#!/usr/bin/env bash
# Reproduces: members with different --max-learners decide differently on
# the same learner add. This happens, for example, while raising the limit
# by restarting members one at a time. Their membership diverges, and
# starting the learner that only some members accepted makes the others
# panic, again on every restart.
#
# Expected on affected versions (3.6, 3.7, main):
#   member lists differ; m2 and m3 exit with "failed to update; member unknown",
#   and exit again when restarted.
source "$(dirname "$0")/lib.sh"

IC="m1=$(peer_url 1),m2=$(peer_url 2),m3=$(peer_url 3)"
for i in 1 2 3; do start "m${i}" "${i}" "${IC}" new --max-learners=1; done
wait_healthy 1 2 3

log "raise --max-learners to 2 on m1 only (the first member restarted)"
stop m1
start m1 1 "${IC}" new --max-learners=2
wait_healthy 1
M1=$(id_of 1 m1)
for s in 2 3; do is_leader "${s}" && ctl "${s}" move-leader "${M1}" >/dev/null; done
for _ in $(seq 1 25); do is_leader 1 && break; sleep 0.2; done
log "waiting 6s so peers count as connected for HealthInterval (5s)"
sleep 6

log "add two learners through m1"
ctl 1 member add l1 --learner --peer-urls "$(peer_url 4)" >/dev/null || exit 1
ctl 1 member add l2 --learner --peer-urls "$(peer_url 5)" >/dev/null || exit 1
sleep 1
for s in 1 2 3; do
  echo "member list on m${s}:"; ctl "${s}" member list --consistency=s | awk -F', ' '{print "   ", $1, ($3 == "" ? "(not started)" : $3), ($6 == "true" ? "learner" : "voter")}'
done
grep -ho '"msg":"Validation on configuration change failed","shouldApplyV3":true,"error":"[^"]*"' "${WORK}"/m2.log | head -1

log "start l2 (as configured on m1). It must fetch the membership from m1, whose peer URL sorts first."
start l2 5 "${IC},l1=$(peer_url 4),l2=$(peer_url 5)" existing --max-learners=2
sleep 5
for n in m2 m3; do
  if kill -0 "${PIDS[$n]}" 2>/dev/null; then echo "${n}: running"; else echo "${n}: exited"; unset "PIDS[$n]"; fi
  grep -ho '"level":"panic"[^}]*"msg":"failed to update; member unknown"' "${WORK}/${n}.log" | head -1
done

log "restart m2: it replays the same entry"
start m2 2 "${IC}" new --max-learners=1
sleep 5
if kill -0 "${PIDS[m2]}" 2>/dev/null; then echo "m2: running after restart"; else echo "m2: exited again after restart"; unset "PIDS[m2]"; fi

if ctl 1 put foo bar >/dev/null 2>&1; then echo "RESULT: cluster has a quorum"; else echo "RESULT: 2 of 3 voters down; no quorum (bug reproduced)"; fi
