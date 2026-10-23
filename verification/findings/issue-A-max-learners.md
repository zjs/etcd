# Draft issue (etcd-io/etcd): mismatched `--max-learners` makes members disagree on membership, and starting the extra learner panics the others

**What happened?**

`--max-learners` is enforced when a conf change is *applied*
(`RaftCluster.ValidateConfigurationChange`), using each member's own flag.
If members run with different values, the same committed
`ConfChangeAddLearnerNode` is accepted on some members and rejected
(applied as a no-op) on others. Their membership, and the raft `ConfState`
persisted in each backend, then differ.

Starting the learner that only some members accepted makes the others
panic. When it publishes its attributes, they apply a
`ClusterMemberAttrSet` for a member they don't know and haven't removed:

```
PANIC  failed to update; member unknown  {"unknown-remote-peer-id": "..."}
```

On restart the same entry is replayed (it was never recorded as applied),
so by our reading of `RaftCluster.UpdateAttributes` the members would
panic again.

If the extra learners are promoted instead (needs the leader to be a member
that accepted them), voter sets diverge across members. With limits 3 and
1, two promotions give one member voters {a,b,c,y,z} and the others
{a,b,c}. Majorities {a,y,z} and {b,c} don't intersect. This was shown in a
TLA+ model of the server's membership logic, not on a running cluster.

**What did you expect to happen?**

Every member makes the same decision for a committed conf change,
whatever its local flags. A mismatched `--max-learners` should be rejected
or harmless, not a source of divergence or panics.

**How can we reproduce it?**

1. Start a 3-member cluster with `--max-learners=1`.
2. Restart member 0 with `--max-learners=2`, and make it leader.
3. Add two learners through member 0. Members 1 and 2 reject the second at
   apply time. `member list` on member 0 shows two learners; on 1 and 2
   it shows one.
4. Start the second learner with `--max-learners=2` and an
   `--initial-cluster` matching member 0's view.
5. Members 1 and 2 panic: `failed to update; member unknown`.

Integration tests reproducing steps 1–3 and 1–5 are available (3/3 runs
each).

**Anything else we need to know?**

- The flag was added in #13377. Review noted that mismatched values "could
  cause hard to debug behavior on leader change" and suggested detecting
  mismatches as a follow-up; we found no implementation.
- 3.5 is not affected (`maxLearners` is a constant there).
- Possible directions:
  1. Check the limit only when proposing a learner add (on the leader),
     and keep apply-time validation independent of local flags.
  2. Make `UpdateAttributes` log and skip an unknown member instead of
     panicking.
  3. Detect mismatched values at join or startup.

**Etcd version:** main at bf9cadf; v3.6.x (code inspection).

**Candidate fix:** [`fix/max-learners-at-propose`](https://github.com/etcd-io/etcd/compare/main...zjs:etcd:fix/max-learners-at-propose),
two commits, each with tests that fail without it:
1. Check `--max-learners` in `mayAddMember`, when the change is proposed
   (with or without strict reconfig check, as today). Keep the apply-time
   check while the cluster version is below 3.8, so members of different
   versions still agree; cluster version changes are applied in log order,
   so all members switch at the same entry.
2. `UpdateAttributes` logs an error and skips an unknown member instead of
   panicking.

Trade-off: the limit becomes a proposal-time check like the other
membership guards. Each member enforces its own value on requests it
receives, and two concurrent learner adds can together exceed it. If a
cluster-wide limit is preferred, it could be stored in the backend instead;
happy to rework it that way.
