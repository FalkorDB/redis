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


# Determine host & port
HOST="$(hostname)"

if $IS_SENTINEL; then
  PORT="${SENTINEL_PORT:-26379}"
else
  PORT="${NODE_PORT:-6379}"
fi

# Redis CLI base args
CLI=(redis-cli -h "$HOST" -p "$PORT")
if [[ -n "$REDIS_PASSWORD" ]]; then
  CLI+=(-a "$REDIS_PASSWORD")
fi

if [[ "$TLS_MODE" == "true" ]]; then
  CLI+=(--tls --cert "${REDIS_TLS_CERT}" --key "${REDIS_TLS_CERT_KEY}" --cacert "${REDIS_TLS_CA_KEY}")
fi

#Skip readiness and healthcheck if it is the first time creating the deployment
if [[ ! -f "/data/.redis-init" ]]; then
  touch "/data/.redis-init"
fi

if [[ ! -s "/data/.redis-init" && $(is_cluster_enabled) ]]; then
   out="$("${CLI[@]}" CLUSTER INFO 2>&1)" || true
   if grep -q '^cluster_state:ok' <<<"$out"; then
      echo 1 > /data/.redis-init
      return 0
    else
      echo "[readiness] cluster_state not ok yet" >&2
      return 0
   fi
fi

# Helpers
function check_sentinel() {
  [[ "$("${CLI[@]}" PING 2>/dev/null)" == "PONG" ]]
}

function is_cluster_enabled() {
  "${CLI[@]}" INFO | grep -q '^cluster_enabled:1'
}

cluster_state_ok() {
  local out
  out="$("${CLI[@]}" CLUSTER INFO 2>&1)" || true

  if grep -q '^cluster_state:ok' <<<"$out"; then
    return 0
  elif [[ "$MODE" == "liveness" ]]; then
    # Allow failed or empty state during cluster boot
    echo "[liveness] cluster_state not ok yet" >&2
    return 0
  else
    return 1
  fi
}


function check_master_liveness() {
  OUT="$("${CLI[@]}" PING 2>&1)" || true
  if [[ "$OUT" == "PONG" ]]; then
    return 0
  elif echo "$OUT" | grep -q 'BUSYLOADING'; then
    return 0
  else
    return 1
  fi
}

function check_master_readiness() {
  # PONG and loading:0
  PING_OK=$("${CLI[@]}" PING 2>/dev/null)
  INFO_OK=$("${CLI[@]}" INFO | grep -q '^loading:0' && echo yes)
  [[ "$PING_OK" == "PONG" && "$INFO_OK" == "yes" ]]
}

function check_slave_liveness() {
  OUT="$("${CLI[@]}" PING 2>&1)" || true
  if [[ "$OUT" == "PONG" ]]; then
    return 0
  elif echo "$OUT" | grep -Eq 'BUSYLOADING|MASTERDOWN'; then
    return 0
  else
    return 1
  fi
}

function check_slave_readiness() {
  PING_OK=$("${CLI[@]}" PING 2>/dev/null)
  INFO="$("${CLI[@]}" INFO)"
  grep -q '^loading:0'  <<<"$INFO" &&
  grep -q '^master_link_status:up' <<<"$INFO" &&
  grep -q '^master_sync_in_progress:0' <<<"$INFO" &&
  [[ "$PING_OK" == "PONG" ]]
}

function check_node_liveness() {
  ROLE=$("${CLI[@]}" INFO | grep -oP '^role:\K\w+')
  if [[ "$ROLE" == "master" ]]; then
    check_master_liveness
  else
    check_slave_liveness
  fi
}

function check_node_readiness() {
  ROLE=$("${CLI[@]}" INFO | grep -oP '^role:\K\w+')
  if [[ "$ROLE" == "master" ]]; then
    check_master_readiness
  else
    check_slave_readiness
  fi
}

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

# If we reach here and the last check returned true, exit 0
exit 0
