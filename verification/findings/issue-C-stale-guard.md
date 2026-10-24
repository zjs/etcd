# Draft issue (etcd-io/etcd): StrictReconfigCheck evaluates member add/remove against the receiving member's possibly stale membership

**What happened?**

With `--strict-reconfig-check` (the default), `mayAddMember` and
`mayRemoveMember` refuse a change that would leave too few reachable
voters. They run on whichever member receives the request, against that
member's local membership, and they don't wait for it to apply entries
that are already committed. A follower that hasn't yet applied a committed
membership change therefore checks the next change against the old
membership, and can accept a change that the leader would refuse.

Two concrete cases, each starting from 4 voters with one down:

**Remove** (all versions with the current remove guard: v3.4.x to v3.7.x,
and main):
1. Remove a running voter B through the leader. Result: 3 voters, 2 up.
   Accepted.
2. Remove follower S through S itself, before S has applied step 1. S
   still counts 4 voters with B connected, so it accepts. Result: 2 voters,
   1 up.

**Add** (v3.5.30+, v3.6.11+, v3.7.x and main; it needs the
quorum-after-add check from #21641):
1. Add voter n0 (not yet started) through the leader. Result: 5 voters,
   3 up. Accepted.
2. Add voter n1 through a follower that hasn't applied step 1. It sees 4
   voters, so it accepts. Result: 6 voters, 3 up, quorum 4.

In both cases, writes fail until enough members are started again
(n0/n1, or the down voter).

The window is the follower's apply lag. It is usually short, but routine:
clients with several endpoints spread consecutive member commands across
members. While a follower has a committed but unapplied conf change, its
raft loop waits for the apply, so its own proposal reaches the leader only
after it has applied the first change. By then the leader has applied it
too and accepts the second change.

**What did you expect to happen?**

With `--strict-reconfig-check`, a change that the leader would refuse is
refused, whichever member receives it.

**How can we reproduce it?**

The existing failpoint `beforeApplyOneConfChange` delays one follower's
apply by 500ms. That is well below the election timeout, so the leader
keeps its quorum, and wide enough to hit by hand. It needs binaries built
with `make gofail-enable && make build`.

- **e2e test:** `TestMemberReconfigStaleView` (in the PR), with add and
  remove subtests. It fails 6/6 on main and passes with the fix.
- **Script:** `C-stale-view.sh add|remove` (attached; bash plus `etcd` and
  `etcdctl`).

  ```
  $ ETCD_BIN_DIR=./bin ./C-stale-view.sh add
  --- add voter n0 (not started) through the leader: 5 voters, 3 up
  --- add voter n1 through m2: 6 voters, 3 up
  --- accepted
  RESULT: write failed after the second change; quorum lost (bug reproduced)
  ```

  For remove, the script also delays the removed member's apply.
  Otherwise it closes its connections as soon as it applies its own
  removal, which is faster than an etcdctl round trip.

**Anything else we need to know?**

- **Fix:** [link to PR]. Before running the checks, wait for a
  linearizable read barrier, as linearizable `MemberList` does. The checks
  then see every committed membership change. It is small and can be
  backported.
- **Residual case, not covered by the fix:** a change checked on a
  follower *before* the previous change has committed. The barrier passes,
  and the follower's proposal can still reach the leader after the leader
  has applied the previous change.
  - Closing this needs the check to be serialized with raft's own
    one-change-at-a-time rule. Options: forward add/remove to the leader
    and check there (as promote does), or carry what was checked in the
    conf change and reject at apply time.
  - The second option has a precondition. Replaying a rejected remove
    during restart currently still runs its side effects (stopping the
    member, removing the peer), because `applyConfChange` skips validation
    when `shouldApplyV3` is false. Today a valid remove is never rejected,
    so this doesn't matter; it would matter once one can be.
  - Happy to discuss this separately.
- **Practical likelihood:** both cases depart from the documented
  runtime-reconfiguration procedure. The add case adds a voter before the
  previous one has started; the remove case removes a second voter while
  one is down. The checks exist to catch such mistakes, though, and they
  catch them when the request reaches the leader.
- **Related:** #21640 and #21641 (the add check), #16798. We found no
  duplicate.

**Etcd version (please run commands below)**

```
$ etcd --version
etcd Version: 3.8.0-alpha.0
Git SHA: 3aaab3479
```

Also present (by code inspection) in v3.4.45 (remove case), v3.5.35,
v3.6.16 and v3.7.3.

**Etcd configuration (command line flags or environment variables)**

Defaults, four members on localhost; see the script.

**Relevant log output**

On the stale follower, with the fix:

```
"msg":"rejecting member add request; local member has not been connected to majority peers, reconfigure breaks active quorum"
```

---

## PR description (draft)

**etcdserver: check member add/remove against the committed membership**

Fixes #NNNN (stale-view case).

- `AddMember` and `RemoveMember` now wait for a linearizable read barrier
  before `mayAddMember` / `mayRemoveMember`, with strict reconfig check
  only.
  - The barrier waits until the local member has applied everything the
    leader had committed.
  - `applyConfChange` updates the membership before the applied index
    advances, so the checks see every committed change.
- **Cost:** one ReadIndex round trip per member add or remove.
- **Without a leader:** the request fails with the barrier's error after
  the request timeout. Before, it failed fast with `ErrUnhealthy`, or the
  proposal waited in `configure`.
- **Promote** already waits for the applied index on the leader
  (`isLearnerReady` → `waitAppliedIndex`).
- **Test:** `TestMemberReconfigStaleView` (e2e, failpoint
  `beforeApplyOneConfChange`, add and remove). It fails on main.
- **Backports:** the remove case affects release-3.4 to release-3.7. The
  barrier exists there (`linearizableReadNotify`), so the change can be
  cherry-picked. A CHANGELOG entry can be added once this has a PR number.
