# Issue for etcd-io/etcd

**Title:** StrictReconfigCheck evaluates member add/remove against the receiving member's possibly stale membership

### Bug report criteria

- [x] This bug report is not security related.
- [x] This is not a support request or question.
- [x] You have read the etcd bug reporting guidelines.
- [x] Existing open issues along with etcd FAQ have been checked and this is not a duplicate.

### What happened?

`mayAddMember` and `mayRemoveMember` run on whichever member receives the request, against that member's local membership, without waiting for it to apply entries that are already committed. A follower that hasn't yet applied a committed membership change checks the next change against the old membership, and can accept a change the leader would refuse.

Two cases, each starting from 4 voters with one down:

**Remove** (release-3.4 to release-3.7, and main):
1. Remove a running voter B through the leader. Result: 3 voters, 2 up. Accepted.
2. Remove follower S through S itself, before S has applied step 1. S still counts 4 voters with B connected, so it accepts. Result: 2 voters, 1 up.

**Add** (v3.5.30+, v3.6.11+, v3.7.x and main; needs the quorum-after-add check from #21641):
1. Add voter n0 (not yet started) through the leader. Result: 5 voters, 3 up. Accepted.
2. Add voter n1 through a follower that hasn't applied step 1. It sees 4 voters and accepts. Result: 6 voters, 3 up, quorum 4.

In both cases writes fail until enough members are started again.

The window is the follower's apply lag: short, but a client with several endpoints routinely sends consecutive member commands to different members. Both cases also depart from the documented reconfiguration procedure, which is the kind of mistake the check exists to catch, and does catch when the request reaches the leader.

### What did you expect to happen?

With `--strict-reconfig-check`, a change that the leader would refuse is refused whichever member receives it.

### How can we reproduce it (as minimally and precisely as possible)?

The existing failpoint `beforeApplyOneConfChange` delays one follower's apply by 500ms, below the election timeout. Build with `make gofail-enable && make build`, then run [`hack/repro/C-stale-view.sh add|remove`](https://github.com/zjs/etcd/blob/report/reconfig-check-stale-view/hack/repro/C-stale-view.sh):

```
$ ETCD_BIN_DIR=./bin hack/repro/C-stale-view.sh add
--- add voter n0 (not started) through the leader: 5 voters, 3 up
--- add voter n1 through m2: 6 voters, 3 up
--- accepted
RESULT: write failed after the second change; quorum lost (bug reproduced)
```

The branch also has an e2e test, `TestMemberReconfigStaleView`, with add and remove subtests.

### Anything else we need to know?

- **Candidate fix, partial.** Branch [`zjs/etcd:report/reconfig-check-stale-view`](https://github.com/zjs/etcd/tree/report/reconfig-check-stale-view) (one commit on main at d622ec5). Before running the checks it waits for a linearizable read barrier, as linearizable `MemberList` does, so the checks see every committed change. Cost: one ReadIndex round trip per add or remove. With the fix the script reports the second change refused with `unhealthy cluster`.
- **What it doesn't cover.** A change checked on a follower *before* the previous change has committed still passes the barrier, and its proposal can reach the leader after the leader has applied the previous one. Closing that needs the check serialised with raft's one-change-at-a-time rule: forward add/remove to the leader and check there, as promote does, or carry what was checked in the conf change and reject at apply. I'd like your view on which direction you'd accept before opening a PR; if you prefer checking on the leader, the barrier may not be worth merging on its own.
- **Related:** #21640, #21641, #16798.
- **AI disclosure.** [see README.md, "Disclosure"]

### Etcd version (please run commands below)

```
$ etcd --version
etcd Version: 3.8.0-alpha.0
Git SHA: d622ec5
```

### Etcd configuration (command line flags or environment variables)

Defaults; four members on localhost. See the script.

### Relevant log output

On the stale follower, with the candidate fix:

```
"msg":"rejecting member add request; local member has not been connected to majority peers, reconfigure breaks active quorum"
```
