#!/usr/bin/env bash
# Copies the linkurious-entity-resolution database from the Bitnami MariaDB (<release>-mariadb) to the MariaDB run
# by the mariadb-operator (<release>-mariadb-op), both deployed by the chart (mariadbOperator.enabled=true).
#
# The migration is done with entity-resolution stopped (replicaCount: 0), so that nothing writes to either
# database during the copy. Replicas are changed through the values in git, not with kubectl scale: Argo CD
# (selfHeal) would revert a manual change.
#
# The dump is streamed from one pod to the other (kubectl exec | kubectl exec): no data is written locally.
# Only the application database is copied: users and grants of the destination are managed by the operator.
#
# Usage: scripts/migrate-mariadb-to-operator.sh [-n namespace] [-r release] [-s statefulset] [-b statefulset]
#                                              [-m mariadb] [-d database] [-y] <command>
#   -s       entity-resolution statefulset (default: the statefulset of the release, labeled
#            app.kubernetes.io/instance=<release>, with a linkurious-entity-resolution container)
#   -b       Bitnami MariaDB statefulset (default: the statefulset of the release with a mariadb container)
#   -m       MariaDB resource of the mariadb-operator (default: derived from the entity-resolution statefulset, whose
#            name is the chart fullname: <fullname truncated to 41 chars>-mariadb-op, as in the chart)
#   check    show both databases (version, tables, row counts, users) and entity-resolution, changes nothing
#   copy     rehearsal, entity-resolution keeps running on the Bitnami database: consistent snapshot, but writes
#            made after it are not copied (row count differences are only reported)
#   migrate  final copy, entity-resolution must be stopped (replicaCount: 0, no pod left): copy the data, compare
#            row counts, and check that entity-resolution stayed stopped. Then set mariadbOperator.primary: true
#            and replicaCount: 1 to restart it on the new database.
#
# The destination database is dropped and recreated by copy and migrate. Both refuse to run unless the
# entity-resolution statefulset template (and, for copy, every running pod) positively targets the Bitnami service
# (SENZING_DATABASE_HOST is its short name or one of its in-cluster DNS names, port 3306, database -d, all as plain
# env values), both services route to the pods the script uses, and no application session is open on the
# destination. Any other target (unset, set through a secret, the destination, another service, an IP) is refused.
set -euo pipefail

namespace="linkurious-entity-resolution-preprod"
release="linkurious-entity-resolution-develop"
database="linkurious"
assume_yes=false
er_sts=""
src_sts=""
dst_name=""
app_user=""

usage() { sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; exit 1; }

while getopts "n:r:s:b:m:d:yh" opt; do
  case "${opt}" in
    n) namespace="${OPTARG}" ;;
    r) release="${OPTARG}" ;;
    s) er_sts="${OPTARG}" ;;
    b) src_sts="${OPTARG}" ;;
    m) dst_name="${OPTARG}" ;;
    d) database="${OPTARG}" ;;
    y) assume_yes=true ;;
    *) usage ;;
  esac
