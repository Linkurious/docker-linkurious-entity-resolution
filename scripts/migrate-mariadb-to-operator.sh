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
#            by Argo CD), and release the lock. -t (default 30) is the maximum time the lock is held, copy included.
#            Entity-resolution writes hang while the lock is held. If the time runs out or the script is
#            interrupted, the lock is released and entity-resolution keeps using the Bitnami database.
#            If the lock session disappears (source pod restart, killed session, kubectl exec cut), the cutover
#            is aborted and the destination user stays locked, so that no pod uses a copy missing later writes.
#
# Entity-resolution connects to the Bitnami database as root, so `read_only` would not block its writes:
# FLUSH TABLES WITH READ LOCK does, and it is released as soon as the session holding it ends.
# The destination database is dropped and recreated by copy and cutover. To avoid erasing data written by
# entity-resolution, both refuse to run unless the statefulset rollout to the Bitnami database is complete,
# every running pod uses it and no application session is open on the destination. During the copy, the
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

usage() { sed -n '2,26p' "$0" | sed 's/^# \{0,1\}//'; exit 1; }

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

er_db_host() {
  kubectl -n "${namespace}" get statefulset "${er_sts}" \
    -o jsonpath="{.spec.template.spec.containers[?(@.name==\"${er_container}\")].env[?(@.name==\"SENZING_DATABASE_HOST\")].value}"
}

preflight() {
  log "context: $(kubectl config current-context), namespace: ${namespace}"
  log "source: ${src_pod} (Bitnami), destination: ${dst_pod} (mariadb-operator), database: ${database}"
  kubectl -n "${namespace}" get pod "${src_pod}" >/dev/null || die "source pod ${src_pod} not found"
  kubectl -n "${namespace}" wait --for=condition=Ready "mariadb/${dst_name}" --timeout=10s >/dev/null \
    || die "MariaDB ${dst_name} is not Ready (kubectl -n ${namespace} describe mariadb ${dst_name})"
  log "source version: $(sql "${src_pod}" 'SELECT VERSION()')"
  log "destination version: $(sql "${dst_pod}" 'SELECT VERSION()')"
  app_user="$(kubectl -n "${namespace}" get "mariadb/${dst_name}" -o jsonpath='{.spec.username}')"
  [[ -n "${app_user}" ]] || die "MariaDB ${dst_name} has no spec.username"
  log "application user on the destination: ${app_user}"
}

cleanup() {
  unfence_destination
  release_source
}

