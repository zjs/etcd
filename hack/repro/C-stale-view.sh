#!/usr/bin/env bash
# Reproduces: the strict reconfig checks for member add/remove run on the
# receiving member's local membership, which may not include a change that
# is already committed. A second change through such a member can leave the
# cluster without a quorum.
#
# Needs etcd built with failpoints (make gofail-enable && make build): the
# script delays a follower's apply of membership changes by 500ms with the
# existing failpoint beforeApplyOneConfChange (for remove, also the removed
# member's), to make the window wide enough to hit by hand.
#
# Usage: ETCD_BIN_DIR=./bin ./C-stale-view.sh add|remove
# Expected on affected versions: the second change is accepted and the final
# write times out. With the fix: "unhealthy cluster", and the write succeeds.
source "$(dirname "$0")/lib.sh"
MODE="${1:-add}"

IC="m1=$(peer_url 1),m2=$(peer_url 2),m3=$(peer_url 3),m4=$(peer_url 4)"
for i in 1 2 3 4; do GOFAIL_HTTP="127.0.0.1:2${i}381" start "m${i}" "${i}" "${IC}" new; done
wait_healthy 1 2 3 4

LEAD=""; for s in 1 2 3 4; do is_leader "${s}" && LEAD=${s}; done
OTHERS=(); for s in 1 2 3 4; do [[ ${s} != "${LEAD}" ]] && OTHERS+=("${s}"); done
STALE=${OTHERS[0]}; DOWN=${OTHERS[1]}; OTHER=${OTHERS[2]}
STALE_ID=$(id_of "${LEAD}" "m${STALE}"); OTHER_ID=$(id_of "${LEAD}" "m${OTHER}")
log "leader m${LEAD}; stopping m${DOWN}; m${STALE} will apply the next change late"
stop "m${DOWN}"
log "waiting 6s so peers count as connected for HealthInterval (5s)"
sleep 6
curl -sf -X PUT -d 'sleep(500)' "http://127.0.0.1:2${STALE}381/beforeApplyOneConfChange" || { echo "failpoints not available; build with make gofail-enable" >&2; exit 2; }

if [[ "${MODE}" == add ]]; then
  log "add voter n0 (not started) through the leader: 5 voters, 3 up"
  ctl "${LEAD}" member add n0 --peer-urls http://127.0.0.1:29001 >/dev/null || exit 1
  log "add voter n1 through m${STALE}: 6 voters, 3 up"
  ctl "${STALE}" member add n1 --peer-urls http://127.0.0.1:29002 && log "accepted" || log "refused"
else
  # The removed member closes its connections as soon as it applies its own
  # removal; delay that too, so m${STALE} still counts it as connected.
  curl -sf -X PUT -d 'sleep(500)' "http://127.0.0.1:2${OTHER}381/beforeApplyOneConfChange" || exit 2
  log "remove m${OTHER} through the leader: 3 voters, 2 up"
  ctl "${LEAD}" member remove "${OTHER_ID}" >/dev/null || exit 1
  log "remove m${STALE} through m${STALE} itself: 2 voters, 1 up"
  # A member removing itself may stop before it replies, so judge by the
  # membership and the final write, not by this command's result.
  ctl "${STALE}" member remove "${STALE_ID}"
  sleep 1
  log "members now, as seen by the leader:"; ctl "${LEAD}" member list --consistency=s
fi
curl -sf -X DELETE "http://127.0.0.1:2${STALE}381/beforeApplyOneConfChange" >/dev/null

if ctl "${LEAD}" put foo bar >/dev/null 2>&1; then
  echo "RESULT: cluster still has a quorum (not affected, or fixed)"
else
  echo "RESULT: write failed after the second change; quorum lost (bug reproduced)"
fi