done
shift $((OPTIND - 1))
[[ $# -eq 1 ]] || usage
command="$1"

er_container="linkurious-entity-resolution"

# Credentials never leave the pods: the root password is read from the container environment of each pod
# (set by the Bitnami chart and by the operator) and passed to the client through MYSQL_PWD.
# shellcheck disable=SC2016
remote_auth='set -e; export MYSQL_PWD="${MARIADB_ROOT_PASSWORD:-$(cat "${MARIADB_ROOT_PASSWORD_FILE:-/dev/null}")}"; [ -n "$MYSQL_PWD" ] || { echo "root password not found in the pod environment" >&2; exit 1; };'

log() { echo "==> $*" >&2; }
die() { echo "ERROR: $*" >&2; exit 1; }

# --- resource names ---
# They are read from the cluster rather than recomputed from the release name: the chart fullname is the release
# name only when it contains the chart name, and nameOverride, fullnameOverride and mariadb.fullnameOverride change it.

# release_sts <container> <option>: the only statefulset of the release (app.kubernetes.io/instance=<release>, set by
# this chart and by the Bitnami chart) with a container named <container>. The mariadb-operator statefulset is labeled
# with the MariaDB name instead, so it never matches.
release_sts() {
  local container="$1" option="$2" found
  # shellcheck disable=SC2016
  found="$(kubectl -n "${namespace}" get statefulsets -l "app.kubernetes.io/instance=${release}" -o go-template='{{range .items}}{{$n := .metadata.name}}{{range .spec.template.spec.containers}}{{if eq .name "'"${container}"'"}}{{$n}}{{"\n"}}{{end}}{{end}}{{end}}')" \
    || die "cannot list the statefulsets of release ${release} in ${namespace}"
  case "$(grep -c . <<< "${found}" || true)" in
    1) echo "${found}" ;;
    0) die "no statefulset of release ${release} (label app.kubernetes.io/instance=${release}) has a ${container} container in ${namespace}: check -n/-r, or set it with ${option}" ;;
    *) die "several statefulsets of release ${release} have a ${container} container ($(tr '\n' ' ' <<< "${found}")): set it with ${option}" ;;
  esac
}

[[ -n "${er_sts}" ]] || er_sts="$(release_sts "${er_container}" -s)"
[[ -n "${src_sts}" ]] || src_sts="$(release_sts mariadb -b)"
# Bitnami: the Service, the StatefulSet and the pod prefix are all "<fullname>-mariadb"
src_pod="${src_sts}-0"
src_service="${src_sts}"
if [[ -z "${dst_name}" ]]; then
  # The entity-resolution statefulset is named after the chart fullname: same as
  # linkurious-entity-resolution.mariadbOperator.fullname (trunc 41 | trimSuffix "-", then "-mariadb-op"), so that
  # the StatefulSet created by the operator is at most 52 characters (its controller-revision-hash label must fit in 63)
  dst_name="${er_sts:0:41}"
  dst_name="${dst_name%-}-mariadb-op"
fi
dst_pod="${dst_name}-0"

# sql <pod> <sql>: runs a statement as root in the mariadb container of the pod, prints tab separated rows
sql() {
  local pod="$1" query="$2"
  # shellcheck disable=SC2016
  kubectl -n "${namespace}" exec "${pod}" -c mariadb -- sh -c \
    "${remote_auth}"' exec "$(command -v mariadb || command -v mysql)" -uroot -N -B -e "$1"' sh "${query}"
}

confirm() {
  ${assume_yes} && return 0
  read -r -p "$1 [y/N] " answer
  [[ "${answer}" == "y" || "${answer}" == "Y" ]] || die "aborted"
}

# --- entity-resolution and its database target ---

# jsonpath of the database target of a pod spec: SENZING_DATABASE_HOST|SENZING_DATABASE_PORT|SENZING_DATABASE_NAME
# (only plain values: a target set through envFrom or valueFrom reads as empty, and is never recognized)
db_target_jsonpath() {
  local spec="$1" v out=""
  for v in HOST PORT NAME; do
    out+="${out:+|}{${spec}.containers[?(@.name==\"${er_container}\")].env[?(@.name==\"SENZING_DATABASE_${v}\")].value}"
  done
  echo "${out}"
}

# Database target of the statefulset template: host|port|name
er_db_target() {
  kubectl -n "${namespace}" get statefulset "${er_sts}" -o jsonpath="$(db_target_jsonpath .spec.template.spec)"
}

# Pods of the entity-resolution statefulset, one per line:
# name|deletionTimestamp|SENZING_DATABASE_HOST|SENZING_DATABASE_PORT|SENZING_DATABASE_NAME
er_pods() {
  local selector
  # shellcheck disable=SC2016
  selector="$(kubectl -n "${namespace}" get statefulset "${er_sts}" \
    -o go-template='{{range $k, $v := .spec.selector.matchLabels}}{{$k}}={{$v}},{{end}}')"
  [[ -n "${selector}" ]] || { log "statefulset ${er_sts} has no selector"; return 1; }
  kubectl -n "${namespace}" get pods -l "${selector%,}" \
    -o jsonpath="{range .items[*]}{.metadata.name}|{.metadata.deletionTimestamp}|$(db_target_jsonpath .spec){\"\\n\"}{end}"
}

