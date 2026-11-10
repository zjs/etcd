# Comments for etcd-io/raft (no new issue; see README.md for why)

## Comment on PR #469 (and the same finding, shortened, on #458)

The `hup` guard is needed, but it isn't enough on its own: I have a second schedule that still reaches two leaders in one term with this PR applied (and with #458 applied).

From config {s1,s2,s3}, the leader adds s4 and then removes s3. s3 appends both entries but never learns that the first one committed. In the next term s3 wins on the old config with {s3,s1}, while s2 wins on the new config with {s2,s4}. The new guard doesn't stop s3, because from s3's point of view nothing is committed-but-unapplied.

The code prevents this with a second rule the spec doesn't model: `maybeAppend` commits up to `min(m.Commit, lastnewi)` in the same step as the append. The leader can only propose the second change after applying the first, so the message carrying it also carries a commit index that covers the first. The spec appends in one step and commits in a later one, which lets s3 hold both entries with a stale commit index.

Witness (extends `MCetcdraft`, replays the schedule step by step): [`tla/witness/TwoLeadersWitness.tla`](https://github.com/zjs/raft/blob/report/tla-membership-restart/tla/witness/TwoLeadersWitness.tla). Copy the `.tla` and `.cfg` into `tla/` and run:

```
java -cp tla2tools.jar:CommunityModules-deps.jar tlc2.TLC -workers 1 -config TwoLeadersWitness.cfg TwoLeadersWitness.tla
```

| Spec | Result |
|---|---|
| `main` (c51f010) | `MoreThanOneLeaderInv` is violated, 72 states |
| #458 (39f9eee) | violated, 72 states |
| #469 (6de2d22) | violated, 72 states |
| [`zjs/raft:report/tla-membership-restart`](https://github.com/zjs/raft/tree/report/tla-membership-restart), which also makes the append and commit atomic ([commit](https://github.com/zjs/raft/commit/69aa71c)) | blocked at a disabled step |

I'm not proposing a competing PR. If it helps, the atomic-commit change could be added to this one, and I'm glad to review it.

AI disclosure: [see README.md, "Disclosure"]

## Comment on issue #456

Three things that may help move this along:

1. **The guard in #458/#469 is necessary but not sufficient.** A different schedule still reaches two leaders with either PR applied; details and a replayable witness are in [my comment on #469](link). It also needs the spec to commit in the same step as the append, as `maybeAppend` does.
2. **There is a third path, through `Restart`.** `PersistState` records only `Len(log)`, and `Restart` restores that many entries from the *in-memory* log. A node that persisted old entries and then overwrote them in memory restarts with the new entries but its old commit index and config, and campaigns on the old config. [`RestartWitness`](https://github.com/zjs/raft/blob/report/tla-membership-restart/tla/witness/RestartWitness.tla) reaches `MoreThanOneLeaderInv` once item 1 is fixed.
3. **Other differences from the code that I found the same way**, each small: the pending-conf-change reset compares the wrong way round, and a new leader starts with no pending index; a promoted learner stays in the learner set, and `RequestVote` is sent to learners; trace validation can't match a real restart, because `InitState` is logged before `loadState`; and `MCetcdraft.cfg` uses `SYMMETRY` although servers are distinguishable.

All of it is on one branch, one commit per item: [`zjs/raft:report/tla-membership-restart`](https://github.com/zjs/raft/tree/report/tla-membership-restart). `example.ndjson` still passes trace validation there.

@serathius, on your point above that the spec needs its own approvers: I'd rather help get #469 reviewed than add a third PR to the queue. If a reviewer for `tla/` who isn't a maintainer would be useful, I'm willing to do that.

AI disclosure: [see README.md, "Disclosure"]
