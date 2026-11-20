#!/usr/bin/env bash
# Copies the linkurious-entity-resolution database from the Bitnami MariaDB (<release>-mariadb) to the MariaDB run
# by the mariadb-operator (<release>-mariadb-op), both deployed by the chart (mariadbOperator.enabled=true).
#
# The dump is streamed from one pod to the other (kubectl exec | kubectl exec): no data is written locally.
# Only the application database is copied: users and grants of the destination are managed by the operator.
#
# Usage: scripts/migrate-mariadb-to-operator.sh [-n namespace] [-r release] [-m mariadb] [-d database] [-t minutes] [-y] <command>
#   -m       name of the MariaDB resource (default: <release truncated to 52 chars>-mariadb-op, as in the chart)
#   check    show both databases (version, tables, row counts, users, pods), changes nothing
#   copy     rehearsal: copy the data while entity-resolution keeps writing to the Bitnami database
#            (consistent snapshot, but writes made after it are not copied), then compare row counts
#   cutover  block the writes on the Bitnami database (global read lock), copy the data, compare row counts, then
#            wait for entity-resolution to be restarted on the new database (mariadbOperator.primary=true synced
#            by Argo CD), and release the lock. Entity-resolution writes hang while the lock is held.
#            -t (default 30): time, copy included, for the switch to begin. If it runs out, the lock is lost or the
#            script is interrupted before the switch begins, the lock is released, entity-resolution keeps using
#            the Bitnami database and the destination user stays locked (the copy is stale).
#            Once Argo CD has started to change the statefulset, the lock is kept (and renewed, or taken again if
#            lost) whatever happens, until every pod runs on the new database, or until every pod is back on the
#            Bitnami one (mariadbOperator.primary reverted) and the rollback is confirmed ('rollback', or -y).
#            Ctrl-C then offers to release the lock anyway (type 'release'), at the risk of splitting the writes.
#
# Entity-resolution connects to the Bitnami database as root, so `read_only` would not block its writes:
# FLUSH TABLES WITH READ LOCK does, and it is released as soon as the session holding it ends.
# The destination database is dropped and recreated by copy and cutover. To avoid erasing data written by
# entity-resolution, both refuse to run unless the statefulset rollout to the Bitnami database is complete, the
# template and every running pod positively target the Bitnami service (SENZING_DATABASE_HOST is its short name or
# one of its in-cluster DNS names, port 3306, database -d, all as plain env values), that service and the
# destination one route to the pods the script uses, and no application session is open on the destination.
# Any other target (unset, set through a secret, another service or database, an IP) is refused. During the copy, the
# application user of the destination is locked (ACCOUNT LOCK), so that a pod switched meanwhile cannot write to it.
set -euo pipefail

namespace="linkurious-entity-resolution-preprod"
release="linkurious-entity-resolution-develop"
database="linkurious"
wait_minutes=30
assume_yes=false

dst_name=""
app_user=""
sts_state=""

usage() { sed -n '2,32p' "$0" | sed 's/^# \{0,1\}//'; exit 1; }

while getopts "n:r:m:d:t:yh" opt; do
  case "${opt}" in
    n) namespace="${OPTARG}" ;;
    r) release="${OPTARG}" ;;
    m) dst_name="${OPTARG}" ;;
    d) database="${OPTARG}" ;;
    t) wait_minutes="${OPTARG}" ;;
    y) assume_yes=true ;;
    *) usage ;;
  esac
