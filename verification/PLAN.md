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
- Go instrumentation lives behind the `with_tla` build tag, in separate files
  where possible. A default build must stay byte-for-byte unaffected, so the
  fork can be rebased on upstream with few conflicts.

## Decisions

- **2026-10-22**: Scope includes P4, checking real etcd runs against the
  models (not only model checking the specs). This requires build-tagged
  instrumentation of server code in this fork.

## Status

- [x] **P0 Tooling**: run TLC in a cloud session, pinned versions, one script.
- [x] **P1 Code map and informal invariants**: write down, in prose, what
      must be true; review each against the code.
- [x] **P2 Raft-layer model**: check membership properties on the existing
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

**P0 results (2026-10-22, cloud session: 4 cores, 15 GB, OpenJDK 21):**

- `tools/tlc.sh` pins TLC build 2026.10.06 (rev `94d0c50`) via the TLA+ VS
  Code extension 2026.10.60203 on Open VSX. `nightly.tlapl.us` and GitHub
  release downloads were not reachable from the session. First fetch takes
  about 1 s, so no SessionStart hook is needed.
- `raft/` holds the upstream spec unchanged (see `raft/SOURCE.md`).
- **Exhaustive (BFS) checking does not finish in a session**, even at small
  bounds. The spec allows unbounded crashes, drops, duplicates and
  heartbeats. With no invariant violations in either run:
  - 3 members + 1 spare, 1 reconfig, 1 request, term ≤ 3: 5.7M distinct
    states, depth 14 after 10 min, queue still growing.
  - `MCetcdraft-smoke.cfg` (2 + 1 spare, same limits): 16.2M distinct
    states, depth 18 after 15 min, queue at 9.9M and growing.
- **Simulation is the practical in-session mode.** Upstream
  `MCetcdraft.cfg`, `-simulate num=30000 -depth 100`, 3 workers: 90,000
  random behaviors (mean length 85), 9.4M states, 6 min 37 s, no
  violations (seed `8692819047272779617`).
- **Trace validation** of upstream `example.ndjson` (4,888 lines) needs
  `-workers 1` (the spec asserts it). **Passed**: 4,998 states, depth
  4,998, no errors, in 45 min 12 s. It slows as it goes (about 3,400 events
  in the first 15 min, then about 100/min), so cost grows faster than
  linearly with trace length.

Consequences for later phases:

- P2 needs state constraints (e.g. caps on crashes and in-flight messages)
  to get exhaustive results at small bounds; otherwise rely on simulation
  plus long runs outside sessions.
- P4 traces must stay short (hundreds to low thousands of events per file),
  or validation will dominate session time.

How to run:

```sh
verification/tools/tlc.sh -workers auto -config verification/raft/MCetcdraft-smoke.cfg verification/raft/MCetcdraft.tla
verification/tools/tlc.sh -workers 3 -simulate num=30000 -depth 100 -config verification/raft/MCetcdraft.cfg verification/raft/MCetcdraft.tla
JSON=$PWD/verification/raft/example.ndjson verification/tools/tlc.sh -workers 1 -lncheck final -config verification/raft/Traceetcdraft.cfg verification/raft/Traceetcdraft.tla
```

### P1 Code map and informal invariants

**Done:** see [`membership-map.md`](membership-map.md) for the pipeline,
stores, answers to the questions below, invariants I1–I12 and hypotheses
H1–H3.

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
| Stores | Raft `ConfState` (persisted via backend hooks), backend `members` and `members_removed` buckets, in-memory `RaftCluster`, transport peer set. (v2store is no longer used for membership at runtime; see `membership-map.md` §2) |
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

**P2 results (2026-10-22).** Files are listed in `raft/SOURCE.md`.

*Spec–code differences found and fixed (F1–F3, unconditional):*
- F1: promoting a learner left it in the learner set.
- F2: the spec asked learners for votes.
- F3: one stray vote blocked an election.

*Code rules added as switches (F4–F6; FALSE = upstream behavior):*
- F4: no campaigning with a committed but unapplied config entry.
- F5: a new leader may propose a config change only once
  `applied ≥ lastIndex` at its election. This also fixes an upstream spec
  bug: the pending marker is cleared on a reversed condition, so the spec
  never enforced one change at a time.
- F6: a follower learns the commit index in the same step as it appends.

*Main result: two leaders in one term, unless the code's rules are
modeled.* `raft/MCwitness.tla` is a 71-step behavior checked by TLC:

1. Initial config C0 = {1,2,3}. Node 1 adds 4 (C1), then removes 3 (C2 =
   {1,2,4}).
2. Node 3 has appended both config entries but hasn't learned that C1
   committed.
3. In term 3, node 3 wins on C0 with votes {3,1}, and node 2 wins on C2
   with votes {2,4}.

| F4 (campaign guard) | F6 (atomic commit) | Result |
|---|---|---|
| off | off | `MoreThanOneLeaderInv` violated |
| off | on | violated |
| on | off | violated |
| on | on | blocked: node 3 can't campaign |