# Pods of the entity-resolution statefulset, one per line: name|controller-revision-hash|SENZING_DATABASE_HOST|deletionTimestamp
er_pods() {
  local selector
  # shellcheck disable=SC2016
  selector="$(kubectl -n "${namespace}" get statefulset "${er_sts}" \
    -o go-template='{{range $k, $v := .spec.selector.matchLabels}}{{$k}}={{$v}},{{end}}')"
  kubectl -n "${namespace}" get pods -l "${selector%,}" -o jsonpath="{range .items[*]}{.metadata.name}{\"|\"}{.metadata.labels.controller-revision-hash}{\"|\"}{.spec.containers[?(@.name==\"${er_container}\")].env[?(@.name==\"SENZING_DATABASE_HOST\")].value}{\"|\"}{.metadata.deletionTimestamp}{\"\\n\"}{end}"
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
# status, and every running pod. Also fails if an application session is open on the destination.
ensure_destination_unused() {
  local host state gen observed replicas ready updated current update pods sessions name revision pod_host deleting bad=""
  host="$(er_db_host)"
  log "entity-resolution SENZING_DATABASE_HOST (template): ${host:-<unset>}"
  [[ "${host}" != "${dst_name}" ]] \
    || die "entity-resolution is configured to use ${dst_name}: refusing to drop its database (set mariadbOperator.primary=false first)"

  state="$(er_sts_state)"
  IFS='|' read -r gen observed replicas ready updated current update <<< "${state}"
  log "statefulset ${er_sts}: generation ${gen} (observed ${observed}), ready ${ready:-0}/${replicas}, updated ${updated:-0}/${replicas}, revision ${current} -> ${update}"
  [[ "${gen}" == "${observed}" && "${current}" == "${update}" && "${updated:-0}" == "${replicas}" && "${ready:-0}" == "${replicas}" ]] \
    || die "statefulset ${er_sts} rollout is not complete (kubectl -n ${namespace} rollout status statefulset/${er_sts})"

  pods="$(er_pods)"
  [[ "$(grep -c . <<< "${pods}" || true)" == "${replicas}" ]] || bad+=$'\n'"  expected ${replicas} pod(s)"
  while IFS='|' read -r name revision pod_host deleting; do
    [[ -n "${name}" ]] || continue
    log "pod ${name}: revision ${revision}, SENZING_DATABASE_HOST ${pod_host:-<unset>}${deleting:+, terminating}"
    [[ "${revision}" == "${update}" ]] || bad+=$'\n'"  ${name} runs revision ${revision}, not ${update}"
    [[ "${pod_host}" != "${dst_name}" ]] || bad+=$'\n'"  ${name} uses ${dst_name}"
    [[ -z "${deleting}" ]] || bad+=$'\n'"  ${name} is terminating"
  done <<< "${pods}"
  [[ -z "${bad}" ]] || die "entity-resolution pods are not all on the Bitnami database:${bad}"

  sessions="$(dst_app_sessions)"
  [[ -z "${sessions}" ]] || die "application sessions are open on ${dst_pod}, refusing to drop its database:"$'\n'"${sessions}"
  sts_state="${state}"
}

# Hosts of the application user on the destination
app_user_hosts() {
  sql "${dst_pod}" "SELECT host FROM mysql.user WHERE user = '${app_user}'"
}

# Locks the application user of the destination and kills its sessions: until unfence_destination, a pod switched
# to the destination (Argo CD sync during the copy) cannot connect, so the drop/copy cannot erase its writes.
fenced=false
keep_fenced=false
fence_destination() {
  local hosts h ids
  hosts="$(app_user_hosts)"
  [[ -n "${hosts}" ]] || die "user ${app_user} not found on ${dst_pod}"
  log "locking user ${app_user} on ${dst_pod}"
  fenced=true
  for h in ${hosts}; do
    sql "${dst_pod}" "ALTER USER '${app_user}'@'${h}' ACCOUNT LOCK"
  done
  ids="$(sql "${dst_pod}" "SELECT id FROM information_schema.processlist WHERE user = '${app_user}' AND id <> CONNECTION_ID()")"
  for id in ${ids}; do
    sql "${dst_pod}" "KILL ${id}" 2>/dev/null || true
  done
}

# Checks that the destination stayed fenced and that entity-resolution did not change during the copy
ensure_fence_held() {
  local h
  for h in $(app_user_hosts); do
    sql "${dst_pod}" "SHOW CREATE USER '${app_user}'@'${h}'" | grep -q 'ACCOUNT LOCK' \
      || { keep_fenced=true; die "user ${app_user}@${h} was unlocked during the copy (operator reconcile?): the copy may not be consistent"; }
  done
  if [[ "$(er_sts_state)" != "${sts_state}" || "$(er_db_host)" == "${dst_name}" ]]; then
    keep_fenced=true
    die "statefulset ${er_sts} changed during the copy (switch or rollback in progress): ${app_user} stays locked on ${dst_pod}. Check which database entity-resolution must use, then unlock it with: ALTER USER '${app_user}'@'%' ACCOUNT UNLOCK"
  fi
}

unfence_destination() {
  local h
  ${fenced} || return 0
  if ${keep_fenced}; then
    log "user ${app_user} left locked on ${dst_pod}"
    return 0
  fi
  for h in $(app_user_hosts); do
    sql "${dst_pod}" "ALTER USER '${app_user}'@'${h}' ACCOUNT UNLOCK" || true
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
    die "row counts differ (< source, > destination)"
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

# Id of the source session holding the global read lock (empty if none)
lock_session_id() {
  sql "${src_pod}" "SELECT id FROM information_schema.processlist WHERE info LIKE CONCAT('%', 'er-migration', '-lock', '%') AND id <> CONNECTION_ID()"
}

lock_pid=""
lock_id=""
# Time (epoch) by which the cutover must be done, set when the lock is taken. The lock session sleeps
# lock_margin seconds longer, so it outlives every step of the script; it only expires on its own if the script
# dies without releasing it (kill -9, lost laptop...), which bounds how long the source can stay locked.
lock_deadline=0
lock_margin=600
lock_source() {
  local id=""
  log "taking the global read lock on ${src_pod} (entity-resolution writes hang from now on, ${wait_minutes} min max)"
  # The session stays open (SLEEP) to keep the lock; it is killed by release_source.
  # SLEEP starts once FLUSH TABLES WITH READ LOCK returns, i.e. after the lock is taken.
  # shellcheck disable=SC2016
  kubectl -n "${namespace}" exec "${src_pod}" -c mariadb -- sh -c \
    "${remote_auth}"' exec "$(command -v mariadb || command -v mysql)" -uroot -N -B -e "$1"' sh \
    "FLUSH TABLES WITH READ LOCK; SELECT '${lock_marker}', SLEEP($(( wait_minutes * 60 + lock_margin )))" >/dev/null &
  lock_pid=$!
  for _ in $(seq 1 60); do
    id="$(lock_session_id)"
    [[ -n "${id}" ]] && break
    kill -0 "${lock_pid}" 2>/dev/null || die "the session taking the lock ended"
    sleep 1
  done
  [[ -n "${id}" ]] || die "could not take the global read lock in 60s (long running query on ${src_pod}?)"
  lock_id="${id}"
  lock_deadline=$(( $(date +%s) + wait_minutes * 60 ))
  log "global read lock held by session ${lock_id}, until $(date -r "${lock_deadline}" +%H:%M:%S 2>/dev/null || date -d "@${lock_deadline}" +%H:%M:%S)"
}

# True while the lock is held: the local kubectl exec is alive and the same session is still sleeping on the
# source. A failed check is retried, so that a transient API error does not abort the cutover.
lock_held() {
  local _try
  for _try in 1 2 3; do
    kill -0 "${lock_pid}" 2>/dev/null || return 1
    [[ "$(lock_session_id 2>/dev/null || true)" == "${lock_id}" ]] && return 0
    sleep 2
  done
  return 1
}

# Aborts the cutover if the lock is lost or about to expire. Writes may have resumed on the source after the
# dump: the destination user is (re)locked and left locked, so that no pod switched to the copy can use it.
ensure_lock_held() {
  local step="$1"
  if ! lock_held; then
    keep_fenced=true
    ${fenced} || fence_destination
    die "global read lock lost on ${src_pod} ${step}: writes may have resumed there after the copy.
    ${app_user} stays locked on ${dst_pod}. If mariadbOperator.primary=true was merged, revert it and wait for
    the rollout, then run cutover again."
  fi
  if (( $(date +%s) >= lock_deadline )); then
    keep_fenced=true
    ${fenced} || fence_destination
    die "the ${wait_minutes} min of the lock ran out ${step}. ${app_user} stays locked on ${dst_pod}.
    If mariadbOperator.primary=true was merged, revert it and wait for the rollout, then run cutover again (-t)."
  fi
}

release_source() {
  local id
  [[ -n "${lock_pid}" ]] || return 0
  id="$(lock_session_id || true)"
  if [[ -n "${id}" ]]; then
    sql "${src_pod}" "KILL ${id}" || true
    log "global read lock released on ${src_pod}"
  fi
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

# Waits, until lock_deadline, for the statefulset to point to the destination and be rolled out, checking the
# lock at every step
wait_for_switch() {
  cat >&2 <<EOF
==> copy done and checked, ${src_pod} is still locked.
    Now set mariadbOperator.primary=true and let Argo CD sync. Waiting until $(date -r "${lock_deadline}" +%H:%M:%S 2>/dev/null || date -d "@${lock_deadline}" +%H:%M:%S) for
    statefulset ${er_sts} to use ${dst_name}... (Ctrl-C releases the lock, entity-resolution stays on Bitnami)
EOF
  until [[ "$(er_db_host)" == "${dst_name}" ]]; do
    ensure_lock_held "while waiting for the switch"
    sleep 10
  done
  log "${er_sts} is configured to use ${dst_name}, waiting for the rollout"
  until kubectl -n "${namespace}" rollout status "statefulset/${er_sts}" --timeout=10s >/dev/null 2>&1; do
    if ! lock_held; then
      die "global read lock lost on ${src_pod} during the rollout: writes may have reached it after the copy.
    ${er_sts} already points to ${dst_name}: compare both databases ('check') before going on."
    fi
    (( $(date +%s) < lock_deadline )) \
      || die "rollout of ${er_sts} not finished in time: check its pod, it already points to ${dst_name}"
  done
  log "rollout of ${er_sts} done"
  # The previous pod is gone: if the lock was still held, no write reached the source after the copy
  lock_held || die "global read lock lost on ${src_pod} before the end of the rollout: writes may have reached it
    after the copy. ${er_sts} already points to ${dst_name}: compare both databases ('check') before going on."
}

case "${command}" in
  check)
    preflight
    log "entity-resolution SENZING_DATABASE_HOST (template): $(er_db_host)"
    log "statefulset ${er_sts} (generation|observed|replicas|ready|updated|currentRevision|updateRevision): $(er_sts_state)"
    log "pods (name|revision|SENZING_DATABASE_HOST|deletionTimestamp):"; er_pods >&2
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
    unfence_destination
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
    unfence_destination
    wait_for_switch
    kill_source_clients
    release_source
    log "cutover done: ${er_sts} uses ${dst_name}. ${src_pod} is no longer used."
    log "rollback: set mariadbOperator.primary=false (writes made on ${dst_name} since the switch would be lost)"
    ;;
  *)
    usage
    ;;
esac
