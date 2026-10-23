# Findings triage (P5)

Status as of 2026-10-23. Nothing here has been reported upstream. Draft
issue texts are in this directory; each needs a final check against current
`main` and the upstream issue tracker before filing. Candidate fixes are
listed below the table.

| # | Finding | Impact | Preconditions | Affected | Evidence | Fix direction | Proposed channel |
|---|---|---|---|---|---|---|---|
| A (H1, H1b, H1c) | `--max-learners` is checked at apply time against each member's own flag | Membership and raft ConfState diverge. Starting the extra learner makes the other members **panic** (likely a crash loop on restart, by code reading). Promoting such learners can reach voter sets with disjoint majorities (model) | Members started with different `--max-learners`; learners added up to the higher limit | 3.6.0+ and main. Not 3.5 (limit is a constant) | `TestH1MixedMaxLearners`, `TestH1cExtraLearnerStartPanics` (3/3), model `MCH1bWitness`, membership traces | Enforce the limit only when proposing (leader); keep apply-time validation independent of local flags; don't panic on attribute updates for unknown members | Public issue. Admin-only trigger, but a panic: maintainers may prefer the security form; your call |
| B (H2) | Promote guard ignores whether the learner and voters are reachable now | Promoting a caught-up learner that has since stopped, while a voter is down, loses quorum; StrictReconfigCheck accepts it | One voter down; learner caught up, then stopped; operator promotes | Every release since 3.4.16 (guard from #11640), and main | `TestH2PromoteDeadLearner` (3/3), model H2, membership trace | Count only voters connected for HealthInterval, plus require the learner connected (model: exhaustive pass, `H2fix`) | Public issue |
| C (H3) | Guards run on the receiving member's local view, not where changes are serialized | Two consecutive or concurrent membership changes through different members can lose quorum under StrictReconfigCheck | Even voter count (2 or 4) with one voter down; the second change reaches a member that hasn't applied the first, or both are checked before either commits | Remove-based: all checked versions (code identical in v3.5.29, v3.6.10, main). Add-based: v3.6.11+, v3.5.30+, main (after #21641) | `TestH3StaleViewAddVoter`, `TestH3StaleViewRemove` (3/3), guard enumeration, model H3, membership traces | Re-run the guard on the leader when it appends the entry (pending-change rule serializes it), or carry the checked config index and refuse if it changed (model: no violation within bounds, `Hleader`) | Public issue |
| D | `etcd-io/raft` TLA+ spec vs code | The spec admits two leaders in one term (false alarm against the code) and doesn't enforce one change at a time; upstream trace validation can't handle restarts | n/a (spec and tooling) | `etcd-io/raft` `tla/` at v3.7.0 | `verification/raft/SOURCE.md` F1–F6, T1; `MCwitness` | The fork's F1–F6 and T1 changes | Public issue or PR on `etcd-io/raft` |

## Candidate fixes

Each fix is on its own branch of `zjs/etcd`, based on etcd `main` at
`3aaab3479`. A branch holds only the fix and upstream-style tests (no
verification scaffolding). No `Signed-off-by` yet. This branch carries
the same changes plus the scaffolding.

| Finding | Branch | Change | Tests (fail without the fix?) |
|---|---|---|---|
| A | `fix/max-learners-at-propose` (2 commits) | A1: check `--max-learners` in `mayAddMember` when proposing; keep the apply-time check while cluster version < 3.8, so members of different versions agree. A2: `UpdateAttributes` logs and skips an unknown member instead of panicking | `TestMaxLearnerMixedConfig` (integration, yes), `TestClusterValidateConfigurationChangeMaxLearners` (unit), `TestClusterUpdateAttributesUnknownMember` (unit, yes) |
| B | `fix/promote-reachable-quorum` | `mayPromoteMember` requires voters connected for `HealthInterval`, plus the learner if connected now, to be a quorum of the new config. A promote forwarded to the leader returns the refusal instead of retrying until timeout | `TestIsConnectedToQuorumAfterPromotingSince` (unit), `TestMemberPromoteUnreachableLearner` (integration, yes) |
| C, option 1 | `fix/membership-check-committed-view` | Linearizable read barrier before the add/remove guards (strict mode only) | None upstream-style: the stale window needs the scaffold's apply freeze |
| C, option 2 | `fix/membership-check-cas` | The conf change carries a digest of the membership the guard checked; apply rejects it with `ErrMembershipChanged` if the membership differs. Only from cluster version 3.8 | `TestClusterValidateConfigurationChangeCheckedMembership` (unit) |
| D | `verification/raft/upstream-patches/` | Patch for `etcd-io/raft` `tla/` (F1–F6, T1, invariants) | Trace validation of etcd runs |

Choices for maintainers:

- **A1** turns the limit into a proposal-time check, like the other
  membership guards. A member enforces its own flag on the requests it
  receives, and two concurrent learner adds can together exceed the limit
  (with option C2 and strict checking, the second is rejected). Alternatives:
  a cluster-wide limit stored in the backend, or refusing mismatched values
  at join.
- **A2** trades a crash loop for an error log. Divergence it would have
  exposed is still logged.
- **B** asks the learner only to be connected *now*. A first version
  required `HealthInterval` for the learner too and broke e2e tests that
  promote right after the learner catches up
  (`TestRuntimeReconfigGrowClusterSize`, `TestReproduce20340`). Residual
  gap: a learner cut off without the connection closing still counts until
  the transport notices.
- **C1 or C2.** C1 is small and changes no data, but it closes only the
  stale-view case, not two concurrent requests, and adds a ReadIndex round
  trip to member add and remove. C2 closes both (model: no violation within
  bounds, `Hcas`, `H3cas`), but changes the conf change context, adds an
  error code, and can reject a change that would have been safe; the client
  retries. They can ship together.
- **Open question for A1 and C2 (priors):** both change apply-time rules
  from cluster version 3.8. Entries replayed by an older binary after a
  downgrade are validated with the older rules. Downgrade lowers the cluster
  version first, so new entries stop using the new rules, but entries
  already in the WAL could be decided differently on replay.

Regression runs, all fixes together on this branch:

| Suite | Result |
|---|---|
| Unit: `server/etcdserver/...`, `api/...` | pass |
| Integration: `./integration/`, `./integration/clientv3/` (member, learner, promote, remove, restart, reconfig) | pass |
| `tests/common` member tests (integration mode) | pass |
| e2e: `TestMemberReplace*`, `TestCtlV3Member*`, `TestRemoveNonExistingMember`, `TestRuntimeReconfig*`, `TestCurlV3ClusterOperations`, `TestReproduce20340` and the other e2e test that grows clusters by promoting learners | pass (after the B change above) |
| Robustness learner failpoints | pass 4/4, plus 6/6 extra churn runs. One earlier failure ran alongside a linter build; its linearizability check passed (the report has `history.html`, written only on success) |
| Scaffold reproductions H1, H1c, H2, H3 (add and remove) | not reproduced with the fixes |

Per branch: builds; `golangci-lint` (v2.14.0, repo config) clean on changed
packages; its tests pass; gofail-only learner tests pass on the A branch.

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
