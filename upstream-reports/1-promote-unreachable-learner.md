# Issue for etcd-io/etcd

Each `###` section below is one field of the bug report form; paste what is
under the heading, not the heading. Tick the four "Bug report criteria" boxes
in the form itself. Three fields come prefilled and the last one renders as a
code block; those sections say what to do.

**Title:** StrictReconfigCheck allows promoting an unreachable learner, which can lose quorum

### What happened?

With `--strict-reconfig-check` (the default), member add and remove are refused when the result would leave too few *reachable* voters. Promote has no such check:

- `isLearnerReady` reads the leader's `Match` for the learner, which keeps its last value after the learner stops.
- `IsReadyToPromoteMember` counts voters that have *ever* started, and counts the learner as started.

So this sequence is accepted:

1. A 3-voter cluster has a learner that has caught up.
2. One voter goes down, and the learner stops.
3. An operator promotes the learner.

The promotion commits under the old configuration (2 of 3). The new configuration has 4 voters and needs 3, but only 2 are running. The leader steps down and writes fail until the learner or the down voter returns. If neither can return, recovery needs `--force-new-cluster` or a snapshot restore, because member remove itself needs quorum.

This is an availability loss only; there is no data or safety impact. It needs a double fault plus an operator action.

### What did you expect to happen?

The promotion is refused, as an add or remove that leaves the same number of reachable voters would be.

### How can we reproduce it (as minimally and precisely as possible)?

The script below needs only bash and stock `etcd` and `etcdctl` binaries, and takes about 20 seconds. Save it as `repro.sh` and run it from an etcd checkout after `make build`:

```
$ ETCD_BIN_DIR=./bin ./repro.sh
--- 3 voters up; waiting 6s so peers count as connected for HealthInterval (5s)
--- add and start a learner
--- stop voter m1 and the learner
--- write with 2 of 3 voters: ok
--- promote the stopped learner 13424acbc8d6cb90
Member 13424acbc8d6cb90 promoted in cluster f2cb1557076fcb4d
--- promote accepted
RESULT: write failed after the promote; quorum lost (bug reproduced)
Leader log:
"msg":"61f97220ab052a12 stepped down to follower since quorum is not active"
```

<details>
<summary>repro.sh</summary>

```bash
#!/usr/bin/env bash
# Reproduces: with --strict-reconfig-check (the default), MemberPromote accepts
# a caught-up learner that has stopped while a voter is down, and the cluster
# loses quorum.
#
# Usage: ETCD_BIN_DIR=/path/to/etcd/bin ./repro.sh
# ETCD_BIN_DIR must contain etcd and etcdctl (default: ./bin). Runs four local
# members on 127.0.0.1, ports 21379-24380, with data in a temporary directory
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

# start <name> <slot 1-9> <initial-cluster> <new|existing>
start() {
  local name=$1 slot=$2 ic=$3 state=$4
  "${ETCD}" --name "${name}" --data-dir "${WORK}/${name}" \
    --listen-client-urls "$(client_url "${slot}")" --advertise-client-urls "$(client_url "${slot}")" \
    --listen-peer-urls "$(peer_url "${slot}")" --initial-advertise-peer-urls "$(peer_url "${slot}")" \
    --initial-cluster "${ic}" --initial-cluster-state "${state}" \
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

# Stop one voter that is not the leader, and the learner.
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
```

</details>

### Anything else we need to know?

- **History.** The promote guard has been based on "ever started" since learners were added in v3.4.0. The code is the same on release-3.4 to release-3.7 and main.
- **Related, smaller.** A promote sent to a follower is forwarded to the leader. If the leader refuses with `ErrNotEnoughStartedMembers`, the follower doesn't recognise the error and retries until the request times out.
- **Candidate fix.** Branch [`zjs/etcd:report/promote-unreachable-learner`](https://github.com/zjs/etcd/tree/report/promote-unreachable-learner) (two commits on main at d622ec5). With strict reconfig check, it requires the voters connected for `HealthInterval`, plus the learner if connected now, to be a quorum of the new voting membership. It also returns the leader's refusal through a forwarding follower. With it, the script above ends with `promote refused` and `RESULT: cluster still has a quorum`. Two open questions:
  - The learner is only required to be connected *now*, not for `HealthInterval`. Requiring the interval broke `TestRuntimeReconfigGrowClusterSize`, because learners are commonly promoted right after catching up.
  - The check adds another consumer of `transport.ActiveSince`, so #22480 (peer status latching inactive) would cause false refusals here as it does for add and remove.
- **AI disclosure.** This was found by an AI agent (Claude Code) that I directed to model this part of etcd in TLA+ and check the model against the code. The agent also wrote the reproduction, the linked branch and the first draft of this report. I have run the reproduction and read the code paths described here, and I'll answer questions myself. If you accept this issue as valid and would find it useful, I'll open a PR based on the candidate fix above.

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

Defaults (`--strict-reconfig-check=true`); three members plus one learner on localhost. See the script.

</details>

### Etcd debug information (please run commands below, feel free to obfuscate the IP address or FQDN in the output)

Replace the field's prefilled text with:

N/A: local reproduction; see the script output above.

### Relevant log output

This field renders as a code block by itself, so paste only the next line, with no backticks:

"msg":"61f97220ab052a12 stepped down to follower since quorum is not active"
