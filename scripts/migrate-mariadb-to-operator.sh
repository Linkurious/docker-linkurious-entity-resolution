#!/usr/bin/env bash
# Copies the linkurious-entity-resolution database from the Bitnami MariaDB (<release>-mariadb) to the MariaDB run
# by the mariadb-operator (<release>-mariadb-op), both deployed by the chart (mariadbOperator.enabled=true).
#
# The dump is streamed from one pod to the other (kubectl exec | kubectl exec): no data is written locally.
# Only the application database is copied: users and grants of the destination are managed by the operator.
#
# Usage: scripts/migrate-mariadb-to-operator.sh [-n namespace] [-r release] [-d database] [-t minutes] [-y] <command>
#   check    show both databases (version, tables, row counts, users), changes nothing
#   copy     rehearsal: copy the data while entity-resolution keeps writing to the Bitnami database
#            (consistent snapshot, but writes made after it are not copied), then compare row counts
#   cutover  block the writes on the Bitnami database (global read lock), copy the data, compare row counts, then
#            wait (up to -t minutes, default 30) for entity-resolution to be restarted on the new database
#            (mariadbOperator.primary=true synced by Argo CD), and release the lock.
#            Entity-resolution writes hang while the lock is held. If the wait times out or the script is
#            interrupted, the lock is released and entity-resolution keeps using the Bitnami database.
#
# Entity-resolution connects to the Bitnami database as root, so `read_only` would not block its writes:
# FLUSH TABLES WITH READ LOCK does, and it is released as soon as the session holding it ends.
# The destination database is dropped and recreated by copy and cutover. To avoid erasing data written by
# entity-resolution, both refuse to run once it is configured to use the destination database.
set -euo pipefail

namespace="linkurious-entity-resolution-preprod"
release="linkurious-entity-resolution-develop"
database="linkurious"
wait_minutes=30
assume_yes=false

usage() { sed -n '2,21p' "$0" | sed 's/^# \{0,1\}//'; exit 1; }

while getopts "n:r:d:t:yh" opt; do
  case "${opt}" in
    n) namespace="${OPTARG}" ;;
    r) release="${OPTARG}" ;;
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
dst_name="${release}-mariadb-op"
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
}

ensure_destination_unused() {
  local host
  host="$(er_db_host)"
  log "entity-resolution SENZING_DATABASE_HOST: ${host:-<unset>}"
  [[ "${host}" != "${dst_name}" ]] \
    || die "entity-resolution already uses ${dst_name}: refusing to drop its database (set mariadbOperator.primary=false first)"
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
lock_source() {
  local id=""
  log "taking the global read lock on ${src_pod} (entity-resolution writes hang from now on)"
  # The session stays open (SLEEP) to keep the lock; it is killed by release_source
  # shellcheck disable=SC2016
  kubectl -n "${namespace}" exec "${src_pod}" -c mariadb -- sh -c \
    "${remote_auth}"' exec "$(command -v mariadb || command -v mysql)" -uroot -N -B -e "$1"' sh \
    "FLUSH TABLES WITH READ LOCK; SELECT '${lock_marker}', SLEEP($(( (wait_minutes + 10) * 60 )))" >/dev/null &
  lock_pid=$!
  for _ in $(seq 1 60); do
    id="$(lock_session_id)"
    [[ -n "${id}" ]] && break
    kill -0 "${lock_pid}" 2>/dev/null || die "the session taking the lock ended"
    sleep 1
  done
  [[ -n "${id}" ]] || die "could not take the global read lock in 60s (long running query on ${src_pod}?)"
  log "global read lock held by session ${id}"
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

wait_for_switch() {
  local deadline=$(( $(date +%s) + wait_minutes * 60 ))
  cat >&2 <<EOF
==> copy done and checked, ${src_pod} is still locked.
    Now set mariadbOperator.primary=true and let Argo CD sync. Waiting up to ${wait_minutes} min for
    statefulset ${er_sts} to use ${dst_name}... (Ctrl-C releases the lock, entity-resolution stays on Bitnami)
EOF
  until [[ "$(er_db_host)" == "${dst_name}" ]]; do
    (( $(date +%s) < deadline )) || die "timeout: ${er_sts} still uses $(er_db_host)"
    sleep 10
  done
  log "${er_sts} is configured to use ${dst_name}, waiting for the rollout"
  kubectl -n "${namespace}" rollout status "statefulset/${er_sts}" --timeout="$(( deadline - $(date +%s) ))s" >&2 \
    || die "rollout of ${er_sts} not finished: check its pod, it already points to ${dst_name}"
}

case "${command}" in
  check)
    preflight
    log "entity-resolution SENZING_DATABASE_HOST: $(er_db_host)"
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
    copy_data
    verify
    log "rehearsal done: writes made after the dump are not copied, run 'cutover' for the final copy"
    ;;
  cutover)
    preflight
    ensure_destination_unused
    confirm "Lock ${src_pod} (entity-resolution writes hang until the switch, ${wait_minutes} min max), drop ${database} on ${dst_pod} and copy it?"
    trap release_source EXIT
    trap 'exit 130' INT TERM
    lock_source
    copy_data
    verify
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