# Replicas of the statefulset: spec|status
er_replicas() {
  kubectl -n "${namespace}" get statefulset "${er_sts}" -o jsonpath='{.spec.replicas}|{.status.replicas}'
}

# host_is <host> <service>: true only if <host> names <service> of the namespace, by its short name or one of its
# in-cluster DNS names. Anything else (unset, other service, other namespace, IP, other cluster domain) is not.
host_is() {
  local host="${1%.}" svc="$2"
  [[ -n "${host}" && -n "${svc}" ]] || return 1
  case "${host}" in
    "${svc}" | "${svc}.${namespace}" | "${svc}.${namespace}.svc" | "${svc}.${namespace}.svc.cluster.local") return 0 ;;
  esac
  return 1
}

# targets <host|port|name> <service>: true only if the target is positively <service>, port 3306, database ${database}
targets() {
  local host port name
  IFS='|' read -r host port name <<< "$1"
  host_is "${host}" "$2" && [[ "${port}" == "3306" && "${name}" == "${database}" ]]
}

# Fails unless the statefulset template positively targets the Bitnami database: entity-resolution is not
# configured to use the destination, and will restart on Bitnami until mariadbOperator.primary is set
ensure_template_on_source() {
  local target
  target="$(er_db_target)" || die "cannot read statefulset ${er_sts}"
  log "entity-resolution database (template, host|port|name): ${target}"
  targets "${target}" "${src_service}" \
    || die "the statefulset template does not target the Bitnami database ${src_service}:3306/${database} (${target}): refusing to drop ${database} on ${dst_pod}. If it uses ${dst_name}, set mariadbOperator.primary=false first."
}

# Fails unless every running pod positively targets the Bitnami database (copy: entity-resolution keeps running)
ensure_pods_on_source() {
  local pods name deleting target bad=""
  pods="$(er_pods)" || die "cannot list the pods of ${er_sts}"
  while IFS='|' read -r name deleting target; do
    [[ -n "${name}" ]] || continue
    log "pod ${name}: database ${target}${deleting:+, terminating}"
    targets "${target}" "${src_service}" || bad+=$'\n'"  ${name} does not target ${src_service}:3306/${database} (${target})"
  done <<< "${pods}"
  [[ -z "${bad}" ]] || die "entity-resolution pods are not all on the Bitnami database:${bad}"
}

# Fails unless entity-resolution is stopped: 0 replicas wanted and running, and no pod left (terminating included)
ensure_er_stopped() {
  local replicas pods
  replicas="$(er_replicas)" || die "cannot read statefulset ${er_sts}"
  pods="$(er_pods)" || die "cannot list the pods of ${er_sts}"
  log "statefulset ${er_sts} replicas (spec|status): ${replicas}, pods: $(grep -c . <<< "${pods}" || true)"
  [[ "${replicas}" == "0|0" && -z "${pods}" ]] \
    || die "entity-resolution is not stopped (replicas ${replicas}${pods:+, pods: $(cut -d'|' -f1 <<< "${pods}" | tr '\n' ' ')}): set replicaCount: 0 and let Argo CD sync first"
}

# --- databases ---

# Pods behind a service (EndpointSlices), sorted
service_pods() {
  kubectl -n "${namespace}" get endpointslices -l "kubernetes.io/service-name=$1" \
    -o jsonpath='{range .items[*]}{range .endpoints[*]}{.targetRef.name}{"\n"}{end}{end}' | sort -u
}

