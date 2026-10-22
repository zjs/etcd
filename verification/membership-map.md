# Membership code map, invariants and hypotheses (P1)

All references are to commit `bf9cadf` of this repo and `go.etcd.io/raft/v3`
v3.7.0. "Confirmed" means read in the code; anything not yet tested against a
running cluster is marked as such.

## 1. Pipeline

```
client ──► AddMember / PromoteMember / RemoveMember / UpdateMember   (server.go:1376–1660)
              │  permission check
              │  proposal-time guard (StrictReconfigCheck), on THIS member's local view
              ▼
           configure()  register waiter on cc.ID, ProposeConfChange      (server.go:1749)
              │
              ▼
           raft leader: refuse if a change is pending → replaced by an
           empty EntryNormal (raft.go:1326–1341)
              │  replicate, commit
              ▼
           apply() on EVERY member, in log order                          (server.go:1887)
              │  index ≤ consistent index → ApplyV2storeOnly (replay)
              │  index >  consistent index → ApplyBoth
              ▼
           applyConfChange()                                              (server.go:2002)
              1. ValidateConfigurationChange (backend + local config)    (cluster.go:306)
                 └─ on error: NodeId := None, raft applies a no-op change,
                    client gets the error
              2. raft ApplyConfChange (only if ApplyBoth) → ep.confState
              3. beHooks.SetConfState(ep.confState) (written at next commit)
              4. RaftCluster.{Add,Promote,Remove}Member / UpdateRaftAttributes
                 (backend write + in-memory map, only if ApplyBoth)
              5. transport Add/Remove/UpdatePeer (always, also on replay)
              ▼
           waiter triggered with (members, err); configure waits for raft
           to advance before replying (issue #15528)                      (server.go:1761–1775)
```

Wire format (confirmed): the server only proposes v1 `ConfChange`:
`AddNode`, `AddLearnerNode`, `RemoveNode`, `UpdateNode`. Promote is `AddNode`
with `ConfigChangeContext.IsPromote = true` (server.go:1512–1527).

## 2. Where membership lives

| Store | Written by | Read by | Notes |
|---|---|---|---|
| In-memory `RaftCluster.members/removed` | `RaftCluster` mutators when `ApplyBoth` | guards, API, transport setup | Loaded from backend by `Recover`/`UnsafeLoad` (cluster.go:256–262) |
| Backend bucket `members` | `MustSaveMemberToBackend` | `ValidateConfigurationChange`, `Recover`, bootstrap | |
| Backend bucket `members_removed` | `MustDeleteMemberFromBackend` (deletes from `members`, adds here) (schema/membership.go:73) | validation (`ErrIDRemoved`), `IsIDRemoved` | |
| Backend `meta/confState` | `BackendHooks.OnPreCommitUnsafe` (hooks.go:50) | **Nothing in non-test code** | Written but never read by the server. Restart rebuilds ConfState from `members` instead |
| Raft tracker config (in memory) | `r.ApplyConfChange` (ApplyBoth only); snapshot restore | raft | At restart: built from backend `members` by `buildConfStateFromV3store` (bootstrap.go:112, 132) |
| Snapshot metadata `ConfState` | `ep.confState` at snapshot time | followers receiving the snapshot | Snapshot `Data` is nil; membership travels in the bbolt file |
| Transport peer set | apply step 5; `applySnapshot` rebuilds it from `cluster.Members()` | raft messaging | |
| v2store | — | — | **Not used for membership at runtime any more.** `RaftCluster.Store(v2store)` has no non-test callers. PLAN.md's table listed it; corrected here |

## 3. Answers to the P1 questions

**Q1. A second change while one is pending.** Raft's leader replaces the
conf-change entry with an empty `EntryNormal` (raft.go:1326–1341). The
server's waiter for that `cc.ID` is never triggered, so `configure` blocks
until the request context ends and returns a timeout (`parseProposeCtxErr`).
The same applies right after a leader change: `becomeLeader` sets
`pendingConfIndex = lastIndex` (raft.go:958), so changes are refused until
the new leader has applied everything up to its last index at election.
Safe, but the client sees a timeout rather than a clear "busy" error.

Retries after an ambiguous timeout are caught at apply time:

- a re-sent add → `ErrPeerURLexists`;
- a re-sent promote → `ErrMemberNotLearner`;
- a re-sent remove → `ErrIDRemoved`.

