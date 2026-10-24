#!/usr/bin/env bash
# Reproduces: with --strict-reconfig-check (default), MemberPromote accepts a
# caught-up learner that has stopped while a voter is down, and the cluster
# loses quorum.
#
# Expected on affected versions: the promote succeeds and the final write
# times out. Expected with the fix: the promote is refused ("unhealthy
# cluster") and the final write succeeds.
source "$(dirname "$0")/lib.sh"

IC="m1=$(peer_url 1),m2=$(peer_url 2),m3=$(peer_url 3)"
for i in 1 2 3; do start "m${i}" "${i}" "${IC}" new; done
wait_healthy 1 2 3
log "3 voters up; waiting 6s so peers count as connected for HealthInterval (5s)"
sleep 6

log "add and start a learner"
ctl 1 member add l --learner --peer-urls "$(peer_url 4)" >/dev/null || exit 1
start l 4 "${IC},l=$(peer_url 4)" existing
wait_healthy 4
ctl 1 put foo bar >/dev/null
sleep 2
LEARNER=$(id_of 1 l)

VOTERS=(1 2 3); DOWN=""
for s in "${VOTERS[@]}"; do is_leader "${s}" || { DOWN=${s}; break; }; done
UP=(); for s in "${VOTERS[@]}"; do [[ ${s} != "${DOWN}" ]] && UP+=("${s}"); done

log "stop voter m${DOWN} and the learner"
stop "m${DOWN}"; stop l
sleep 1
ctl "${UP[0]}" put foo baz >/dev/null && log "write with 2 of 3 voters: ok"

log "promote the stopped learner ${LEARNER}"
if ctl "${UP[0]}" member promote "${LEARNER}"; then
  log "promote accepted"
else
  log "promote refused"
fi

if ctl "${UP[0]}" put foo qux >/dev/null 2>&1; then
  echo "RESULT: cluster still has a quorum (not affected, or fixed)"
else
  echo "RESULT: write failed after the promote; quorum lost (bug reproduced)"
  sleep 2
  echo "Leader log:"; grep -ho '"msg":"[^"]*quorum is not active"' "${WORK}"/m*.log | tail -1
fi
