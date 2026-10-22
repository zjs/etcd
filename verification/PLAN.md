# Membership-change verification: plan and tracker

Working notes for a fork-only effort. This directory is not intended for
upstream in its current form. If the models prove useful, they can be offered
to etcd maintainers separately.

## Goal

Increase confidence that etcd's **current** cluster-membership behavior is
correct: adding, promoting and removing members, and recovering membership
state after crashes, restarts and snapshots. Where we find a defect, produce a
minimal reproducing test as evidence before deciding whether to report it.

### Why membership

- The Raft library already has a TLA+ spec and trace validation upstream
  (`etcd-io/raft`, `tla/`). The **server** layer, where etcd decides whether
  a change is allowed and records membership in several stores, has no model.
- The robustness suite exercises membership only through the `MemberReplace`
  failpoint (remove a voting member, then re-add it as a voter). Learner
  add/promote is not exercised there.
- Membership has a history of subtle bugs. For example, SysMoBench (2025)
  reproduced a learner-promotion election bug in etcd Raft from a TLA+ model.

### Non-goals

- Verifying the KV store, MVCC, watches, leases or auth.
- Read-path features (ReadIndex, lease reads), PreVote, CheckQuorum, except
  where they affect membership safety.
- Machine-checked proofs. We use model checking (TLC, possibly Apalache) plus
  trace validation, i.e. bounded checking, not proof.

## Ground rules

- All work stays on this fork's topic branch. Nothing is posted upstream
  (issues, PRs, comments) without an explicit decision.
- Specs copied from `etcd-io/raft` keep their Apache-2.0 headers and record
  the source version.
- Every claimed finding needs a counterexample trace **and** a reproducing Go
  test against real code before it is called a bug.

## Status

- [ ] **P0 Tooling**: run TLC in a cloud session, pinned versions, one script.
- [ ] **P1 Code map and informal invariants**: write down, in prose, what
      must be true; review each against the code.
- [ ] **P2 Raft-layer model**: check membership properties on the existing
      upstream spec; calibrate against a known historical bug.
- [ ] **P3 Server-layer model**: new spec for etcd's membership state
      machine above Raft.
- [ ] **P4 Model–code conformance**: trace validation and new robustness
      scenarios.
- [ ] **P5 Findings**: reproduce, write up, decide on disclosure.

## Phases

### P0 Tooling

- Script `verification/tools/tlc.sh`: fetch a pinned `tla2tools.jar` (and
  CommunityModules) into an ignored cache dir, then run TLC with given
  spec/config. Java is available in the cloud image.
- Smoke test: model-check upstream `MCetcdraft.tla` (raft v3.7.0) at small
  bounds; record state count and wall time here.
- Optional: a SessionStart hook so later sessions have the tools ready.

### P1 Code map and informal invariants

Produce `verification/membership-map.md` covering every path that reads or
writes membership, and a numbered list of invariants (I1, I2, …) that later
phases check. Starting points (all confirmed at commit `bf9cadf`):

