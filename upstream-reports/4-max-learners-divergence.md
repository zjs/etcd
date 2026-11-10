# Issue for etcd-io/etcd

Each `###` section below is one field of the bug report form; paste what is
under the heading, not the heading. Tick the four "Bug report criteria" boxes
in the form itself. Three fields come prefilled and the last one renders as a
code block; those sections say what to do.

**Title:** Raising `--max-learners` one member at a time can make members disagree on membership, then crash-loop

### What happened?

`--max-learners` is a per-member flag. Its help text says "the maximum number of learners that can be available in the cluster membership", but each member enforces its own value. It is checked when a learner add is *applied* (`RaftCluster.ValidateConfigurationChange`), so members with different values decide differently on the same committed `ConfChangeAddLearnerNode`:

- members whose limit allows it add the learner;
- the others apply it as a no-op (`Validation on configuration change failed ... too many learner members in cluster`).

Members legitimately run different values while an operator raises the limit by restarting members one at a time. A learner added during that window reaches only some members' membership and raft configuration.

Starting that learner then crashes the other members. When it publishes its attributes, they apply a `ClusterMemberAttrSet` for a member they neither know nor have removed, and panic:

```
"level":"panic","caller":"membership/cluster.go:481","msg":"failed to update; member unknown"
```

They panic again on every restart: the entry is above their consistent index, so it is replayed. Raising their flag doesn't help, because their stored membership lacks the learner. In a 3-member cluster where one member had been restarted with the higher limit, the other two crash-loop and the cluster has no quorum. Recovery needs `--force-new-cluster` on the remaining member or a snapshot restore.

### What did you expect to happen?

Every member makes the same decision for a committed conf change, whatever its local flags. Changing `--max-learners` one member at a time should not be able to split membership or take members down.

### How can we reproduce it (as minimally and precisely as possible)?

The script below needs only bash and stock `etcd` and `etcdctl` binaries, and takes about 30 seconds. Save it as `repro.sh` and run it from an etcd checkout after `make build`. It:

1. starts 3 members with `--max-learners=1`;
2. restarts m1 with `--max-learners=2` and moves leadership to it;
3. adds two learners through m1;
4. starts the second learner;
5. restarts m2.

```
$ ETCD_BIN_DIR=./bin ./repro.sh
--- raise --max-learners to 2 on m1 only (the first member restarted)
--- waiting 6s so peers count as connected for HealthInterval (5s)
--- add two learners through m1
member list on m1:
    a4b228137be5f2e (not started) learner
    31239b86612d3435 (not started) learner
    61f97220ab052a12 m3 voter
    69b38ac7138de88d m1 voter
    9e737febb6b99eee m2 voter
member list on m2:
    a4b228137be5f2e (not started) learner
    61f97220ab052a12 m3 voter
    69b38ac7138de88d m1 voter
    9e737febb6b99eee m2 voter
member list on m3:
    a4b228137be5f2e (not started) learner
    61f97220ab052a12 m3 voter
    69b38ac7138de88d m1 voter
    9e737febb6b99eee m2 voter
"msg":"Validation on configuration change failed","shouldApplyV3":true,"error":"membership: too many learner members in cluster"
--- start l2 (as configured on m1). It must fetch the membership from m1, whose peer URL sorts first.
m2: exited
"level":"panic","ts":"2026-11-10T15:07:45.048959Z","caller":"membership/cluster.go:481","msg":"failed to update; member unknown"
m3: exited
"level":"panic","ts":"2026-11-10T15:07:45.048863Z","caller":"membership/cluster.go:481","msg":"failed to update; member unknown"
--- restart m2: it replays the same entry
m2: exited again after restart
RESULT: 2 of 3 voters down; no quorum (bug reproduced)
```

<details>
<summary>repro.sh</summary>