# Fails unless <service> exists and routes to <pod> only
ensure_service_routes_to() {
  local svc="$1" pod="$2" pods
  kubectl -n "${namespace}" get service "${svc}" >/dev/null || die "service ${svc} not found"
  pods="$(service_pods "${svc}")"
  [[ "${pods}" == "${pod}" ]] \
    || die "service ${svc} does not route to ${pod} only (endpoints: $(echo "${pods:-none}" | tr '\n' ' '))"
}

preflight() {
  log "context: $(kubectl config current-context), namespace: ${namespace}"
  log "entity-resolution: statefulset ${er_sts}, source: ${src_pod} (Bitnami), destination: ${dst_pod} (mariadb-operator), database: ${database}"
  kubectl -n "${namespace}" get pod "${src_pod}" >/dev/null || die "source pod ${src_pod} not found"
  kubectl -n "${namespace}" wait --for=condition=Ready "mariadb/${dst_name}" --timeout=10s >/dev/null \
    || die "MariaDB ${dst_name} is not Ready (kubectl -n ${namespace} describe mariadb ${dst_name})"
  # The pods the script reads from and writes to must be the ones behind the hosts entity-resolution uses
  ensure_service_routes_to "${src_service}" "${src_pod}"
  ensure_service_routes_to "${dst_name}" "${dst_pod}"
  log "services: ${src_service} -> ${src_pod}, ${dst_name} -> ${dst_pod}"
  log "source version: $(sql "${src_pod}" 'SELECT VERSION()')"
  log "destination version: $(sql "${dst_pod}" 'SELECT VERSION()')"
  app_user="$(kubectl -n "${namespace}" get "mariadb/${dst_name}" -o jsonpath='{.spec.username}')"
  [[ -n "${app_user}" ]] || die "MariaDB ${dst_name} has no spec.username"
  log "application user on the destination: ${app_user}"
}

