#!/usr/bin/env bash
# Validate raft traces (NDJSON) against verification/raft/Traceetcdraft.tla.
#
# Usage: verification/tools/validate-trace.sh [-c config.cfg] trace.ndjson...
# Runs one TLC per trace (trace validation needs a single worker), in
# parallel, and prints PASS/FAIL per trace. Logs go next to each trace as
# <trace>.tlc.log.

set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CFG="${ROOT}/raft/Traceetcdraft.cfg"
if [[ "${1:-}" == "-c" ]]; then CFG="$(cd "$(dirname "$2")" && pwd)/$(basename "$2")"; shift 2; fi

run() {
  local trace log
  trace="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
  log="${trace}.tlc.log"
  JSON="${trace}" "${ROOT}/tools/tlc.sh" -workers 1 -lncheck final \
    -config "${CFG}" "${ROOT}/raft/Traceetcdraft.tla" > "${log}" 2>&1
  if grep -q "No error has been found" "${log}"; then
    echo "PASS $(basename "${trace}")"
  else
    echo "FAIL $(basename "${trace}") ($(grep -m1 -oE 'Error: .*|is violated' "${log}")) see ${log}"
  fi
}

"${ROOT}/tools/tlc.sh" --fetch-only
for t in "$@"; do run "$t" & done
wait
