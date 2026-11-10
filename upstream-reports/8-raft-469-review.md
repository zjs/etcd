# Staged review for etcd-io/raft PR #469

Post as a PR review ("Comment", not "Request changes": you are not an
approver). Everything marked *ran* was run on PR head `6de2d22` with TLC
2026.10.06; rerun the commands yourself before posting.

---

**Summary.** The guard is right and the PR does what it says, but it does not yet make `MoreThanOneLeaderInv` hold: a second schedule still elects two leaders in one term with this PR applied. It needs one more rule from the code (commit in the same step as the append). Details and a replayable witness below.

### What I checked

| Check | Result |
|---|---|
| `SplitBrain456` on this PR | passes, 71 states (*ran*) |
| `SplitBrain456` with the `~HasUnappliedConfChange(i)` line removed from `Timeout` | `MoreThanOneLeaderInv` violated, 82 states (*ran*). So the scenario does test the guard. |
| `MCetcdraft.cfg`, simulation, depth 100, 150 s | no violation, about 2.4M states (*ran*) |
| `HasUnappliedConfChange` against `hasUnappliedConfChanges()` in `raft.go` | equivalent, given that the spec applies the latest committed config entry in one step (read, not run) |
| every action that assigns `config'` also assigns `appliedConfChangeIndex'` | yes: `Restart`, `ApplySimpleConfChange`; all others leave `configVars` unchanged (read) |
| Trace validation of `example.ndjson` (`Traceetcdraft.cfg`, including `TraceMatched`) | passes: progress 100%, 4,998 distinct states, 46 min (*ran*). So the guard does not reject the recorded run. |

### The guard is not sufficient on its own

Schedule (71 steps, within `MCetcdraft`'s bounds):

1. Config {s1,s2,s3}, s1 leader. s1 adds s4, then removes s3.
2. s3 appends both entries but never learns that the first one committed.
3. Next term: s3 campaigns on {s1,s2,s3} and wins with {s3,s1}; s2 campaigns on {s1,s2,s4} and wins with {s2,s4}.

`HasUnappliedConfChange(s3)` is false in step 3, because from s3's point of view nothing is committed and unapplied.

The code can't reach step 2. `handleAppendEntries` calls `raftLog.maybeAppend`, which appends and commits up to `min(m.Commit, lastnewi)` in one step. A leader proposes the second change only after applying the first, so any message carrying the second entry also carries a commit index that covers the first. The spec appends in `NoConflictAppendEntriesRequest` and commits later in `AppendEntriesAlreadyDone`, which is what lets s3 hold both entries with a stale commit index.

Witness: [`TwoLeadersWitness.tla` / `.cfg`](https://github.com/zjs/raft/tree/report/tla-membership-restart/tla/witness). It extends `MCetcdraft` and replays the schedule. Copy both files into `tla/` and run:

```
java -cp tla2tools.jar:CommunityModules-deps.jar tlc2.TLC -workers 1 -config TwoLeadersWitness.cfg TwoLeadersWitness.tla
```

| Spec | Result (*ran*) |
|---|---|
| `main` (c51f010) | `MoreThanOneLeaderInv` violated, 72 states |
| this PR (6de2d22) | violated, 72 states |
| #458 (39f9eee) | violated, 72 states |
| this PR plus the change below | blocked at a disabled step, 52 states |

### Suggested change

In `NoConflictAppendEntriesRequest`, commit and reply in the same step:

```tla
    /\ log' = [log EXCEPT ![i] = @ \o SubSeq(m.mentries, Len(@)-index+2, Len(m.mentries))]
    /\ CommitTo(i, Min({m.mcommitIndex, m.mprevLogIndex + Len(m.mentries)}))
    /\ Reply([mtype           |-> AppendEntriesResponse,
              msubtype        |-> m.msubtype,
              mterm           |-> currentTerm[i],
              msuccess        |-> TRUE,
              mmatchIndex     |-> m.mprevLogIndex + Len(m.mentries),
              msource         |-> i,
              mdest           |-> m.msource],
              m)
    /\ UNCHANGED <<serverVars, durableState>>
```

Two things to know before taking it:

- **`SplitBrain456` needs re-scripting with it.** Its script relies on the separate commit step and stops at step 19 (`CampaignBlockedByGuard` violated) once the append commits atomically (*ran*). The scenario itself is still reachable, since s3 can know the first change is committed without having applied it.
- **I have not rerun trace validation with this change on top of this PR.** In my own branch, which has the same change among others, `example.ndjson` passes, but that is a different base.

### Relative to #458

Both PRs add the same guard to `Timeout`. #458 compares `config[i]` with the config of the latest committed entry and adds no state; this PR tracks an applied index, which is closer to the code. They differ only when two changes return to an identical config (add s4, remove s4): #458 would let a server campaign with both unapplied, which the code refuses (by reading; I did not build a scenario for it). That is harmless for safety, but this PR is the more faithful of the two. The finding above applies equally to both.

### Not checked

- Exhaustive model checking: the counterexamples are 70+ steps deep, beyond what breadth-first search reaches.
- The original `BugDriver` attached to #456.

AI disclosure: [see README.md, "Disclosure"]