# Client ports (one per line) of the connections the Bitnami metrics sidecar (mysqld-exporter, read-only) holds to
# MariaDB: local ports of the TCP sockets to port 3306 owned by the processes of the "metrics" container of <pod>.
# Nothing if the pod has no such container.
exporter_ports() {
  local pod="$1" containers
  containers="$(kubectl -n "${namespace}" get pod "${pod}" -o jsonpath='{.spec.containers[*].name}')" || return 1
  [[ " ${containers} " == *" metrics "* ]] || return 0
  # shellcheck disable=SC2016
  kubectl -n "${namespace}" exec "${pod}" -c metrics -- bash -c '
    set -e
    inodes=" "
    for fd in /proc/[0-9]*/fd/*; do
      l="$(readlink "${fd}" 2>/dev/null)" || continue
      if [[ "${l}" == "socket:["*"]" ]]; then l="${l#socket:[}"; inodes+="${l%]} "; fi
    done
    for f in /proc/net/tcp /proc/net/tcp6; do
      [[ -r "${f}" ]] || continue
      { read -r _
        while read -r _ local rem _ _ _ _ _ _ inode _; do
          if [[ "${rem##*:}" == 0CEA && "${inodes}" == *" ${inode} "* ]]; then echo "$((16#${local##*:}))"; fi
        done; } < "${f}"
    done'
}

# Sessions open on a database pod, except this script's own connection and the connections of the metrics sidecar
# (identified by their client port, see exporter_ports): "id user@host db". Any other session counts, including
# root sessions over the unix socket or the loopback (e.g. a client opened with kubectl exec).
open_sessions() {
  local pod="$1" rows out ports id user host db
  rows="$(sql "${pod}" "SELECT id, user, host, IFNULL(db, '-') FROM information_schema.processlist WHERE command NOT IN ('Daemon', 'Killed', 'Binlog Dump') AND id <> CONNECTION_ID()")" || return 1
  [[ -n "${rows}" ]] || return 0
  # Listed after the sessions: a connection the exporter opened in between is reported, never ignored
  out="$(exporter_ports "${pod}")" || { log "cannot identify the connections of the metrics sidecar of ${pod}"; return 1; }
  ports=" ${out//$'\n'/ } "
  while IFS=$'\t' read -r id user host db; do
    [[ -n "${id}" ]] || continue
    if [[ "${host}" == *:* ]]; then
      case "${host%:*}" in
        localhost | 127.0.0.1 | ::1) [[ "${ports}" == *" ${host##*:} "* ]] && continue ;;
      esac
    fi
    echo "${id} ${user}@${host} ${db}"
  done <<< "${rows}"
}

# Client sessions of a database pod that stay open: present in two samples taken 2s apart (same id). Short-lived
# sessions (exec probes of the container, a connection the exporter is opening) are not reported.
client_sessions() {
  local first second line
  first="$(open_sessions "$1")" || return 1
  [[ -n "${first}" ]] || return 0
  sleep 2
  second="$(open_sessions "$1")" || return 1
  while read -r line; do
    if [[ -n "${line}" ]] && grep -q "^${line%% *} " <<< "${first}"; then echo "${line}"; fi
  done <<< "${second}"
}

# Fails if the application uses the destination: a session of its user, or any client on the database
ensure_no_session_on_destination() {
  local sessions
  sessions="$(sql "${dst_pod}" "SELECT CONCAT(id, ' ', user, '@', host, ' ', IFNULL(db, '-')) FROM information_schema.processlist WHERE (user = '${app_user}' OR db = '${database}') AND command <> 'Killed' AND id <> CONNECTION_ID()")" \
    || die "cannot list the sessions of ${dst_pod}"
  [[ -z "${sessions}" ]] || die "application sessions are open on ${dst_pod}, refusing to drop its database:"$'\n'"${sessions}"
}

# Fails if a client is connected to the source: entity-resolution is stopped, so any client may still write to it
ensure_no_client_on_source() {
  local sessions
  sessions="$(client_sessions "${src_pod}")" || die "cannot list the sessions of ${src_pod}"
  [[ -z "${sessions}" ]] || die "clients are connected to ${src_pod}, they could write during the copy:"$'\n'"${sessions}"
}

# Exact row count of every table of the database, sorted ("table<TAB>count")
row_counts() {
  local pod="$1" tables query=""
  tables="$(sql "${pod}" "SELECT table_name FROM information_schema.tables WHERE table_schema='${database}' AND table_type='BASE TABLE' ORDER BY table_name")" || return 1
  [[ -n "${tables}" ]] || return 0
  while read -r t; do
    query+="${query:+ UNION ALL }SELECT '${t}', COUNT(*) FROM \`${database}\`.\`${t}\`"
  done <<< "${tables}"
  sql "${pod}" "${query}" | sort
}

verify() {
  local src dst
  log "comparing row counts"
  src="$(row_counts "${src_pod}")" || die "cannot count the rows of ${src_pod}"
  dst="$(row_counts "${dst_pod}")" || die "cannot count the rows of ${dst_pod}"
  if diff <(echo "${src}") <(echo "${dst}") >&2; then
    log "OK: $(echo "${src}" | grep -c . || true) tables, same row counts"
  elif [[ "${command}" == "copy" ]]; then
    log "WARNING: row counts differ (< source, > destination): expected in a rehearsal, entity-resolution keeps writing"
  else
    die "row counts differ (< source, > destination)"
  fi
}

copy_data() {
  local charset collation destination_database
  destination_database="$(kubectl -n "${namespace}" get "mariadb/${dst_name}" -o jsonpath='{.spec.database}')"
  [[ "${destination_database}" == "${database}" ]] \
    || die "destination database is ${destination_database:-<unset>}, not ${database}: refusing to copy"
  read -r charset collation < <(sql "${src_pod}" \
    "SELECT default_character_set_name, default_collation_name FROM information_schema.schemata WHERE schema_name='${database}'")
  [[ -n "${charset}" ]] || die "database ${database} not found on ${src_pod}"
  preflight
  ensure_template_on_source
  if [[ "${command}" == "migrate" ]]; then
    ensure_er_stopped
    ensure_no_client_on_source
  else
    ensure_pods_on_source
  fi
  ensure_no_session_on_destination
  log "dropping and recreating database ${database} (${charset}/${collation}) on ${dst_pod}"
  sql "${dst_pod}" "DROP DATABASE IF EXISTS \`${database}\`; CREATE DATABASE \`${database}\` CHARACTER SET ${charset} COLLATE ${collation}"
  # copy: consistent snapshot, entity-resolution keeps writing. migrate: global read lock held for the whole dump,
  # so that no session (root included) can write to the source while it is read.
  local consistency="--single-transaction"
  [[ "${command}" == "migrate" ]] && consistency="--lock-all-tables"
  log "streaming dump ${src_pod} -> ${dst_pod} (${consistency})"
  # shellcheck disable=SC2016
  kubectl -n "${namespace}" exec "${src_pod}" -c mariadb -- sh -c \
    "${remote_auth}"' exec "$(command -v mariadb-dump || command -v mysqldump)" -uroot \
       "$2" --routines --triggers --events --hex-blob --default-character-set=utf8mb4 "$1"' \
    sh "${database}" "${consistency}" \
  | kubectl -n "${namespace}" exec -i "${dst_pod}" -c mariadb -- sh -c \
    "${remote_auth}"' exec "$(command -v mariadb || command -v mysql)" -uroot "$1"' sh "${database}"
  # Grants are not tied to the database: the ones the operator gave to its user survive the drop/recreate
  log "grants on destination: $(sql "${dst_pod}" "SELECT CONCAT(grantee, ' ', privilege_type) FROM information_schema.schema_privileges WHERE table_schema='${database}'" | sort -u | tr '\n' ' ')"
}

case "${command}" in
  check)
    preflight
    log "entity-resolution database (template, host|port|name): $(er_db_target)"
    log "statefulset ${er_sts} replicas (spec|status): $(er_replicas)"
    log "pods (name|deletionTimestamp|host|port|name):"; er_pods >&2
    log "clients on the source:";      client_sessions "${src_pod}" >&2
    log "clients on the destination:"; client_sessions "${dst_pod}" >&2
    log "source row counts:";      row_counts "${src_pod}"
    log "destination row counts:"; row_counts "${dst_pod}"
    # Users are not copied: any user needed on the destination has to be declared as a User/Grant resource
    users="SELECT CONCAT(user, '@', host) FROM mysql.user WHERE user NOT IN ('', 'mariadb.sys') ORDER BY 1"
    log "users (< source only, > destination only):"
    diff <(sql "${src_pod}" "${users}") <(sql "${dst_pod}" "${users}") >&2 || true
    ;;
  copy)
    preflight
    ensure_template_on_source
    ensure_pods_on_source
    ensure_no_session_on_destination
    confirm "Drop ${database} on ${dst_pod} and copy it from ${src_pod} (rehearsal, entity-resolution keeps running)?"
    copy_data
    verify
    log "rehearsal done: writes made after the dump are not copied, run 'migrate' with entity-resolution stopped"
    ;;
  migrate)
    preflight
    ensure_template_on_source
    ensure_er_stopped
    ensure_no_client_on_source
    ensure_no_session_on_destination
    confirm "Drop ${database} on ${dst_pod} and copy it from ${src_pod} (final copy, entity-resolution is stopped)?"
    copy_data
    verify
    # Nothing may have restarted or connected during the copy, otherwise writes may be missing from it
    ensure_template_on_source
    ensure_er_stopped
    ensure_no_client_on_source
    cat >&2 <<EOF
==> migration done: ${dst_pod} has the same data as ${src_pod}, entity-resolution is still stopped.
    Next: set mariadbOperator.primary: true and replicaCount: 1 (in the same change) and let Argo CD sync.
    entity-resolution then starts on ${dst_name}. Check it with:
      $0 -n ${namespace} -r ${release} check
    Rollback: set mariadbOperator.primary: false (${src_pod} is unchanged; writes made on ${dst_name} are lost).
EOF
    ;;
  *)
    usage
    ;;
esac
