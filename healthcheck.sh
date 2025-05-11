#!/bin/bash
set -eo pipefail

#
# healthcheck.sh <liveness|readiness> [sentinel]
#

MODE="$1"
IS_SENTINEL=false
if [[ "$2" == "sentinel" ]]; then
  IS_SENTINEL=true
fi

echo "[healthcheck] MODE=$MODE, IS_SENTINEL=$IS_SENTINEL" >&2

# Determine host & port
HOST="$(hostname)"
echo "[healthcheck] HOST=$HOST" >&2

if $IS_SENTINEL; then
  PORT="${SENTINEL_PORT:-26379}"
else
  PORT="${NODE_PORT:-6379}"
fi

echo "[healthcheck] PORT=$PORT" >&2

# Redis CLI base args, wrapped with timeout
CLI=(timeout -s 15 "${REDIS_TIMEOUT_SECONDS}" redis-cli -h "$HOST" -p "$PORT")
if [[ -n "$REDIS_PASSWORD" ]]; then
  CLI+=(-a "$REDIS_PASSWORD")
fi

if [[ "$TLS_MODE" == "true" ]]; then
  CLI+=(--tls --cert "${REDIS_TLS_CERT}" --key "${REDIS_TLS_CERT_KEY}" --cacert "${REDIS_TLS_CA_KEY}")
fi

echo "[healthcheck] CLI=${CLI[*]}" >&2

# Skip readiness and healthcheck if first time
if [[ ! -f "/data/.redis-init" ]]; then
  touch "/data/.redis-init"
  echo "[healthcheck] Initialized .redis-init flag" >&2
fi

# Helper to run Redis CLI with debug on stderr and clean stdout
function run_cli() {
  # debug to stderr
  echo "[healthcheck] Running: ${CLI[*]} $*" >&2
  # capture only command output
  local output
  if ! output=$("${CLI[@]}" "$@" 2>&1); then
    local status=$?
    echo "[healthcheck] Exit status: $status" >&2
    if [[ $status -eq 124 ]]; then
      echo "[healthcheck] ERROR: Command timed out after $REDIS_TIMEOUT_SECONDS seconds" >&2
    fi
    # print command output even on failure
    printf "%s\n" "$output"
    return $status
  fi
  local status=0
  echo "[healthcheck] Exit status: $status" >&2
  # print only output
  printf "%s\n" "$output"
  return 0
}

# Helpers
function check_sentinel() {
  echo "[healthcheck] check_sentinel" >&2
  [[ "$(run_cli PING)" == "PONG" ]]
}

function is_cluster_enabled() {
  echo "[healthcheck] is_cluster_enabled" >&2
  run_cli INFO | grep -q '^cluster_enabled:1'
}

function cluster_state_ok() {
  echo "[healthcheck] cluster_state_ok" >&2
  local out
  out="$(run_cli CLUSTER INFO)" || true
  echo "[healthcheck] CLUSTER INFO output: $out" >&2
  grep -q '^cluster_state:ok' <<<"$out"
}

function check_master_liveness() {
  echo "[healthcheck] check_master_liveness" >&2
  local out
  out="$(run_cli PING)" || true
  echo "[healthcheck] PING output: $out" >&2
  if [[ "$out" == "PONG" ]] || echo "$out" | grep -q 'BUSYLOADING'; then
    return 0
  else
    return 1
  fi
}

function check_master_readiness() {
  echo "[healthcheck] check_master_readiness" >&2
  local pong=$(run_cli PING)
  local load_ok
  run_cli INFO | grep -q '^loading:0'
  load_ok=$?
  echo "[healthcheck] PING=$pong, loading0? $load_ok" >&2
  [[ "$pong" == "PONG" && "$load_ok" -eq 0 ]]
}

function check_slave_liveness() {
  echo "[healthcheck] check_slave_liveness" >&2
  local out
  out="$(run_cli PING)" || true
  echo "[healthcheck] PING output: $out" >&2
  if [[ "$out" == "PONG" ]] || echo "$out" | grep -Eq 'BUSYLOADING|MASTERDOWN'; then
    return 0
  else
    return 1
  fi
}

function check_slave_readiness() {
  echo "[healthcheck] check_slave_readiness" >&2
  local pong=$(run_cli PING)
  local info
  info=$(run_cli INFO)
  echo "[healthcheck] INFO output: $info" >&2
  grep -q '^loading:0' <<<"$info" &&
  grep -q '^master_link_status:up' <<<"$info" &&
  grep -q '^master_sync_in_progress:0' <<<"$info" &&
  [[ "$pong" == "PONG" ]]
}

function check_node_liveness() {
  echo "[healthcheck] check_node_liveness" >&2
  local role=$(run_cli INFO | grep -oP '^role:\K\w+')
  echo "[healthcheck] role=$role" >&2
  if [[ "$role" == "master" ]]; then
    check_master_liveness
  else
    check_slave_liveness
  fi
}

function check_node_readiness() {
  echo "[healthcheck] check_node_readiness" >&2
  local role=$(run_cli INFO | grep -oP '^role:\K\w+')
  echo "[healthcheck] role=$role" >&2
  if [[ "$role" == "master" ]]; then
    check_master_readiness
  else
    check_slave_readiness
  fi
}

function check_if_cluster_first_time() {
  echo "[healthcheck] check_if_cluster_first_time" >&2
  if [[ ! -s "/data/.redis-init" ]]; then
    if is_cluster_enabled; then
      local out
      out="$(run_cli CLUSTER INFO)" || true
      echo "[healthcheck] First-time CLUSTER INFO: $out" >&2
      if grep -q '^cluster_state:ok' <<<"$out"; then
        echo 1 > /data/.redis-init
        exit 0
      else
        echo "cluster_state not ok yet" >&2
        exit 0
      fi
    fi
  fi
}

check_if_cluster_first_time

# Main dispatch
if $IS_SENTINEL; then
  check_sentinel
else
  if is_cluster_enabled; then
    cluster_state_ok
  else
    if [[ "$MODE" == "liveness" ]]; then
      check_node_liveness
    else
      check_node_readiness
    fi
  fi
fi

# If successful
echo "[healthcheck] Completed successfully" >&2
exit 0