```bash
#!/usr/bin/env bash
# Reproduces: members with different --max-learners decide differently on the
# same learner add, for example while the limit is being raised by restarting
# members one at a time. Their membership diverges, and starting the learner
# that only some members accepted makes the others panic, again on restart.
#
# Usage: ETCD_BIN_DIR=/path/to/etcd/bin ./repro.sh
# ETCD_BIN_DIR must contain etcd and etcdctl (default: ./bin). Runs local
# members on 127.0.0.1, ports 21379-25380, with data in a temporary directory
# that is removed on exit (set KEEP=1 to keep it).
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
```

</details>

### Anything else we need to know?

- **Affected versions.** 3.6.x, 3.7.x and main. 3.5 is not affected: the limit is a constant there.
- **Safe procedure today.** Don't add learners until every member runs the new `--max-learners`. This isn't documented; documenting it is the smallest mitigation, and the only one available to existing releases.
- **No candidate fix yet.** I tried enforcing the limit only when proposing. It removes the divergence, but members with the lower flag then hold more learners than their flag allows and fail the existing startup check on restart, and concurrent adds can overshoot the limit.
- **Options.** Any option that changes the apply-time decision has to be gated on cluster version, so that members of different versions still agree.
  1. Make the limit cluster-wide state: stored in the membership, set through raft, and checked at apply against the replicated value. Cleanest semantics; needs an API and a migration story.
  2. Publish each member's limit in its attributes (a new field in `ClusterMemberAttrSet`) and check against the minimum published by the current voters. The old, lower limit applies until every member has restarted, and the startup checks keep passing.
  3. Carry the proposer's limit in the conf change and check that at apply. Deterministic, but it has the restart problem above, so the startup check would have to become a warning.
  4. Refuse learner adds while members' published limits differ. Simple, but it blocks adds while the flag is being changed.
- **Maintainer input needed.** I'm not sure which of those is best (I lean towards 2, or 1 if you want the limit to be a cluster setting), so I'm holding off on a PR.
- **Lessons learned so far:**
  - The reproduction depends on the order in which things happen. The adds must go through m1, m1 must be the leader when the learner starts, and the learner must fetch the membership from m1 (it takes the first peer that answers, in sorted-URL order); otherwise it fails to join with a membership mismatch instead.
  - The panic is what stops this from going further. With the panic replaced by a log line on an in-process cluster, the extra learners could be promoted through m1, giving m1 voters {m1,m2,m3,l1,l2} while m2 and m3 have {m1,m2,m3}; majorities {m1,l1,l2} and {m2,m3} don't intersect. So the panic should stay until membership can't diverge.
  - #13377, which added the flag (as `--experimental-max-learners`), also added startup checks (at join, and on every restart). They compare the local flag with the current learner count, not with other members' flags, so they don't catch this. They do constrain any fix: a member whose flag is lower than the number of learners in its membership refuses to start.
- **Related:** #16002 (closed as stale) reached the same panic by a different route: a new member whose DNS name resolved to an existing member.
- **AI disclosure.** This was found by an AI agent (Claude Code) that I directed to model this part of etcd in TLA+ and check the model against the code. The agent also wrote the reproduction and the first draft of this report. I have run the reproduction and read the code paths described here, and I'll answer questions myself. If you accept this issue as valid and tell me which option you prefer, I'll open a PR for it.

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

`--max-learners=1` on m2 and m3, `--max-learners=2` on m1 and the second learner; otherwise defaults. See the script.

</details>

### Etcd debug information (please run commands below, feel free to obfuscate the IP address or FQDN in the output)

Replace the field's prefilled text with:

N/A: local reproduction; see the script output above.

### Relevant log output

This field renders as a code block by itself, so paste only the text below, with no backticks (first line from m2 when the second learner is added, second line from m2 when that learner starts):

"msg":"Validation on configuration change failed","shouldApplyV3":true,"error":"membership: too many learner members in cluster"
"level":"panic","ts":"2026-11-10T15:07:45.048959Z","caller":"membership/cluster.go:481","msg":"failed to update; member unknown"