**Q2. Concurrent requests and proposal-time guards.** Raft lets only one
change be in flight, but the guards run earlier, on whichever member received
the request, against that member's local view:

- `IsStarted()` means "has ever published a name" (member.go:114), not
  "currently reachable".
- Live connectivity is checked for add (`isConnectedToQuorumAfterAddingNewMemberSince`)
  and remove (`numConnectedSince`), but **not for promote**.
- Only promote waits for the local applied index to catch up
  (`isLearnerReady` → `waitAppliedIndex`). Add and remove can run on a stale
  view.
- Apply-time validation checks only structure (ID exists/removed, learner
  flag, URL uniqueness, learner count), not quorum health.

So nothing ties a guard's decision to the configuration the change is
finally applied to. See H2 and H3.

**Q3. WAL replay and crash consistency.** Entries at or below the backend's
consistent index are replayed with `ApplyV2storeOnly`:

- validation is skipped;
- raft `ApplyConfChange` is skipped;
- backend and in-memory state are unchanged;
- transport peers are still updated;
- a replayed self-removal still stops the server (server.go:2051–2053).

This is consistent because raft's restart config is rebuilt from the
backend's `members` bucket, which already includes those entries. For one
entry, the consistent index, `confState` and member writes all go through
the same batch transaction (consistent index via
`txPostLockInsideApplyHook`; `confState` via the pre-commit hook). Whether
they always land in the same bbolt commit is not confirmed: it depends on
batch-commit timing. Check in P3.

**Q4. Removed IDs.** Validation rejects any change for an ID in
`members_removed` (`ErrIDRemoved`, cluster.go:314). Peer messages from
removed IDs are dropped (rafthttp/http.go:405, server.go:701). Member IDs
are a hash of peer URLs, cluster name and time (member.go:63–74), so
re-adding a URL produces a new ID. No path re-admits a removed ID was found.

**Q5. Where `maxLearners` is enforced.**

- At apply, for learner adds (cluster.go:352).
- At bootstrap when joining an existing cluster (bootstrap.go:362).
- Not at proposal time.

The limit is each member's own `--max-learners` flag (embed/config.go:747),
not a cluster-wide value. See H1.

## 4. Invariants

Status: **code** = holds by code reading; **P2/P3/P4** = to be checked
there; **H#** = threatened by a hypothesis below.

| # | Invariant | Status |
|---|---|---|
| I1 | Every member makes the same accept/reject decision for each committed conf-change entry | code, if configs match; **violated with mixed `--max-learners` (H1, reproduced)** |
| I2 | After applying index k, each member's raft config equals {voters = non-learner members, learners = learner members} from its backend | P3 |
| I3 | After restart, raft's config (rebuilt from backend) equals the config from applying the log up to the consistent index | code; P3 with crashes |
| I4 | A conf-change entry's member write, consistent index and `confState` are durable together or not at all | P3 (batch-commit timing) |
| I5 | A removed ID never re-enters `members` and its messages are dropped | code |
| I6 | Peer URLs are unique among members | code (add/update validation) |
| I7 | Learners ≤ max-learners | code, per member; cluster-wide only if flags match (H1) |
| I8 | At most one conf change between a leader's applied index and its log end | code (raft); P2 |
| I9 | Learners never vote and never count towards commit | P2 |
| I10 | With StrictReconfigCheck on, an accepted voter add/promote/remove leaves a quorum of reachable voters in the new configuration, assuming no further failures | **violated (H2, H3 reproduced)**; P3 |
| I11 | `configure` reports success only after the change applied locally; a timeout may mean applied or not, and retries are detected | code |
| I12 | After any apply, snapshot or replay, transport peers = members \ {self} | P3 |

## 5. Hypotheses

All three were reproduced on 2026-10-22 against real in-process clusters
(`tests/integration/verification`, build tag `verification`). Each test
reproduced its hypothesis 3 out of 3 times. They are not yet confirmed as
bugs: P5 still needs an upstream search, affected versions and a severity
call. Model traces come in P3.

**H1. Different `--max-learners` values can make members disagree on
membership.** Learner-add validation uses the local flag. Example: one
member allows 2 learners and the others 1. A second learner add is then
accepted on one member and rejected (`NodeId = None`) on the others. Their
backends and raft configs would diverge, violating I1/I2. A later promote
of that learner would make the voter sets differ. It needs operator
misconfiguration; bootstrap only checks the joining member's own flag
against current membership.