| Concern | Location |
|---|---|
| API entry points | `server/etcdserver/server.go`: `AddMember`, `PromoteMember` (forwards to leader over HTTP), `promoteMember`, `RemoveMember`, `UpdateMember` |
| Proposal-time guards (`StrictReconfigCheck`) | `mayAddMember`, `mayPromoteMember`, `isLearnerReady` (learner `Match` ≥ 90% of leader's), `mayRemoveMember`; `membership/cluster.go`: `IsReadyToAddVotingMember`, `IsReadyToPromoteMember`, `IsReadyToRemoveVotingMember` |
| Proposal and wait | `configure`: registers wait on `cc.ID`, `ProposeConfChange`, waits for apply or ctx timeout |
| Apply-time validation | `membership/cluster.go` `ValidateConfigurationChange` (reads backend only; skipped when `shouldApplyV3` is false). On failure, `applyConfChange` applies the change with `NodeId = None` |
| Apply | `server.go` `applyConfChange` → `r.ApplyConfChange`, `beHooks.SetConfState`, `RaftCluster.{AddMember,PromoteMember,RemoveMember,UpdateRaftAttributes}`, transport peer updates |
| Stores | Raft `ConfState` (persisted via backend hooks), backend members bucket, v2store (`membership/storev2.go`), transport peer set |
| Recovery | `RaftCluster.Recover` (called from `server.go` on snapshot apply), `bootstrap.go`, `storage/util.go` `GetEffectiveNodeIDsFromWALEntries`, `CreateConfigChangeEnts` (force-new-cluster) |
| Wire format | Only v1 `ConfChange` is proposed: `AddNode`, `AddLearnerNode`, `RemoveNode`, `UpdateNode`. Promote is `AddNode` with `ConfigChangeContext.IsPromote` |

Questions P1 must answer from the code (not assume):

1. What does a client see when Raft drops a conf change because another one is
   pending? Does `configure` return an error, or wait until timeout?
2. Proposal-time guards are evaluated on one member's local view, before the
   change is committed. What prevents two concurrent requests from each
   passing a guard that their combined effect would fail?
3. During WAL replay (`shouldApplyV3 = false`), which stores are updated and
   which are skipped, and can they disagree after a crash at any point in
   `applyConfChange`?
4. Is a removed member ID ever re-accepted (backend, v2store, transport)?
5. Where is `maxLearners` enforced: proposal, apply, bootstrap, or all three?

### P2 Raft-layer model

- Vendor upstream `tla/` from raft v3.7.0 into `verification/raft/` (pinned,
  with attribution) so we can add configs without touching the module cache.
- The upstream spec models single-step changes (`AddNewServer`, `AddLearner`,
  `DeleteServer`, `ApplySimpleConfChange`) with a one-pending-change rule,
  plus 8 safety invariants. Add membership-specific invariants, e.g.:
  - learners never count towards a vote or commit quorum;
  - at most one uncommitted config entry in any leader's log;
  - a leader that removes itself does not commit entries after the change
    applies.
- **Calibration**: check out the raft/etcd version from before the
  learner-promotion fix reported in SysMoBench, adjust the spec to that
  behavior, and confirm TLC finds the bug. If it cannot, the model is too
  coarse for this class of bug.

### P3 Server-layer model

New spec `verification/server/EtcdMembership.tla`. Abstract Raft as a totally
ordered committed log (justified by P2), and model:

- the proposal-time guards over an abstract "started members" view per
  server, with stale views allowed;
- apply-time validation and the `NodeId = None` rejection path;
- the separate stores (ConfState, backend, v2store) and their write order;
- crash at any step, restart via WAL replay, and snapshot restore.

Candidate invariants (refine in P1):

- after recovery, all stores agree on the member set and learner flags;
- the Raft `ConfState` agrees with the backend's member list;
- removed IDs never reappear;
- learner count ≤ `maxLearners`;
- with `StrictReconfigCheck` on, an accepted change never leaves fewer started
  voters than a quorum of the new configuration (assuming no faults during the
  change). This is the property the guards intend; check whether races break
  it.

### P4 Model–code conformance

- Enable the raft `TraceLogger` (`-tags=with_tla`) in an e2e or robustness
  build and validate real traces against `Traceetcdraft.tla`. The etcd server
  does not currently wire up a `TraceLogger`.
- Add robustness failpoints for learner add → promote, and learner removal,
  run with existing fault injection.
- For each P3 counterexample, write an integration test that drives the same
  interleaving against real code (gofail failpoints where needed).

### P5 Findings

Record each finding below with: invariant violated, minimal trace, reproducing
test, affected versions, and severity. Decide disclosure per finding.

## Findings

_None yet._

## Session log

- **2026-10-22**: Surveyed existing work: upstream raft TLA+ spec and trace
  validation, robustness tests (porcupine), Jepsen 3.4.3, Antithesis,
  ModelFuzz, SysMoBench. Mapped server membership code paths (table above).
  Wrote this plan. Next: P0.
