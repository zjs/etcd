# Comments for etcd-io/raft (no new issue; see README.md for why)

## PR #469

Use the staged review in `8-raft-469-review.md` instead of a comment.

## Comment on PR #458

The guard here is the same one as in #469, and the same gap applies: a second schedule still reaches two leaders in one term with this PR applied. Details, a replayable witness and a suggested change are in [my review of #469](link). #469 tracks an applied index and so follows `hasUnappliedConfChanges()` more closely; the two differ only when two changes return to an identical config.

AI disclosure: [see README.md, "Disclosure"]

## Comment on issue #456

Three things that may help move this along:

1. **The guard in #458/#469 is necessary but not sufficient.** A different schedule still reaches two leaders with either PR applied; details and a replayable witness are in [my review of #469](link). It also needs the spec to commit in the same step as the append, as `maybeAppend` does.
2. **There is a third path, through `Restart`.** `PersistState` records only `Len(log)`, and `Restart` restores that many entries from the *in-memory* log. A node that persisted old entries and then overwrote them in memory restarts with the new entries but its old commit index and config, and campaigns on the old config. [`RestartWitness`](https://github.com/zjs/raft/blob/report/tla-membership-restart/tla/witness/RestartWitness.tla) reaches `MoreThanOneLeaderInv` once item 1 is fixed.
3. **Other differences from the code that I found the same way**, each small: the pending-conf-change reset compares the wrong way round, and a new leader starts with no pending index; a promoted learner stays in the learner set, and `RequestVote` is sent to learners; trace validation can't match a real restart, because `InitState` is logged before `loadState`; and `MCetcdraft.cfg` uses `SYMMETRY` although servers are distinguishable.

All of it is on one branch, one commit per item: [`zjs/raft:report/tla-membership-restart`](https://github.com/zjs/raft/tree/report/tla-membership-restart). `example.ndjson` still passes trace validation there.

@serathius, on your point above that the spec needs its own approvers: I'd rather help get #469 reviewed than add a third PR to the queue. If a reviewer for `tla/` who isn't a maintainer would be useful, I'm willing to do that.

AI disclosure: [see README.md, "Disclosure"]