*Reproduced* by `TestH1MixedMaxLearners`. 3 voters with `--max-learners=1`;
member 0 restarted with `2`; two learner adds. Member 0 records 2 learners
in its member list and in its persisted raft `ConfState`; members 1 and 2
record 1. So the raft configurations differ, not just the metadata. Open:
what a later promote of the extra learner does (voter sets would differ);
model in P3.

**H2. Promote does not check that the learner or the voters are currently
reachable.** `mayPromoteMember` uses `isLearnerReady` (the leader's `Match`
for the learner, which keeps its last value after the learner dies) and
`IsReadyToPromoteMember` (counts ever-started members and counts the
learner as started). Example: 3 voters with 1 down, plus a caught-up
learner that has just died. Promote passes both checks and commits under
the old config (2 of 3). The new config has 4 voters needing 3, with only
2 alive, so the cluster loses quorum. Add and remove have live-connectivity
checks; promote does not.

*Reproduced* by `TestH2PromoteDeadLearner` (strict reconfig check on).
Sequence:
1. Add a learner and let it catch up.
2. Stop one non-leader voter, then the learner.
3. A control write succeeds (2 of 3 voters alive).
4. `MemberPromote` succeeds.
5. The leader logs "stepped down to follower since quorum is not active"
   and writes time out for 15 s.
6. Restarting the learner restores writes.

**H3. Guards on stale views.** Add and remove guards don't wait for the
local applied index. A member that hasn't applied the previous change
evaluates the next one against the old membership.

*Found by enumeration:* `verification/explore/guard_enum.py` compares the
guards on an up-to-date view and on a view one change behind, for 1–5
voters, 0–1 learners and two changes each. It finds 2,354 cases where only
the stale view accepts a change that leaves no reachable quorum, with the
stale member different from the first change's proposer. Every case starts
from an **even** voter count (2 or 4); none from 1, 3 or 5.

*Reproduced* by `TestH3StaleViewAddVoter` (strict reconfig check on).
Sequence:
1. 4 voters, one stopped.
2. Make a follower lag. The test holds a read lock on its backend and
   starts a commit, so its apply blocks in `ValidateConfigurationChange`
   before the in-memory view updates.
3. Add voter n0 (not started) via the leader: accepted. The leader's view
   shows 5 voters; the lagging follower's shows 4.
4. Control: adding n1 via the leader is refused ("unhealthy cluster").
5. Adding n1 via the lagging follower is accepted. The lag is released
   about 30 ms later.
6. The leader's view shows 6 voters with 3 alive (quorum 4); writes time
   out for 15 s.

The lag is artificial, but real lags of this length happen routinely
(apply runs behind commit). A client with several endpoints spreads
requests across members, so consecutive member commands can reach
different members.

*Also reproduced* by `TestH3StaleViewRemove`, which uses only the remove
guard (unchanged since before PR #21641). Sequence:
1. 4 voters A (down), B, L (leader), S; freeze the apply loops of B and S.
2. Remove B via L: accepted. L's view shows 3 voters; S's view shows 4.
3. Control: removing S via L is refused ("unhealthy cluster").
4. Removing S via S is accepted. S's stale view counts B as an active
   voter, because B hasn't applied its own removal yet and is still
   connected.
5. L's view shows 2 voters with 1 alive; writes time out.

Every remove → remove case found by the enumeration has this shape: the
first removed member is still running when the stale member evaluates.

## 6. Notes for P2/P3

- **Spec vs code: new leader.** Spec `BecomeLeader` leaves
  `pendingConfChangeIndex` unchanged and appends no empty entry. The code
  sets `pendingConfIndex = lastIndex` *before* appending the empty entry
  (raft.go:958–962). The spec is more permissive, which is fine for safety
  checking but will matter for trace validation.
- **P2 question.** In the code, a new leader that already applied its whole
  log can propose a conf change before an entry from its own term commits.
  That is the precondition of the known single-step reconfiguration bug
  (Ongaro, raft-dev, 2015). etcd applies configs at apply time, not append
  time, which may avoid it. Check with a P2 model at 4–5 servers and
  ≥ 2 reconfigurations.
- **Not in the raft spec, needed in P3:** per-member validation rejection
  (`NodeId = None`), replay skipping `ApplyConfChange`, ConfState rebuilt
  from the backend at restart, snapshot install rebuilding the transport,
  and the client-facing waiter and timeout.
