#!/usr/bin/env bash
# Validate membership traces against verification/server/TraceEtcdMembership.tla.
# Usage: verification/tools/validate-membership-trace.sh [-c config.cfg] trace.ndjson...
# PASS = every line matched (TLC reports the TraceNotDone invariant violated).
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CFG="${ROOT}/server/TraceEtcdMembership.cfg"
if [[ "${1:-}" == "-c" ]]; then CFG="$(cd "$(dirname "$2")" && pwd)/$(basename "$2")"; shift 2; fi
"${ROOT}/tools/tlc.sh" --fetch-only
run() {
  local trace log
  trace="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
  log="${trace}.tlc.log"
  JSON="${trace}" "${ROOT}/tools/tlc.sh" -workers 1 \
    -config "${CFG}" "${ROOT}/server/TraceEtcdMembership.tla" > "${log}" 2>&1
  if grep -q "Invariant TraceNotDone is violated" "${log}"; then
    echo "PASS $(basename "${trace}")"
  else
    echo "FAIL $(basename "${trace}") ($(grep -m1 -oE 'furthest trace line matched", [0-9]+, "of", [0-9]+|Error: .*' "${log}")) see ${log}"
  fi
}
for t in "$@"; do run "$t" & done
wait
