#!/usr/bin/env bash
# Shared helpers for the reproduction scripts in this directory.
#
# Usage: ETCD_BIN_DIR=/path/to/etcd/bin ./<script>.sh
# ETCD_BIN_DIR must contain etcd and etcdctl (default: ./bin). Each script
# runs local members on 127.0.0.1, ports 21379-29380, with data under a
# temporary directory that is removed on exit (set KEEP=1 to keep it).

set -uo pipefail

BIN="${ETCD_BIN_DIR:-./bin}"
ETCD="${BIN}/etcd"
ETCDCTL="${BIN}/etcdctl"
[[ -x "${ETCD}" && -x "${ETCDCTL}" ]] || { echo "etcd/etcdctl not found in ${BIN}; set ETCD_BIN_DIR" >&2; exit 2; }

WORK="$(mktemp -d)"
declare -A PIDS

cleanup() {
  for n in "${!PIDS[@]}"; do kill -9 "${PIDS[$n]}" 2>/dev/null; done
  wait 2>/dev/null
  if [[ "${KEEP:-0}" == 1 ]]; then echo "data and logs kept in ${WORK}"; else rm -rf "${WORK}"; fi
}
trap cleanup EXIT

client_url() { echo "http://127.0.0.1:2${1}379"; }
peer_url() { echo "http://127.0.0.1:2${1}380"; }

# start <name> <slot 1-9> <initial-cluster> <new|existing> [extra flags...]
start() {
  local name=$1 slot=$2 ic=$3 state=$4; shift 4
  "${ETCD}" --name "${name}" --data-dir "${WORK}/${name}" \
    --listen-client-urls "$(client_url "${slot}")" --advertise-client-urls "$(client_url "${slot}")" \
    --listen-peer-urls "$(peer_url "${slot}")" --initial-advertise-peer-urls "$(peer_url "${slot}")" \
    --initial-cluster "${ic}" --initial-cluster-state "${state}" "$@" \
    >>"${WORK}/${name}.log" 2>&1 &
  PIDS[${name}]=$!
}

stop() { kill -9 "${PIDS[$1]}" 2>/dev/null; wait "${PIDS[$1]}" 2>/dev/null; unset "PIDS[$1]"; }

ctl() { local slot=$1; shift; "${ETCDCTL}" --endpoints "$(client_url "${slot}")" --command-timeout=5s "$@"; }

wait_healthy() { # wait_healthy <slot>...
  for s in "$@"; do
    for _ in $(seq 1 50); do ctl "${s}" endpoint health >/dev/null 2>&1 && break; sleep 0.2; done
  done
}

is_leader() { # is_leader <slot>: true if the member at <slot> is the leader
  local j; j=$(ctl "$1" endpoint status -w json) || return 1
  [[ "$(grep -oE '"member_id":[0-9]+' <<<"${j}" | head -1 | cut -d: -f2)" == \
     "$(grep -oE '"leader":[0-9]+' <<<"${j}" | head -1 | cut -d: -f2)" ]]
}

id_of() { # id_of <slot> <name>: hex member ID of <name>, from the member list at <slot>
  ctl "$1" member list | awk -F', ' -v n="$2" '$3 == n {print $1}'
}

log() { echo "--- $*"; }