So the upstream spec admits a split-brain the code prevents. The code
needs **both** rules to block this behavior.

The supporting property is `KnowsPrevConfigCommittedInv`: a node holding a
config entry knows the previous one is committed. It depends on:
- F5 (leader side): a change is proposed only after the previous one is
  applied, so any message carrying C(n+1) also carries commit ≥ C(n);
- F6 (follower side): commit is learned atomically with the entries.

F4 then keeps a campaigning node's config within one step of the latest.
With single-step changes, adjacent configs have overlapping quorums.

*Random simulation, code-faithful (F4–F6 on), all 14 invariants, no
violations:*
- `MCmembership.cfg` (reliable network): 37,841 behaviors (mean length
  127), 5 min.
- `MCmembership-full.cfg` (crashes, drops, duplicates): 44,009 behaviors,
  5 min.
- `MCmembership-upstream.cfg` (F4–F6 off) violates
  `KnowsPrevConfigCommittedInv` within seconds.

*Limits:*
- Exhaustive search does not reach the needed depth (~70 steps). BFS was
  stopped at depth 16–19 with 6–7M states and no violations, both on the
  general model and on the directed scenario.
- "Both rules on → safe" is supported by simulation and by blocking the
  known attack, not proved.
- The calibration in the plan (#10998) turned out to be a **liveness** bug
  (elections stalling while a learner refuses to vote). The witness serves
  as calibration instead: the model finds a safety violation as soon as a
  code rule is removed.

*Upstream spec issues worth offering to `etcd-io/raft` (spec bugs, not
code bugs):*
- F1–F3;
- the reversed pending-marker reset;
- missing F4/F6, which lets the spec reach `MoreThanOneLeaderInv`
  violations (a false alarm against the code);
- `SYMMETRY` over an asymmetric spec.

*For etcd:* the safety of etcd's apply-time, one-at-a-time
reconfiguration rests on three code details: `hup`'s unapplied-conf-change
check, `maybeAppend` committing atomically, and `pendingConfIndex =
lastIndex` at election. Changing any of them needs the same scrutiny as a
protocol change.

Trace validation of upstream `example.ndjson` against the patched spec
(upstream-mode switches): **passes**. Same result as P0: 4,998 states, no
errors, in 46 min. F1–F3 don't break trace validation.

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

Checks that real etcd processes behave as the models say. A model that passes
model checking but doesn't match the code proves little.

**P4a: Raft-layer traces from real etcd.**
- The etcd server does not currently wire up raft's `TraceLogger`. Add a
  `with_tla` file in `server/etcdserver/` that sets `raft.Config.TraceLogger`
  and writes NDJSON to a path from an env var; a nop file for default builds.
- Teach the e2e framework to build with the tag and collect per-member trace
  files, with the robustness report artifacts.
- Run membership e2e tests and robustness `MemberReplace`, then validate with
  upstream `Traceetcdraft.tla` / `validate.sh`.
- Known upstream limits to plan around (from `tla/README.md`): the merge
  sorts on a timestamp field, so members must run on one machine; the
  spec assumes atomic persistence, so crash traces may give false alarms;
  validation slows sharply past a few thousand events per file, so keep
  runs short and QPS low.

**P4b: Server-layer traces.**
- Instrument the membership paths from the P1 map (guard decisions,
  propose, apply/validate, each store write, recover) under the same tag,
  using the variable names of `EtcdMembership.tla`.
- Write `TraceEtcdMembership.tla` mapping events to spec actions, following
  the upstream `Traceetcdraft.tla` pattern.
- Ordering across members: membership events are applied in log order, so
  key events by (term, index) where possible and use timestamps only for
  proposal-side events.

**P4c: Exercise more behavior.**
- Add robustness failpoints for learner add → promote, and learner removal,
  run with existing fault injection (kill, blackhole, gofail).
- A run that never reaches a code path gives no evidence about it. Record
  which spec actions each trace set covers, and add scenarios until every
  membership action is covered.

**P4d: Counterexamples to tests.**
- For each P3 counterexample, write an integration test that drives the same
  interleaving against real code (gofail failpoints where needed).

### P5 Findings

Record each finding below with: invariant violated, minimal trace, reproducing
test, affected versions, and severity. Decide disclosure per finding.

## Findings

Reproduced on real in-process clusters (not yet triaged for disclosure;
details in `membership-map.md` §5). Run with
`cd tests && go test -tags verification ./integration/verification/ -v`.

| # | Summary | Test | Result |
|---|---|---|---|
| H1 | Members with different `--max-learners` apply the same learner add differently; raft `ConfState` diverges | `TestH1MixedMaxLearners` | reproduced 3/3 |
| H2 | Promote guard has no live-connectivity check; promoting a caught-up but dead learner with one voter down loses quorum | `TestH2PromoteDeadLearner` | reproduced 3/3 |
| H3 | Add guard on a member one change behind accepts a voter add that an up-to-date member refuses; quorum lost | `TestH3StaleViewAddVoter` | reproduced 3/3 |
| H3 (remove) | Remove guard on a member one change behind (still counting the just-removed member as connected) accepts a removal that an up-to-date member refuses; quorum lost | `TestH3StaleViewRemove` | reproduced 3/3 |

P5 for each: search upstream issues and PRs, find affected versions, rate
severity, then decide on disclosure.

### Upstream search (2026-10-22)

Method: web search of `etcd-io/etcd` issues and PRs, reading the linked
threads, and searching upstream commit history and release branches. The
GitHub issue API was not available in the session, so "nothing found" means
not found by these searches, not "definitely unreported".

**H1 (mixed `--max-learners`): risk acknowledged, consequence not
discussed.**
- The flag was added in PR #13377 (2021, experimental; made GA as
  `--max-learners` in 3.6, `27d9978c8`, `06edd83d2`).