done
shift $((OPTIND - 1))
[[ $# -eq 1 ]] || usage
command="$1"
[[ "${wait_minutes}" =~ ^[0-9]+$ ]] || { echo "ERROR: -t expects a number of minutes" >&2; exit 1; }

src_pod="${release}-mariadb-0"
if [[ -z "${dst_name}" ]]; then
  # Same as linkurious-entity-resolution.mariadbOperator.fullname (fullname = release when it contains the chart name)
  dst_name="${release:0:52}"
  dst_name="${dst_name%%-}-mariadb-op"
fi
dst_pod="${dst_name}-0"
# Bitnami: the Service, the StatefulSet and the pod prefix are all "<fullname>-mariadb"
src_service="${src_pod%-0}"
er_sts="${release}"
er_container="linkurious-entity-resolution"
# Marker of the session holding the global read lock, split in queries so that they do not match themselves
lock_marker="er-migration-lock"

# Credentials never leave the pods: the root password is read from the container environment of each pod
# (set by the Bitnami chart and by the operator) and passed to the client through MYSQL_PWD.
# shellcheck disable=SC2016
remote_auth='set -e; export MYSQL_PWD="${MARIADB_ROOT_PASSWORD:-$(cat "${MARIADB_ROOT_PASSWORD_FILE:-/dev/null}")}"; [ -n "$MYSQL_PWD" ] || { echo "root password not found in the pod environment" >&2; exit 1; };'

log() { echo "==> $*" >&2; }
die() { echo "ERROR: $*" >&2; exit 1; }

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
  log "source: ${src_pod} (Bitnami), destination: ${dst_pod} (mariadb-operator), database: ${database}"
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

# phase "switch": the destination has been unlocked for entity-resolution, during the cutover
phase=""
cleanup() {
  local rc=$?
  trap - EXIT
  set +e
  if [[ "${phase}" == "switch" && -z "${switch_state}" ]]; then
    if switch_begun; then
      # Timeout, interrupt or error while pods may be moving to the destination: releasing the lock now would let
      # the previous pods (or their statements waiting for it) write on Bitnami while the new ones use the copy
      log "exiting (status ${rc}) while ${er_sts} is switching: the lock is kept until the switch is resolved"
      hold_switch
    else
      # Nothing switched yet, but the copy becomes stale once the source is writable again
      keep_fenced=true
    fi
  fi
  if [[ "${phase}" != "switch" ]] && ${fenced}; then
    keep_fenced=true
  fi
  # The stale copy is positively fenced before the source accepts writes again
  if ${keep_fenced}; then
    secure_fence || rc=1
  fi
  unfence_destination
  release_source
  exit "${rc}"
}

# Pods of the entity-resolution statefulset, one per line:
# name|controller-revision-hash|deletionTimestamp|SENZING_DATABASE_HOST|SENZING_DATABASE_PORT|SENZING_DATABASE_NAME
er_pods() {
  local selector
  # shellcheck disable=SC2016
  selector="$(kubectl -n "${namespace}" get statefulset "${er_sts}" \
    -o go-template='{{range $k, $v := .spec.selector.matchLabels}}{{$k}}={{$v}},{{end}}')"
  kubectl -n "${namespace}" get pods -l "${selector%,}" \
    -o jsonpath="{range .items[*]}{.metadata.name}|{.metadata.labels.controller-revision-hash}|{.metadata.deletionTimestamp}|$(db_target_jsonpath .spec){\"\\n\"}{end}"
}

# Snapshot of the statefulset: generation|observedGeneration|replicas|readyReplicas|updatedReplicas|currentRevision|updateRevision
er_sts_state() {
  kubectl -n "${namespace}" get statefulset "${er_sts}" -o jsonpath='{.metadata.generation}|{.status.observedGeneration}|{.spec.replicas}|{.status.readyReplicas}|{.status.updatedReplicas}|{.status.currentRevision}|{.status.updateRevision}'
}

# Application sessions open on the destination: user of the MariaDB resource, or any client on the database,
# except our own sessions (unix socket, localhost)
dst_app_sessions() {
  sql "${dst_pod}" "SELECT CONCAT(id, ' ', user, '@', host, ' ', IFNULL(db, '-')) FROM information_schema.processlist WHERE (user = '${app_user}' OR db = '${database}') AND host NOT LIKE 'localhost%' AND command <> 'Killed' AND id <> CONNECTION_ID()"
}

# Fails unless entity-resolution is fully rolled out on the Bitnami database: desired template, statefulset
# status, and every running pod must positively target ${src_service}:3306/${database}. Also fails if an
# application session is open on the destination.
ensure_destination_unused() {
  local target state gen observed replicas ready updated current update pods sessions name revision deleting pod_target bad=""
  target="$(er_db_target)"
  log "entity-resolution database (template, host|port|name): ${target}"
  targets "${target}" "${src_service}" \
    || die "the statefulset template does not target the Bitnami database ${src_service}:3306/${database} (${target}): refusing to drop ${database} on ${dst_pod}. If it uses ${dst_name}, set mariadbOperator.primary=false first."

  state="$(er_sts_state)"
  IFS='|' read -r gen observed replicas ready updated current update <<< "${state}"
  log "statefulset ${er_sts}: generation ${gen} (observed ${observed}), ready ${ready:-0}/${replicas}, updated ${updated:-0}/${replicas}, revision ${current} -> ${update}"
  [[ "${gen}" == "${observed}" && "${current}" == "${update}" && "${updated:-0}" == "${replicas}" && "${ready:-0}" == "${replicas}" ]] \
    || die "statefulset ${er_sts} rollout is not complete (kubectl -n ${namespace} rollout status statefulset/${er_sts})"

  pods="$(er_pods)"
  [[ "$(grep -c . <<< "${pods}" || true)" == "${replicas}" ]] || bad+=$'\n'"  expected ${replicas} pod(s)"
  while IFS='|' read -r name revision deleting pod_target; do
    [[ -n "${name}" ]] || continue
    log "pod ${name}: revision ${revision}, database ${pod_target}${deleting:+, terminating}"
    [[ "${revision}" == "${update}" ]] || bad+=$'\n'"  ${name} runs revision ${revision}, not ${update}"
    targets "${pod_target}" "${src_service}" || bad+=$'\n'"  ${name} does not target ${src_service}:3306/${database} (${pod_target})"
    [[ -z "${deleting}" ]] || bad+=$'\n'"  ${name} is terminating"
  done <<< "${pods}"
  [[ -z "${bad}" ]] || die "entity-resolution pods are not all on the Bitnami database:${bad}"

  sessions="$(dst_app_sessions)"
  [[ -z "${sessions}" ]] || die "application sessions are open on ${dst_pod}, refusing to drop its database:"$'\n'"${sessions}"
  sts_state="${state}"
}

# Accounts (hosts) of the application user on the destination. Fails if the lookup fails or finds no account:
# an empty answer is never taken for "nothing to lock".
app_user_hosts() {
  local hosts
  hosts="$(sql "${dst_pod}" "SELECT host FROM mysql.user WHERE user = '${app_user}'")" \
    || { log "cannot list the accounts of ${app_user} on ${dst_pod}"; return 1; }
  [[ -n "${hosts}" ]] || { log "no account ${app_user} on ${dst_pod}"; return 1; }
  echo "${hosts}"
}

# Ids of the sessions of the application user on the destination (fails if they cannot be listed)
app_user_sessions() {
  sql "${dst_pod}" "SELECT id FROM information_schema.processlist WHERE user = '${app_user}' AND id <> CONNECTION_ID()"
}

# True only if every account of the application user is positively locked and none of its sessions is left.
# A failed lookup counts as not fenced.
verify_fence() {
  local hosts h create sessions
  hosts="$(app_user_hosts)" || return 1
  for h in ${hosts}; do
    create="$(sql "${dst_pod}" "SHOW CREATE USER '${app_user}'@'${h}'")" \
      || { log "cannot read the account ${app_user}@${h}"; return 1; }
    grep -q 'ACCOUNT LOCK' <<< "${create}" || { log "account ${app_user}@${h} is not locked"; return 1; }
  done
  sessions="$(app_user_sessions)" || { log "cannot list the sessions of ${app_user}"; return 1; }
  [[ -z "${sessions}" ]] || { log "sessions of ${app_user} still open: $(tr '\n' ' ' <<< "${sessions}")"; return 1; }
}

# Locks every account of the application user, kills its sessions (including ones opened while it was unlocked),
# waits for them to end and verifies the result. Idempotent. Fails if the fence cannot be verified.
establish_fence() {
  local hosts h id _try
  hosts="$(app_user_hosts)" || return 1
  # From the first lock on, cleanup knows the destination was touched (a failure before it changes nothing)
  fenced=true
  for h in ${hosts}; do
    sql "${dst_pod}" "ALTER USER '${app_user}'@'${h}' ACCOUNT LOCK" || { log "cannot lock ${app_user}@${h}"; return 1; }
  done
  # Killed sessions stay listed until they end: kill and check again for up to 10s
  for _try in 1 2 3 4 5 6 7 8 9; do
    for id in $(app_user_sessions 2>/dev/null || true); do
      sql "${dst_pod}" "KILL ${id}" 2>/dev/null || true
    done
    verify_fence 2>/dev/null && return 0
    sleep 1
  done
  verify_fence
}

# Locks the application user of the destination: until unfence_destination, a pod switched to the destination
# (Argo CD sync during the copy) cannot connect, so the drop/copy cannot erase its writes.
fenced=false
# keep_fenced: the destination copy must not be used (stale, or state unclear). cleanup then re-establishes and
# verifies the fence before the source lock is released (secure_fence).
keep_fenced=false
fence_destination() {
  log "locking user ${app_user} on ${dst_pod}"
  establish_fence || die "could not lock user ${app_user} on ${dst_pod}"
  log "user ${app_user} locked on ${dst_pod} (verified)"
}

# Checks that the destination stayed fenced and that entity-resolution did not change during the copy
ensure_fence_held() {
  if ! verify_fence; then
    keep_fenced=true
    log "the lock of ${app_user} on ${dst_pod} was lost during the copy (operator reconcile?), locking it again"
    establish_fence || true
    die "user ${app_user} was not locked on ${dst_pod} during the copy: the copy may not be consistent, run it again"
  fi
  if [[ "$(er_sts_state)" != "${sts_state}" ]] || ! targets "$(er_db_target)" "${src_service}"; then
    keep_fenced=true
    die "statefulset ${er_sts} changed during the copy (switch or rollback in progress): ${app_user} stays locked on ${dst_pod}. Check which database entity-resolution must use, then unlock it with: ALTER USER '${app_user}'@'%' ACCOUNT UNLOCK"
  fi
}

# Before the source becomes writable again, the stale destination must be positively fenced. While it cannot be,
# the source lock (if any) is kept and renewed, and the fence retried; Ctrl-C offers to give up.
secure_fence() {
  hold_interrupted=false
  trap 'hold_interrupted=true' INT TERM
  until establish_fence; do
    [[ -z "${lock_pid}" ]] || keep_lock_alive
    log "WARNING: cannot lock ${app_user} on ${dst_pod}${lock_pid:+, ${src_pod} stays locked}; retrying in 10s (Ctrl-C for options)"
    if ${hold_interrupted}; then
      hold_interrupted=false
      if ask_tty "Give up? ${dst_pod} may stay usable with a stale copy${lock_pid:+ once ${src_pod} is unlocked}. Type 'giveup' to confirm:" giveup; then
        log "WARNING: gave up locking ${app_user} on ${dst_pod}: make sure no pod uses ${dst_name}"
        trap 'exit 130' INT TERM
        return 1
      fi
    fi
    sleep 10
  done
  trap 'exit 130' INT TERM
  log "user ${app_user} left locked on ${dst_pod} (verified)"
}

# Unlocks the application user and verifies it. Fails (and leaves fenced=true) if it cannot be done.
unfence_destination() {
  local hosts h
  ${fenced} || return 0
  ${keep_fenced} && return 0
  hosts="$(app_user_hosts)" || return 1
  for h in ${hosts}; do
    sql "${dst_pod}" "ALTER USER '${app_user}'@'${h}' ACCOUNT UNLOCK" || { log "cannot unlock ${app_user}@${h}"; return 1; }
    ! sql "${dst_pod}" "SHOW CREATE USER '${app_user}'@'${h}'" | grep -q 'ACCOUNT LOCK' \
      || { log "${app_user}@${h} is still locked"; return 1; }
  done
  fenced=false
  log "user ${app_user} unlocked on ${dst_pod}"
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
  src="$(row_counts "${src_pod}")"
  dst="$(row_counts "${dst_pod}")"
  if diff <(echo "${src}") <(echo "${dst}") >&2; then
    log "OK: $(echo "${src}" | grep -c . || true) tables, same row counts"
  else
    if [[ "${command}" == "copy" ]]; then
      log "WARNING: row counts differ (< source, > destination); concurrent source writes can cause rehearsal drift"
    else
      die "row counts differ (< source, > destination)"
    fi
  fi
}

copy_data() {
  local charset collation
  read -r charset collation < <(sql "${src_pod}" \
    "SELECT default_character_set_name, default_collation_name FROM information_schema.schemata WHERE schema_name='${database}'")
  [[ -n "${charset}" ]] || die "database ${database} not found on ${src_pod}"
  log "dropping and recreating database ${database} (${charset}/${collation}) on ${dst_pod}"
  sql "${dst_pod}" "DROP DATABASE IF EXISTS \`${database}\`; CREATE DATABASE \`${database}\` CHARACTER SET ${charset} COLLATE ${collation}"
  log "streaming dump ${src_pod} -> ${dst_pod}"
  # shellcheck disable=SC2016
  kubectl -n "${namespace}" exec "${src_pod}" -c mariadb -- sh -c \
    "${remote_auth}"' exec "$(command -v mariadb-dump || command -v mysqldump)" -uroot \
       --single-transaction --routines --triggers --events --hex-blob --default-character-set=utf8mb4 "$1"' \
    sh "${database}" \
  | kubectl -n "${namespace}" exec -i "${dst_pod}" -c mariadb -- sh -c \
    "${remote_auth}"' exec "$(command -v mariadb || command -v mysql)" -uroot "$1"' sh "${database}"
  # Grants are not tied to the database: the ones the operator gave to its user survive the drop/recreate
  log "grants on destination: $(sql "${dst_pod}" "SELECT CONCAT(grantee, ' ', privilege_type) FROM information_schema.schema_privileges WHERE table_schema='${database}'" | sort -u | tr '\n' ' ')"
}

# Ids of the source sessions holding the global read lock, one per line (empty if none)
lock_session_ids() {
  sql "${src_pod}" "SELECT id FROM information_schema.processlist WHERE info LIKE CONCAT('%', 'er-migration', '-lock', '%') AND id <> CONNECTION_ID()"
}

lock_pid=""
lock_id=""
# Time (epoch) by which entity-resolution must start switching, set when the lock is taken. Until the switch
# begins, the lock session sleeps lock_margin seconds longer than that; once it has begun, the lock is renewed
# until the switch or a rollback is complete. A session only expires on its own if the script dies without
# releasing it (kill -9, lost laptop...), which bounds how long the source can stay locked.
lock_deadline=0
lock_expires=0
lock_margin=600
lock_renew_seconds=1800

# take_lock <seconds>: starts a session that takes the global read lock and sleeps <seconds>, waits for it to hold
# the lock, and makes it the current lock session. A previous lock session is left untouched (the global read
# lock can be held by several sessions at once), so that the lock can be renewed without a gap.
take_lock() {
  local seconds="$1" pid id=""
  # The session stays open (SLEEP) to keep the lock; it is killed by release_source.
  # SLEEP starts once FLUSH TABLES WITH READ LOCK returns, i.e. after the lock is taken.
  # shellcheck disable=SC2016
  kubectl -n "${namespace}" exec "${src_pod}" -c mariadb -- sh -c \
    "${remote_auth}"' exec "$(command -v mariadb || command -v mysql)" -uroot -N -B -e "$1"' sh \
    "FLUSH TABLES WITH READ LOCK; SELECT '${lock_marker}', SLEEP(${seconds})" >/dev/null &
  pid=$!
  for _ in $(seq 1 60); do
    id="$(lock_session_ids | grep -vx "${lock_id:-none}" | head -1 || true)"
    [[ -n "${id}" ]] && break
    kill -0 "${pid}" 2>/dev/null || return 1
    sleep 1
  done
  [[ -n "${id}" ]] || { kill "${pid}" 2>/dev/null || true; return 1; }
  lock_pid="${pid}"
  lock_id="${id}"
  lock_expires=$(( $(date +%s) + seconds ))
}

lock_source() {
  log "taking the global read lock on ${src_pod} (entity-resolution writes hang from now on, ${wait_minutes} min max before the switch)"
  take_lock $(( wait_minutes * 60 + lock_margin )) \
    || die "could not take the global read lock in 60s (long running query on ${src_pod}?)"
  lock_deadline=$(( $(date +%s) + wait_minutes * 60 ))
  log "global read lock held by session ${lock_id}, the switch must begin before $(fmt_time "${lock_deadline}")"
}

fmt_time() { date -r "$1" +%H:%M:%S 2>/dev/null || date -d "@$1" +%H:%M:%S; }

# True while the lock is held: the local kubectl exec is alive and its session is still sleeping on the source.
# A failed check is retried, so that a transient API error is not taken for a lost lock.
lock_held() {
  local _try
  [[ -n "${lock_pid}" ]] || return 1
  for _try in 1 2 3; do
    kill -0 "${lock_pid}" 2>/dev/null || return 1
    lock_session_ids 2>/dev/null | grep -qx "${lock_id}" && return 0
    sleep 2
  done
  return 1
}

# Aborts the cutover, before entity-resolution is switched, if the lock is lost or the time is out. Writes may
# have resumed on the source after the dump: the destination user is (re)locked and left locked, so that no pod
# switched to the copy can use it.
ensure_lock_held() {
  local step="$1"
  if ! lock_held; then
    keep_fenced=true
    establish_fence || true
    die "global read lock lost on ${src_pod} ${step}: writes may have resumed there after the copy.
    ${app_user} stays locked on ${dst_pod}. If mariadbOperator.primary=true was merged, revert it and wait for
    the rollout, then run cutover again."
  fi
  if (( $(date +%s) >= lock_deadline )); then
    keep_fenced=true
    establish_fence || true
    die "the ${wait_minutes} min of the lock ran out ${step}. ${app_user} stays locked on ${dst_pod}.
    If mariadbOperator.primary=true was merged, revert it and wait for the rollout, then run cutover again (-t)."
  fi
}

# During a switch: renews the lock before it expires, and takes it again if it was lost
lock_lost_during_switch=false
keep_lock_alive() {
  local old_pid old_id
  if ! lock_held; then
    lock_lost_during_switch=true
    log "WARNING: global read lock lost on ${src_pod} during the switch, taking it again (writes may have reached it meanwhile)"
    lock_pid=""; lock_id=""
    if take_lock "${lock_renew_seconds}"; then
      log "global read lock taken again by session ${lock_id}"
    else
      log "WARNING: could not take the lock again, retrying"
    fi
    return 0
  fi
  if (( $(date +%s) > lock_expires - 300 )); then
    old_pid="${lock_pid}"; old_id="${lock_id}"
    if take_lock "${lock_renew_seconds}"; then
      sql "${src_pod}" "KILL ${old_id}" 2>/dev/null || true
      kill "${old_pid}" 2>/dev/null || true
      log "global read lock renewed by session ${lock_id} (until $(fmt_time "${lock_expires}"))"
    else
      lock_pid="${old_pid}"; lock_id="${old_id}"
      log "WARNING: could not renew the lock, session ${old_id} expires at $(fmt_time "${lock_expires}"), retrying"
    fi
  fi
}

release_source() {
  local id
  [[ -n "${lock_pid}" ]] || return 0
  for id in $(lock_session_ids || true); do
    sql "${src_pod}" "KILL ${id}" || true
  done
  log "global read lock released on ${src_pod}"
  kill "${lock_pid}" 2>/dev/null || true
  lock_pid=""
  lock_id=""
}

# Kills the client connections left on the source (from the previous entity-resolution pod), so that statements
# waiting for the lock are not run once it is released. Our own sessions use the unix socket (localhost).
kill_source_clients() {
  local ids
  ids="$(sql "${src_pod}" "SELECT id FROM information_schema.processlist WHERE host NOT LIKE 'localhost%' AND command NOT IN ('Daemon', 'Binlog Dump') AND id <> CONNECTION_ID()")"
  for id in ${ids}; do
    sql "${src_pod}" "KILL ${id}" 2>/dev/null || true
  done
  log "killed $(echo "${ids}" | grep -c . || true) client connection(s) left on ${src_pod}"
}

# rolled_out_on <service>: true when the template, the statefulset status and every running pod positively
# target <service>:3306/${database}
rolled_out_on() {
  local svc="$1" state gen observed replicas ready updated current update pods name revision deleting pod_target n=0
  targets "$(er_db_target)" "${svc}" || return 1
  state="$(er_sts_state)" || return 1
  IFS='|' read -r gen observed replicas ready updated current update <<< "${state}"
  [[ "${gen}" == "${observed}" && "${current}" == "${update}" && "${updated:-0}" == "${replicas}" && "${ready:-0}" == "${replicas}" ]] || return 1
  pods="$(er_pods)" || return 1
  while IFS='|' read -r name revision deleting pod_target; do
    [[ -n "${name}" ]] || continue
    [[ "${revision}" == "${update}" && -z "${deleting}" ]] || return 1
    targets "${pod_target}" "${svc}" || return 1
    n=$(( n + 1 ))
  done <<< "${pods}"
  (( n == replicas ))
}

# True once Argo CD has started to change the statefulset since the copy, or if it cannot be told: the template no
# longer positively targets the Bitnami database (whatever it targets), or its generation changed. From then on,
# pods may be moving away from the source and it must stay locked until the switch is resolved.
switch_begun() {
  local target gen
  target="$(er_db_target 2>/dev/null)" || return 0
  gen="$(kubectl -n "${namespace}" get statefulset "${er_sts}" -o jsonpath='{.metadata.generation}' 2>/dev/null)" || return 0
  ! targets "${target}" "${src_service}" || [[ "${gen}" != "${sts_state%%|*}" ]]
}

# Interactive answer, never assumed: no terminal means no
ask_tty() {
  local answer
  [[ -r /dev/tty ]] || return 1
  read -r -p "$1 " answer </dev/tty || return 1
  [[ "${answer}" == "$2" ]]
}

# switch_state: "" (not resolved), "done" (all pods on the destination), "rolled_back" (all pods back on the source)
switch_state=""
hold_interrupted=false

finish_switch() {
  # The previous pods are gone: their statements still waiting for the lock must not run once it is released
  kill_source_clients
  switch_state="done"
  log "rollout of ${er_sts} on ${dst_name} done"
  if ${lock_lost_during_switch}; then
    log "WARNING: the lock was lost for a while during the switch: writes may have reached ${src_pod} after the
    copy. Compare both databases ('check') before removing it."
  fi
}

# Once the switch has begun, keeps the source locked (renewing the lock) until every pod runs on the destination,
# or until a rollback to the source is complete and confirmed. Interrupts and timeouts do not release the lock.
hold_switch() {
  set +e
  trap 'hold_interrupted=true' INT TERM
  log "switch in progress: ${src_pod} stays locked until ${er_sts} is rolled out on ${dst_name},"
  log "or rolled back on ${src_service} (revert mariadbOperator.primary) and confirmed. Ctrl-C shows the options."
  while :; do
    keep_lock_alive
    if rolled_out_on "${dst_name}"; then
      finish_switch
      break
    fi
    if rolled_out_on "${src_service}"; then
      log "rollback done: every pod of ${er_sts} uses ${src_service} again"
      if ${assume_yes} || ask_tty "Release the lock on ${src_pod}? Writes made on ${dst_name} since the switch are not on Bitnami. Type 'rollback' to confirm:" rollback; then
        # The copy is now stale: no pod may use it until a new cutover
        keep_fenced=true
        establish_fence || true
        switch_state="rolled_back"
        break
      fi
    fi
    if ${hold_interrupted}; then
      hold_interrupted=false
      log "statefulset ${er_sts}: $(er_sts_state), template database: $(er_db_target)"
      er_pods >&2
      if ask_tty "Release the lock anyway? Pods on Bitnami and on ${dst_name} may then split the writes. Type 'release' to confirm:" release; then
        log "WARNING: lock released during the switch on request"
        switch_state="released"
        break
      fi
      log "still holding the lock"
    fi
    sleep 10
  done
  trap 'exit 130' INT TERM
  set -e
}

# Waits, until lock_deadline, for Argo CD to start switching the statefulset, then holds the lock until the
# switch (or a rollback) is complete
wait_for_switch() {
  cat >&2 <<EOF
==> copy done and checked, ${src_pod} is still locked.
    Now set mariadbOperator.primary=true and let Argo CD sync. The switch must begin before $(fmt_time "${lock_deadline}").
    (Ctrl-C before the switch begins: the lock is released, entity-resolution stays on Bitnami)
EOF
  until switch_begun; do
    ensure_lock_held "while waiting for the switch"
    sleep 10
  done
  log "statefulset ${er_sts} is being changed by Argo CD"
  hold_switch
}

case "${command}" in
  check)
    preflight
    log "entity-resolution database (template, host|port|name): $(er_db_target)"
    log "statefulset ${er_sts} (generation|observed|replicas|ready|updated|currentRevision|updateRevision): $(er_sts_state)"
    log "pods (name|revision|deletionTimestamp|host|port|name):"; er_pods >&2
    log "application sessions on the destination: $(dst_app_sessions | grep -c . || true)"
    log "source row counts:";      row_counts "${src_pod}"
    log "destination row counts:"; row_counts "${dst_pod}"
    # Users are not copied: any user needed on the destination has to be declared as a User/Grant resource
    users="SELECT CONCAT(user, '@', host) FROM mysql.user WHERE user NOT IN ('', 'mariadb.sys') ORDER BY 1"
    log "users (< source only, > destination only):"
    diff <(sql "${src_pod}" "${users}") <(sql "${dst_pod}" "${users}") >&2 || true
    ;;
  copy)
    preflight
    ensure_destination_unused
    confirm "Drop ${database} on ${dst_pod} and copy it from ${src_pod} (rehearsal, entity-resolution keeps running)?"
    trap cleanup EXIT
    trap 'exit 130' INT TERM
    fence_destination
    # Checked again once fenced: a switch started between the first check and the lock is caught here
    ensure_destination_unused
    copy_data
    verify
    ensure_fence_held
    unfence_destination || die "could not unlock user ${app_user} on ${dst_pod}"
    log "rehearsal done: writes made after the dump are not copied, run 'cutover' for the final copy"
    ;;
  cutover)
    preflight
    ensure_destination_unused
    confirm "Lock ${src_pod} (entity-resolution writes hang until the switch, ${wait_minutes} min max), drop ${database} on ${dst_pod} and copy it?"
    trap cleanup EXIT
    trap 'exit 130' INT TERM
    fence_destination
    ensure_destination_unused
    lock_source
    copy_data
    ensure_lock_held "during the copy"
    verify
    ensure_fence_held
    # Checked last before letting pods use the copy: the lock must have been held from the dump until now
    ensure_lock_held "during the checks"
    # The destination is ready: from now on, entity-resolution can be switched to it
    phase="switch"
    unfence_destination || die "could not unlock user ${app_user} on ${dst_pod}"
    wait_for_switch
    case "${switch_state}" in
      done)
        release_source
        log "cutover done: ${er_sts} uses ${dst_name}. ${src_pod} is no longer used."
        log "rollback: set mariadbOperator.primary=false (writes made on ${dst_name} since the switch would be lost)"
        ;;
      rolled_back)
        die "cutover rolled back: ${er_sts} uses ${src_service} again, ${app_user} stays locked on ${dst_pod}. Run cutover again to retry."
        ;;
      *)
        die "lock released on request during the switch: compare both databases ('check')"
        ;;
    esac
    ;;
  *)
    usage
    ;;
esac
