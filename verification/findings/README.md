# Findings triage (P5)

Status as of 2026-10-24. Nothing here has been reported upstream. Draft
issue texts are in this directory; each needs a final check against current
`main` and the upstream issue tracker before filing. Candidate fixes are
listed below the table.

| # | Finding | Impact | Preconditions | Affected | Evidence | Fix direction | Proposed channel |
|---|---|---|---|---|---|---|---|
| A (H1, H1b, H1c) | `--max-learners` is checked at apply time against each member's own flag | Membership and raft ConfState diverge. Starting the extra learner makes the other members **panic** (likely a crash loop on restart, by code reading). Promoting such learners can reach voter sets with disjoint majorities (model) | Members started with different `--max-learners`; learners added up to the higher limit | 3.6.x, 3.7.x and main. Not 3.5 (limit is a constant) | `TestH1MixedMaxLearners`, `TestH1cExtraLearnerStartPanics` (3/3), model `MCH1bWitness`, membership traces | Enforce the limit only when proposing (leader); keep apply-time validation independent of local flags; don't panic on attribute updates for unknown members | Public issue. Admin-only trigger, but a panic: maintainers may prefer the security form; your call |
| B (H2) | Promote guard ignores whether the learner and voters are reachable now | Promoting a caught-up learner that has since stopped, while a voter is down, loses quorum; StrictReconfigCheck accepts it | One voter down; learner caught up, then stopped; operator promotes | All releases with learners (3.4.0+; code unchanged through v3.7.3), and main | `TestH2PromoteDeadLearner` (3/3), model H2, membership trace | Count only voters connected for HealthInterval, plus require the learner connected (model: exhaustive pass, `H2fix`) | Public issue |
| C (H3) | Guards run on the receiving member's local view, not where changes are serialized | Two consecutive or concurrent membership changes through different members can lose quorum under StrictReconfigCheck | Even voter count (2 or 4) with one voter down; the second change reaches a member that hasn't applied the first, or both are checked before either commits | Remove-based: v3.4.x to v3.7.x and main. Add-based: v3.5.30+, v3.6.11+, v3.7.x, main (after #21641) | `TestH3StaleViewAddVoter`, `TestH3StaleViewRemove` (3/3), guard enumeration, model H3, membership traces | Re-run the guard on the leader when it appends the entry (pending-change rule serializes it), or carry the checked config index and refuse if it changed (model: no violation within bounds, `Hleader`) | Public issue |
| D | `etcd-io/raft` TLA+ spec vs code | The spec admits two leaders in one term (false alarm against the code) and doesn't enforce one change at a time; upstream trace validation can't handle restarts | n/a (spec and tooling) | `etcd-io/raft` `tla/` at v3.7.0 | `verification/raft/SOURCE.md` F1–F6, T1; `MCwitness` | The fork's F1–F6 and T1 changes | Public issue or PR on `etcd-io/raft` |

## Status after maintainer-perspective review (2026-10-24)

Each draft issue and fix was reviewed by a fresh reviewer acting as an
upstream maintainer (`reviews/`). The drafts, fixes and reproductions below
are the revised versions. Each reproduction runs on stock upstream binaries
or specs and fails there; nothing depends on this branch's scaffolding.

| Finding | Upstream deliverable | Reproduction maintainers can run | Status |
|---|---|---|---|
| A | Issue with design options (`issue-A-max-learners.md`); no fix proposed yet | `repro/A-max-learners.sh`: diverged member lists, panics on m2/m3, panic again on restart, no quorum | Ready to file; fix waits for maintainers' choice |
| B | Issue + PR: `fix/promote-reachable-quorum` (2 commits) | `repro/B-promote-unreachable-learner.sh`; `TestMemberPromoteUnreachableLearner` (fails on main) | Ready to file |
| C | Issue + PR: `fix/membership-check-committed-view` (stale-view case) | `repro/C-stale-view.sh add\|remove` (gofail build); `TestMemberReconfigStaleView` (e2e, fails 6/6 on main, passes 16/16 with the fix) | Ready to file |
| D | Issue + PR for etcd-io/raft: `../raft/upstream-patches/` (7 commits) | `repro/D/TwoLeadersWitness`, `repro/D/RestartWitness` (TLC) | Ready to offer |

Shelved, kept for reference:
- `fix/max-learners-at-propose`.
  - Its proposal-time check leaves members with the lower limit unable to
    restart.
  - Removing the panic exposes the voter-set split that the panic now
    prevents.
- `fix/membership-check-cas` (option 2 for C). It needs, first:
  - a fix for replaying a rejected remove (its side effects still run);
  - a digest computed atomically with the check;
  - WAL version detection of the new field;
  - an error-code decision.

  The issue describes this as a follow-up design discussion.

Changes made because of the reviews:
- **B:**
  - The check now applies only to learners. The first version broke
    promoting a voter (`TestMemberPromoteMemberNotLearner`, which only runs
    with gofail).
  - The forwarding error mapping is its own commit, with tests.
  - The integration test waits on the transport's active-peer metric
    instead of sleeping, and also covers successful promotion after the
    learner returns.
  - Versions corrected: all releases with learners (3.4.0+).
- **C:**
  - Added an e2e test with upstream's `beforeApplyOneConfChange`
    failpoint.
  - The remove case also needs the removed member's apply delayed: it
    closes its connections as soon as it applies its own removal.
  - The issue now describes the residual case precisely.
- **A:** reframed as raising the flag one member at a time. It now covers
  the existing startup checks, the restart cost, and design options.
- **D:**
  - The reviewer found a further two-leaders path through `Restart`.
    Commit 1 of the series fixes it.
  - The switches became unconditional, `reconfigCount` counts proposals,
    `SYMMETRY` is removed, and T1 is tightened.

Regression runs for the revised fixes (each branch on its own):
- **B:**
  - unit tests;
  - integration `clientv3` member/promote tests with gofail enabled;
  - `-race` on the new test;
  - e2e `TestRuntimeReconfigGrowClusterSize`, `TestReproduce20340`,
    `TestCtlV3MemberPromote*`, `TestMemberReplaceWithLearner`;
  - lint.
- **C:**
  - unit tests;
  - the integration member tests (earlier run);
  - the new e2e test, 16/16 with the fix;
  - lint.

Lower priority observations, not drafted as issues:
- A second conf change while one is pending is silently replaced by raft
  with an empty entry; the client waits for its timeout instead of getting
  an error (`membership-map.md` Q1).
- The backend's `meta/confState` is written on every conf change but never
  read; restart rebuilds ConfState from the members bucket.
- Learner failpoints for the robustness suite
  (`tests/robustness/failpoint/learner.go`) could be offered upstream on
  their own; they pass linearizability and watch validation.

Ordering suggestion: C and B first (same code path, one design discussion
about where guards run), then A (needs a decision on how a per-member flag
should behave), D independently.