- The PR description says members can technically be started with
  different values, and that "care was taken" to validate.
- A reviewer said a mismatch "could cause hard to debug behavior on leader
  change" and proposed a metric hashing the config that must match across
  members. It was left as a follow-up; no implementation found.
- Nobody discussed that the limit is checked when applying log entries, so
  members diverge.
- Affects 3.6.x and main. Not 3.5: there the limit is a constant 1
  (`release-3.5` `cluster.go:46`).

**H2 (promote without a liveness check): no report found.**
- Promote guard history: `dfe296ac3` (2019, `mayPromote` check), then
  `6991f619f` (2020, PR #11640 for #11633). That fix made the guard count
  the learner as "started" so N→N+1 promotion works. It does not consider
  whether the learner is reachable now.
- Issue #12186 (promotion while quorum is already lost) is a different
  question.
- Unchanged since 2020 on release-3.5, release-3.6 and main, so it affects
  every release with learner promotion (3.4.5+ by the 2020 date; exact 3.4
  tag not checked).

**H3 (guards on stale views): no report found; one recent change widens
it.**
- PR #21641 (fixes #21640, merged 2026-04-26) relaxed the add guard from
  "connected to all voters" to "connected to quorum(n+1)". It was
  backported in v3.6.11 and v3.5.30 (both 2026-05-01). Review discussed
  quorum after the add, but not races or stale views.
- `TestH3StaleViewAddVoter` needs one voter down, which the old guard
  refused. So **this specific scenario affects only v3.6.11+, v3.5.30+
  and main.**
- Rerunning `explore/guard_enum.py` with the old add guard still finds
  1,514 stale-view cases (e.g. remove → remove on 4 voters), so **H3 as a
  class predates #21641.**
- `TestH3StaleViewRemove` reproduces remove → remove on main (3/3). Every
  remove → remove case needs the first removed member still running when
  the stale member evaluates. The test freezes that member's apply so it
  hasn't processed its own removal yet.
- The remove guard is identical in v3.6.10 and main. v3.5.29 differs only
  cosmetically (error package names, member lookup). So this variant
  applies to releases before v3.6.11 / v3.5.30 by code equivalence. The
  test was not run against them.
- Adjacent, not the same: k0sproject/k0s#8530 (remove guard counts a
  partitioned peer as connected) and canonical/k8sd#159.

## Session log

- **2026-10-22**: Surveyed existing work: upstream raft TLA+ spec and trace
  validation, robustness tests (porcupine), Jepsen 3.4.3, Antithesis,
  ModelFuzz, SysMoBench. Mapped server membership code paths (table above).
  Wrote this plan. Decided to include P4 (real-run checking).
- **2026-10-22**: P0 done: pinned TLC runner, vendored upstream spec,
  baseline runs (see P0 results). Next: P1 code map.
- **2026-10-22**: P1 done: `membership-map.md`. v2store is out of the
  runtime membership path; backend `meta/confState` is written but never
  read. Three hypotheses (H1–H3) to test. Next: P2, plus early Go repro
  tests for H1/H2 since they are cheap.
- **2026-10-22**: Reproduced H1, H2 and H3 with integration tests (build
  tag `verification`). The guard enumeration shows stale-view gaps only from
  even voter counts. Next: P2.
- **2026-10-22**: Upstream search for H1–H3 (see Findings). None found as
  reported; H1's misconfiguration risk was noted in PR #13377 review. H3's
  add-voter variant is enabled by PR #21641 (v3.6.11/v3.5.30); the
  remove-based variants predate it. Next: P2.
- **2026-10-22**: Added `TestH3StaleViewRemove` (reproduced 3/3);
  remove-guard code is equivalent in v3.6.10 and v3.5.29. Next: P2.
- **2026-10-22**: P2 done.
  - Fixed 3 spec–code differences; added 3 code rules as switches; fixed
    the upstream pending-marker bug.
  - Witness: two leaders in one term unless both the campaign guard and
    atomic commit are modeled.
  - Code-faithful simulation is clean (82k behaviors).
  - Next: confirm trace validation, then P3.
- **2026-10-22**: Trace validation of the patched spec passes. Next: P3.
