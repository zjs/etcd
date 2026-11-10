# Issue for etcd-io/etcd

Each `###` section below is one field of the bug report form; paste what is
under the heading, not the heading. Tick the four "Bug report criteria" boxes
in the form itself. Three fields come prefilled and the last one renders as a
code block; those sections say what to do.

**Title:** StrictReconfigCheck evaluates member add/remove against the receiving member's possibly stale membership

### What happened?

`mayAddMember` and `mayRemoveMember` run on whichever member receives the request, against that member's local membership, without waiting for it to apply entries that are already committed. A follower that hasn't yet applied a committed membership change checks the next change against the old membership, and can accept a change the leader would refuse.

Two cases, each starting from 4 voters with one down:

**Remove** (release-3.4 to release-3.7, and main):
1. Remove a running voter B through the leader. Result: 3 voters, 2 up. Accepted.
2. Remove follower S through S itself, before S has applied step 1. S still counts 4 voters with B connected, so it accepts. Result: 2 voters, 1 up.

**Add** (v3.5.30+, v3.6.11+, v3.7.x and main; it needs the quorum-after-add check from #21641):
1. Add voter n0 (not yet started) through the leader. Result: 5 voters, 3 up. Accepted.
2. Add voter n1 through a follower that hasn't applied step 1. It sees 4 voters and accepts. Result: 6 voters, 3 up, quorum 4.

In both cases writes fail until enough members are started again.

The window is the follower's apply lag: short, but a client with several endpoints routinely sends consecutive member commands to different members. Both cases also depart from the documented reconfiguration procedure, which is the kind of mistake the check exists to catch, and does catch when the request reaches the leader.

This is an availability loss only; there is no data or safety impact.

### What did you expect to happen?

With `--strict-reconfig-check`, a change that the leader would refuse is refused whichever member receives it.

### How can we reproduce it (as minimally and precisely as possible)?

The existing failpoint `beforeApplyOneConfChange` delays one follower's apply by 500ms, which is below the election timeout. The script below needs bash, `curl`, and `etcd` and `etcdctl` built with failpoints. Save it as `repro.sh` and run it from an etcd checkout after `make gofail-enable && make build`:

```
$ ETCD_BIN_DIR=./bin ./repro.sh add
--- leader m1; stopping m3; m2 will apply the next change late
--- waiting 6s so peers count as connected for HealthInterval (5s)
--- add voter n0 (not started) through the leader: 5 voters, 3 up
--- add voter n1 through m2: 6 voters, 3 up
--- accepted
RESULT: write failed after the second change; quorum lost (bug reproduced)

$ ETCD_BIN_DIR=./bin ./repro.sh remove
--- leader m2; stopping m3; m1 will apply the next change late
--- waiting 6s so peers count as connected for HealthInterval (5s)
--- remove m4 through the leader: 3 voters, 2 up
--- remove m1 through m1 itself: 2 voters, 1 up
--- members now, as seen by the leader:
61f97220ab052a12, started, m3, http://127.0.0.1:23380, http://127.0.0.1:23379, false
9e737febb6b99eee, started, m2, http://127.0.0.1:22380, http://127.0.0.1:22379, false
RESULT: write failed after the second change; quorum lost (bug reproduced)
```

<details>
<summary>repro.sh</summary>

```bash
#!/usr/bin/env bash
# Reproduces: the strict reconfig checks for member add/remove run on the
# receiving member's local membership, which may not include a change that is
# already committed. A second change through such a member can leave the
# cluster without a quorum.
#
# Needs etcd built with failpoints (make gofail-enable && make build). The
# script delays one follower's apply of membership changes by 500ms with the
# existing failpoint beforeApplyOneConfChange (for remove, also the removed
# member's), to make the window wide enough to hit by hand.
#
# Usage: ETCD_BIN_DIR=/path/to/etcd/bin ./repro.sh add|remove
# ETCD_BIN_DIR must contain etcd and etcdctl (default: ./bin). Runs four local
# members on 127.0.0.1, ports 21379-24381, with data in a temporary directory
# that is removed on exit (set KEEP=1 to keep it).
set -uo pipefail
MODE="${1:-add}"

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
failpoint_url() { echo "http://127.0.0.1:2${1}381/beforeApplyOneConfChange"; }

# start <name> <slot 1-9> <initial-cluster>
start() {
  local name=$1 slot=$2 ic=$3
  GOFAIL_HTTP="127.0.0.1:2${slot}381" "${ETCD}" --name "${name}" --data-dir "${WORK}/${name}" \
    --listen-client-urls "$(client_url "${slot}")" --advertise-client-urls "$(client_url "${slot}")" \
    --listen-peer-urls "$(peer_url "${slot}")" --initial-advertise-peer-urls "$(peer_url "${slot}")" \
    --initial-cluster "${ic}" --initial-cluster-state new \
    >>"${WORK}/${name}.log" 2>&1 &
  PIDS[${name}]=$!
}

stop() { kill -9 "${PIDS[$1]}" 2>/dev/null; wait "${PIDS[$1]}" 2>/dev/null; unset "PIDS[$1]"; }

ctl() { local slot=$1; shift; "${ETCDCTL}" --endpoints "$(client_url "${slot}")" --command-timeout=5s "$@"; }

wait_healthy() {
  for s in "$@"; do
    for _ in $(seq 1 50); do ctl "${s}" endpoint health >/dev/null 2>&1 && break; sleep 0.2; done
  done
}

# is_leader <slot>: true if the member at <slot> is the leader
is_leader() {
  local j; j=$(ctl "$1" endpoint status -w json) || return 1
  [[ "$(grep -oE '"member_id":[0-9]+' <<<"${j}" | head -1 | cut -d: -f2)" == \
     "$(grep -oE '"leader":[0-9]+' <<<"${j}" | head -1 | cut -d: -f2)" ]]
}

# id_of <slot> <name>: hex member ID of <name>, from the member list at <slot>
id_of() { ctl "$1" member list | awk -F', ' -v n="$2" '$3 == n {print $1}'; }

log() { echo "--- $*"; }

IC="m1=$(peer_url 1),m2=$(peer_url 2),m3=$(peer_url 3),m4=$(peer_url 4)"
for i in 1 2 3 4; do start "m${i}" "${i}" "${IC}"; done
wait_healthy 1 2 3 4

LEAD=""; for s in 1 2 3 4; do is_leader "${s}" && LEAD=${s}; done
OTHERS=(); for s in 1 2 3 4; do [[ ${s} != "${LEAD}" ]] && OTHERS+=("${s}"); done
STALE=${OTHERS[0]}; DOWN=${OTHERS[1]}; OTHER=${OTHERS[2]}
STALE_ID=$(id_of "${LEAD}" "m${STALE}"); OTHER_ID=$(id_of "${LEAD}" "m${OTHER}")
log "leader m${LEAD}; stopping m${DOWN}; m${STALE} will apply the next change late"
stop "m${DOWN}"
log "waiting 6s so peers count as connected for HealthInterval (5s)"
sleep 6
curl -sf -X PUT -d 'sleep(500)' "$(failpoint_url "${STALE}")" || { echo "failpoints not available; build with make gofail-enable" >&2; exit 2; }

if [[ "${MODE}" == add ]]; then
  log "add voter n0 (not started) through the leader: 5 voters, 3 up"
  ctl "${LEAD}" member add n0 --peer-urls http://127.0.0.1:29001 >/dev/null || exit 1
  log "add voter n1 through m${STALE}: 6 voters, 3 up"
  if ctl "${STALE}" member add n1 --peer-urls http://127.0.0.1:29002 >/dev/null; then log "accepted"; else log "refused"; fi
else
  # The removed member closes its connections as soon as it applies its own
  # removal; delay that too, so the stale member still counts it as connected.
  curl -sf -X PUT -d 'sleep(500)' "$(failpoint_url "${OTHER}")" || exit 2
  log "remove m${OTHER} through the leader: 3 voters, 2 up"
  ctl "${LEAD}" member remove "${OTHER_ID}" >/dev/null || exit 1
  log "remove m${STALE} through m${STALE} itself: 2 voters, 1 up"
  # A member removing itself may stop before it replies, so judge by the
  # membership and the final write, not by this command's result.
  ctl "${STALE}" member remove "${STALE_ID}" >/dev/null 2>&1
  sleep 1
  log "members now, as seen by the leader:"; ctl "${LEAD}" member list --consistency=s
fi
curl -sf -X DELETE "$(failpoint_url "${STALE}")" >/dev/null

if ctl "${LEAD}" put foo bar >/dev/null 2>&1; then
  echo "RESULT: cluster still has a quorum (not affected, or fixed)"
else
  echo "RESULT: write failed after the second change; quorum lost (bug reproduced)"
fi
```

</details>

### Anything else we need to know?

- **Candidate fix, partial.** One commit on main at d622ec5, with an e2e test (`TestMemberReconfigStaleView`, add and remove):
  https://github.com/etcd-io/etcd/compare/main...zjs:etcd:report/reconfig-check-stale-view
  Before running the checks it waits for a linearizable read barrier, as linearizable `MemberList` does, so the checks see every committed change. Cost: one ReadIndex round trip per add or remove. With it, the stale member refuses the second change in both modes of the script (`unhealthy cluster`), and both end with `RESULT: cluster still has a quorum`.
- **What it doesn't cover.** A change checked on a follower *before* the previous change has committed still passes the barrier, and its proposal can reach the leader after the leader has applied the previous one. Closing that needs the check serialised with raft's one-change-at-a-time rule. I see two ways:
  1. forward add and remove to the leader and check there, as promote does;
  2. carry what was checked in the conf change and reject at apply.
- **Direction is the maintainers' call.** Which of those you'd accept decides whether the barrier is worth merging on its own or should be replaced, so I'm holding off on a PR until then.
- **If you'd like to work on this,** please start from the branch above rather than from scratch, and feel free to review it, test it or build on it; I'd rather coordinate than duplicate. Two things that cost me time and aren't obvious:
  - To reproduce the remove case, the removed member's apply has to be delayed as well. Otherwise it closes its connections as soon as it applies its own removal, and the stale member no longer counts it as connected.
  - Option 2 has a precondition. Replaying a rejected remove on restart still runs its side effects (stopping the member, removing the peer), because `applyConfChange` skips validation when `shouldApplyV3` is false. That doesn't matter today, since a valid remove is never rejected.
- **Related:** #22758 (promote has no reachability check; same question of where these checks should run), #21640 and #21641 (the add check), #16798.
- **AI disclosure.** This was found by an AI agent (Claude Code) that I directed to model this part of etcd in TLA+ and check the model against the code. The agent also wrote the reproduction, the linked branch and the first draft of this report. I have run the reproduction and read the code paths described here, and I'll answer questions myself. If you accept this issue as valid and tell me which direction you prefer, I'll open a PR for it.

### Etcd version (please run commands below)

Replace the field's prefilled text with:

<details>

```console
$ etcd --version
etcd Version: 3.8.0-alpha.0
Git SHA: d622ec5
Go Version: go1.27.3
Go OS/Arch: linux/amd64

$ etcdctl version
etcdctl version: 3.8.0-alpha.0
API version: 3.8
```

</details>

### Etcd configuration (command line flags or environment variables)

Replace the field's prefilled text with:

<details>

Defaults (`--strict-reconfig-check=true`); four members on localhost, built with failpoints. See the script.

</details>

### Etcd debug information (please run commands below, feel free to obfuscate the IP address or FQDN in the output)

Replace the field's prefilled text with:

N/A: local reproduction; see the script output above.

### Relevant log output

This field renders as a code block by itself, so paste only the next line, with no backticks. It is from the stale follower, with the candidate fix applied:

"msg":"rejecting member add request; local member has not been connected to majority peers, reconfigure breaks active quorum"
