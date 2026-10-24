# Draft issue (etcd-io/etcd): StrictReconfigCheck allows promoting an unreachable learner, which can lose quorum

**What happened?**

With `--strict-reconfig-check` (the default), etcd refuses member add and
remove when the result would leave too few *reachable* voters. Promote has
no such check:

- `isLearnerReady` checks the leader's `Match` for the learner. `Match`
  keeps its last value after the learner stops.
- `IsReadyToPromoteMember` counts voters that have *ever* started
  (`IsStarted`), and counts the learner as started.

So the following sequence is accepted:
1. A 3-voter cluster has a learner that has caught up.
2. One voter goes down, and the learner stops.
3. An operator promotes the learner.

The promotion commits under the old configuration (2 of 3). The new
configuration has 4 voters and needs 3, but only 2 are running. The leader
steps down, and writes fail until the learner or the down voter returns.

```
"msg":"61f97220ab052a12 stepped down to follower since quorum is not active"
```

There is no data or safety impact; this is an availability loss.

- **Recovery:** bringing back the learner or the down voter restores
  quorum.
- **If neither can return** (e.g. the learner's node was decommissioned,
  which is why it stopped): member remove itself needs quorum, so recovery
  needs `--force-new-cluster` or a snapshot restore.

**What did you expect to happen?**

The promotion is refused, as an add or remove leaving the same number of
reachable voters would be.

**How can we reproduce it?**

A self-contained script (bash and stock `etcd`/`etcdctl`) is attached:
`B-promote-unreachable-learner.sh`. It:
1. starts 3 members and waits 6s (so peers count as connected for
   `HealthInterval`);
2. adds and starts a learner, and writes a key;
3. kills one non-leader voter and the learner, and writes a key (succeeds);
4. promotes the learner (succeeds);
5. writes a key (times out).

```
$ ETCD_BIN_DIR=./bin ./B-promote-unreachable-learner.sh
--- promote the stopped learner ca0c28ef0385c75e
Member ca0c28ef0385c75e promoted in cluster f2cb1557076fcb4d
RESULT: write failed after the promote; quorum lost (bug reproduced)
```

The preconditions are a double fault plus an operator action. The learner
must be added while all voters are up, because `mayAddMember` refuses even
a learner add with one of three voters down. Then a voter goes down and
the learner stops before the promote.

**Anything else we need to know?**

- **History:**
  - The promote guard has been based on "ever started" since learners were
    added (v3.4.0).
  - #11640 (v3.4.4) refined it, without adding a connectivity check.
  - The code is unchanged on v3.4.45, v3.5.35, v3.6.16, v3.7.3 and main
    (3aaab3479).
- **Related:** a promote sent to a follower is forwarded to the leader. If
  the leader refuses it with `ErrNotEnoughStartedMembers`, the follower
  doesn't recognize the error and retries until the request times out.
- **A fix is ready** for review: [link to PR]. It counts voters connected
  for `HealthInterval` plus the learner if connected now, as add and remove
  do.

**Etcd version (please run commands below)**

```
$ etcd --version
etcd Version: 3.8.0-alpha.0
Git SHA: 3aaab3479
```

**Etcd configuration (command line flags or environment variables)**

Defaults (`--strict-reconfig-check=true`), three members plus one learner
on localhost; see the script.

**Etcd debug information**

N/A.

**Relevant log output**

See above.

---

## PR description (draft)

**etcdserver: require a reachable quorum when promoting a learner**

Fixes #NNNN. Two commits:

1. **Return a forwarded promote's refusal instead of retrying.**
   - `ErrNotEnoughStartedMembers` and `ErrUnhealthy` now map to 412 in the
     peer promote handler.
   - The forwarding member recognizes them and returns them, instead of
     retrying until `ReqTimeout`.
   - Tests: `TestServeMemberPromoteErrors` and
     `TestPromoteMemberHTTPErrors`, both failing before.
2. **Require a reachable quorum when promoting a learner.**
   - With strict reconfig check, the voters connected for `HealthInterval`
     plus the learner if connected now must be a quorum of the new voting
     membership.
   - The check applies only when the target is a learner (promoting a voter
     is still refused when applied, with `ErrMemberNotLearner`).
   - Tests:
     - `TestIsConnectedToQuorumAfterPromotingSince`, a unit test;
     - `TestMemberPromoteUnreachableLearner`, an integration test. It
       expects the refusal on the leader and through a forwarding follower,
       then that promotion succeeds once the learner is back. It fails
       before the change.

Notes for review:
- **The learner isn't held to `HealthInterval`.**
  - It has just caught up (`isLearnerReady`), so the leader reached it
    moments ago.
  - Learners are often promoted right after catching up, less than
    `HealthInterval` after starting.
  - Requiring it broke `TestRuntimeReconfigGrowClusterSize` ("1 to 3 with
    learner").
- **"Connected" means no transport failure observed.** A peer that stops
  responding without closing its connection still counts until the
  transport notices (up to the 5s read/write timeouts). This is the same as
  for add and remove.
- **Mixed versions.**
  - A follower on an older version forwarding to a leader with this change keeps
    retrying until timeout on the new refusal. That is what it already does
    for `ErrNotEnoughStartedMembers` today.
  - The check runs on the leader, so there is no protection until the
    leader has the change.
- **Behavior change.** A promote can now return `Unavailable: unhealthy
  cluster` within `HealthInterval` of a voter reconnecting. The client
  doesn't auto-retry `MemberPromote`.
- **Alternative considered:** fold learner liveness into `isLearnerReady`
  (`ErrLearnerNotReady`). Old followers already stop retrying on it, but it
  would also apply without strict reconfig check.
- **Backports:** the helpers exist on release-3.5 to release-3.7. A
  CHANGELOG entry can be added once this has a PR number.
- **Tested:**
  - unit tests;
  - the integration `clientv3` member/promote tests with gofail enabled
    (including `TestMemberPromoteMemberNotLearner`);
  - `-race` on the new test;
  - e2e `TestRuntimeReconfigGrowClusterSize`, `TestReproduce20340`,
    `TestCtlV3MemberPromote*` and `TestMemberReplaceWithLearner`.
