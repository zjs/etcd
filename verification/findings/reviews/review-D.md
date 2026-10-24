# Review: issue D and patch 0001 (etcd-io/raft `tla/`)

## (a) Verdict: needs changes

Most of the spec–code differences are real. But with all three new
constants TRUE, the patched spec still elects two leaders in one term, via a
`Restart` bug that was already in upstream. So the claim that the switches
make the spec match the code, and the invariant the patch adds to
`MCetcdraft.cfg`, are both broken (TLC run).

## (b) Issue-report feedback

- **Lead with the main finding:** upstream's own `MoreThanOneLeaderInv`
  (already in `MCetcdraft.cfg`) is violated by a behavior in upstream's MC
  model.
  - BFS never reaches it (about 70 steps).
  - The 71-step witness also violates it on the **unpatched** upstream spec
    (TLC).
  - Attach the witness and the command to run it.
- **Item 1 is in the wrong group.**
  - It is a state-shape bug (voter and learner at once), not a missed
    behavior. Upstream sends to config ∪ learners, `AddLearner` is blocked,
    and `DeleteServer` removes j from both.
  - Merge items 2 and 3.
- **The issue miscounts the switches.** It says "5 and 6 behind
  constants", but there are three constants.
- **Item 7 overstates it.**
  - InitState's commit is the snapshot index, and its log length is real.
  - Mention the obvious alternative: move `traceInitState` after
    `loadState` in raft.go.
- **Item 8:** `Permutations(Server)` exchanges InitServer members with the
  spare, so the reduction is unsound, not "may skip states". The patch
  adds invariants under it.
- **Remove fork references.** Attach the traces. Note `example.ndjson` has
  no restart, so nothing upstream exercises T1.

## (c) Spec/patch findings

1. **HIGH: two leaders in one term with all switches TRUE, via `Restart`.**
   - `PersistState` stores only `Len(log)`. `Restart` restores
     `SubSeq(<in-memory log>, 1, durableState.log)`, which resurrects
     entries that were never persisted.
   - The 79-step behavior, within `MCetcdraft` bounds:
     1. s3 leads term 2, appends and persists two entries.
     2. s1 leads term 3, adds s4, removes s3.
     3. s3 persists term 3 only, overwrites entries 4–5 in memory, and
        restarts.
     4. s3 now holds the new config entries with config C0.
     5. In term 4, s3 wins on C0 with {s3, s1} and s2 wins on C2' with
        {s2, s4}.
   - TLC results: `MoreThanOneLeaderInv` is violated at state 80;
     `KnowsPrevConfigCommittedInv` fails first, at state 60.
   - Fix:
     - keep the log sequence in `durableState` and restore it;
     - use `Len(durableState[i].log)` in `CommittedIsDurableInv`;
     - add the witness as a regression test.
2. **HIGH (design): the constants.**
   - FALSE is known-unsafe for F4/F6, and keeps a plainly reversed
     comparison for F5. Who would set FALSE?
   - Make F5 unconditional, and likely F4 and F6 too. Show that the rules
     are necessary in the commit message or a witness.
   - If the constants stay: declare them in the top CONSTANTS block, and
     rename `LeaderPendingAtElection`.
3. **MEDIUM: the "applied" approximation is over-claimed.**
   - etcd's leader calls `Advance()` without waiting for `ApplyConfChange`,
     so the code can accept a second change before the tracker config
     changes. The spec forbids that.
   - An A→B→A sequence makes `HasUnappliedCommittedConfig` more permissive
     than the code.
   - State the assumption.
4. **MEDIUM: `reconfigCount` changes meaning.** With TRUE, it counts only
   when the proposing leader applies its own change while still leader. So
   `ReconfigurationLimit` no longer bounds changes; count at proposal time.
5. **MEDIUM: split the patch and add tests.**
   - Separate commits: T1 (or the Go tracer move plus a restart fixture);
     F1–F3; F5; F4/F6 + Restart fix + invariants + witness configs.
   - The reviewer's simulations did not surface the original bug (90 s
     each).
6. **LOW-MED: T1 matches too loosely.** Any follower BecomeFollower after
   any ApplyConfChange passes. Require that the last non-ApplyConfChange
   line for i be InitState. In the comment, "commit 0" should be "the
   snapshot index".
7. **LOW: F6 is only partly atomic.** Conflict truncation is still one entry
   per step, and the reply copies `m.msubtype`.
8. **LOW:** the SYMMETRY reduction is unsound (above).
9. **LOW: hygiene.**
   - History comments belong in commit messages.
   - Two trailing-whitespace lines.
   - `tla/README.md` isn't updated.
   - Bot author identity, no `Signed-off-by`; check the policy on
     AI-assisted contributions.

## (d) Evidence checks

| Claim | Result |
|---|---|
| Applies to raft `main` 1931ff5 | Yes; 2 whitespace warnings |
| Parses (SANY) | OK |
| Witness depends on F4 and F6 | Violated unless both are TRUE (all 8 combinations); F5 makes no difference |
| Witness on unpatched upstream | Violates (state 72) |
| Code claims 1–7 | All accurate |
| T1 | Patched: restart and learner traces pass. Unpatched: the restart trace fails at InitState. A negative control fails as it should |
| Simulation claims | Consistent rates; but finding 1 exists at depth 79 |

## (e) Likely maintainer questions

- Why constants instead of fixing the spec?
- Does the patched spec satisfy `MoreThanOneLeaderInv`? (No: the Restart
  path.)
- How does "applied" relate to the `Advance` contract?
- Why not fix the tracer in Go? Can a restart trace fixture and the
  witness go into the repo or CI?
- Does PreVote/CheckQuorum make the witness unreachable in practice? It is
  still a spec bug.
- What about ConfChangeV2 configurations and the omitted empty entry at
  `becomeLeader`?
- Validation cost?
- **Issue or PR first?** File a short issue first, centered on the
  `MoreThanOneLeaderInv` false alarm with both witnesses; then small PRs.

## (f) Fine as is

- F1–F3 are correct and minimal.
- F5's `pending = Len(log)` at election.
- F6's commit, reply index and precondition match `handleAppendEntries`.
- The witness is well documented.
- `LearnersVotersDisjointInv` and `ConfigEntryDisjointInv`.
- T1's approach works and catches a corrupted trace.
- The changelog placement.
