# Draft issue (etcd-io/etcd): StrictReconfigCheck allows promoting an unreachable learner, which can lose quorum

**What happened?**

`mayPromoteMember` checks two things:
- `isLearnerReady`: the leader's `Match` for the learner. This keeps its
  last value after the learner stops.
- `IsReadyToPromoteMember`: counts voters that have *ever* published a
  name (`IsStarted`), and counts the learner as started.

Neither looks at current connectivity. Add and remove do
(`isConnectedToQuorumAfterAddingNewMemberSince`, `numConnectedSince`).

With 3 voters, one of them down, and a learner that caught up and then
stopped, `MemberPromote` succeeds. The promotion commits under the old
config (2 of 3); the new config has 4 voters needing 3, with 2 running. The
leader logs `stepped down to follower since quorum is not active` and
writes time out until the learner comes back.

**What did you expect to happen?**

With `--strict-reconfig-check` (the default), the promotion is refused, as
an equivalent add or remove would be.

**How can we reproduce it?**

1. Start a 3-member cluster (strict reconfig check on). Wait at least 5s.
2. Add a learner, start it, and let it catch up.
3. Stop one non-leader voter, then stop the learner.
4. Write a key: succeeds (2 of 3).
5. `MemberPromote(learner)`: succeeds.
6. Write a key: times out. Restarting the learner restores writes.

Integration test available (3/3 runs).

**Anything else we need to know?**

- The guard's current form dates from #11640 (fix for #11633, in v3.4.16
  and later); it's unchanged on release-3.5, release-3.6 and main.
- Suggested check: count voters connected for `HealthInterval` (as remove
  does), and require the learner itself to be connected. In a TLA+ model of
  the server's membership logic, this closes the case; exhaustive check, 3
  voters plus 1 learner, up to 2 faults.

**Etcd version:** main at bf9cadf; release-3.5 and release-3.6 (code
inspection).
