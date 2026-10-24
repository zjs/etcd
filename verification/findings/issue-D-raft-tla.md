# Draft issue (etcd-io/raft): `tla/` model elects two leaders in one term (`MoreThanOneLeaderInv` false alarm)

**What happened?**

`MCetcdraft` checks `MoreThanOneLeaderInv`, but the spec has behaviors
that violate it. Breadth-first search doesn't reach them (they are 70–80
steps long), so the model check passes. Both are spec artifacts rather than
code bugs: the spec misses rules the code has.

1. **Campaigning on a config two changes old** (`TwoLeadersWitness`, 71
   steps).
   - From config {s1,s2,s3}, the leader adds s4 and then removes s3.
   - s3 appends both entries but doesn't learn that the first committed.
   - In the next term, s3 wins on the old config with {s3,s1}, and s2 wins
     on the new config {s1,s2,s4} with {s2,s4}.
   - Two rules in the code prevent this, and the spec models neither:
     - `hup` refuses to campaign with committed but unapplied conf changes
       (`hasUnappliedConfChanges`).
     - `maybeAppend` commits up to `min(m.Commit, lastnewi)` in the same
       step as the append. The spec appends in one step and commits in a
       later one.
   - The witness reaches the violation unless both are modeled.
2. **Restart brings back entries that were never persisted**
   (`RestartWitness`, 78 steps).
   - `PersistState` records only `Len(log)`, and `Restart` restores
     `SubSeq(<in-memory log>, 1, <that length>)`.
   - A node that persisted old entries and then overwrote them in memory
     restarts with the new entries, but with its old commit index and
     config, and campaigns on the old config.
   - This still violates `MoreThanOneLeaderInv` even when the rules in 1,
     and the pending-change rule below, are modeled.

Both witnesses are attached. They are TLA+ modules that extend
`MCetcdraft` and replay the behavior step by step. Run them from `tla/`:

```
java -cp tla2tools.jar:CommunityModules-deps.jar tlc2.TLC -workers 1 -config TwoLeadersWitness.cfg TwoLeadersWitness.tla
```

Results on `main` (c51f010):
- `TwoLeadersWitness`: `Invariant MoreThanOneLeaderInv is violated`.
- `RestartWitness` stops earlier on `main`, because the spec's
  non-atomic append doesn't allow its script. With item 1 fixed, it
  reaches `MoreThanOneLeaderInv is violated`.

Other differences between the spec and the code, found the same way. Each
is checked against raft v3.7.0 / `main`:

3. **Pending conf change rule.**
   - The code allows a new conf change only while `pendingConfIndex <=
     applied`, and `becomeLeader` sets `pendingConfIndex = lastIndex`.
   - The spec allows one only while `pendingConfChangeIndex = 0`, and
     `ApplySimpleConfChange` resets it when it is `>= k`. That comparison
     is reversed.
   - Since re-applying an older committed config is always enabled, a
     leader can reset it at will and stack two uncommitted config entries.
     A new leader also starts with no pending index.
4. **Learners.**
   - `AddNewServer` keeps a promoted learner in the learner set, so it is a
     voter and a learner at once (`makeVoter` removes it).
   - `RequestVote` also asks learners, while `campaign` asks only voters.
   - `BecomeLeader` requires *every* granted vote to come from a voter, so
     one vote from a learner blocks the election; `TallyVotes` ignores such
     votes.
5. **Trace validation can't validate a restart.**
   - `newRaft` logs `InitState` before `loadState`, so a restart's
     `InitState` shows term 0, an empty config and the snapshot's commit
     index. `RestartIfLogged` validates against it, so no real restart
     matches.
   - `example.ndjson` contains no restart, so this doesn't show up in the
     repo.
6. **`MCetcdraft.cfg` uses `SYMMETRY Permutations(Server)`.**
   - `InitServer`, the order of `BootstrapLog` (`SetToSeq`) and the spare
     servers make servers distinguishable, so this is not a symmetry of the
     spec.
   - The reduction can skip reachable states.

**What did you expect to happen?**

The spec's behaviors are a superset of the code's that still satisfies
its invariants, so that a violation means a bug.

**Anything else we need to know?**

- **PR:** a series of 7 small commits is ready ([link to PR]). It fixes
  1–6 and adds membership invariants. The two witnesses then stop at a
  disabled step, before reaching the second leader.
- **Validated with the patched spec:**
  - `example.ndjson`, and 5 traces from etcd integration runs (including a
    restart and a leader removal), pass trace validation.
  - A corrupted restart trace fails, and the real restart trace fails on
    the current spec.
  - A 15-minute simulation of `MCetcdraft.cfg` (without `SYMMETRY`) finds
    no violation.
- **Modeling assumption, now documented:** the spec has no applied index.
  A committed config entry counts as applied once the node's config
  matches it, which assumes `ApplyConfChange` is called before `Advance`
  (as in `doc.go`'s loop). The README allows `Advance` "at any time after
  step 1". In that case the code can accept a second conf change before
  the first is applied to the tracker. That isn't modeled, and we haven't
  analyzed it.
- **Not addressed:**
  - `becomeLeader` appends an empty entry; the spec doesn't.
  - `ConfChangeV2` configurations.
  - Conflict truncation is still one entry per step.
- **Context:** we found these while checking etcd's membership handling.
  CheckQuorum and PreVote, which etcd enables, would likely make
  `TwoLeadersWitness` hard to reach in a real cluster, but the spec should
  still not allow it.

---

## PR description (draft)

**tla: model membership changes and restarts as the code does**

Fixes #NNNN. One commit per change, each parsing on its own:

1. **Restore only persisted log entries on restart.** `durableState.log`
   becomes the persisted log instead of its length.
2. **Model learner promotion and voting as the code does.** Covers
   `makeVoter`, `campaign` and `TallyVotes`.
3. **Model the pending conf change rule.** `becomeLeader` sets the pending
   index, and the reversed reset is fixed. `reconfigCount` now counts
   proposals: it used to miss changes committed after their proposer
   stepped down, so `ReconfigurationLimit` didn't bound them.
4. **Model `hup`'s check and `maybeAppend`'s atomic commit.**
5. **Check membership invariants** in `MCetcdraft.cfg`, and drop the
   unsound `SYMMETRY`.
6. **Validate restarts at the `BecomeFollower` after `loadState`**
   (trace spec). An alternative is to move `traceInitState` after
   `loadState` in `raft.go`, but that reorders the restart events, so this
   keeps the trace format.
7. **Document the applied-config assumption;** changelog entry.

The behaviors that commits 1 and 4 remove are attached to #NNNN as
replayable witnesses (`TwoLeadersWitness`, `RestartWitness`). Happy to add
them under `tla/` as regression configs if that's useful.

Checks:
- SANY on each commit.
- Trace validation of `example.ndjson` and of 5 etcd traces, with negative
  controls.
- `MCetcdraft.cfg` simulation, 15 minutes, no violation.
- Both witnesses: violated before, blocked after.

Cost: removing `SYMMETRY` and persisting the log increase the state space
of exhaustive runs; simulation is unaffected.
