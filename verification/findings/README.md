# Findings triage (P5)

Status as of 2026-10-23. Nothing here has been reported upstream. Draft
issue texts are in this directory; each needs a final check against current
`main` and the upstream issue tracker before filing.

| # | Finding | Impact | Preconditions | Affected | Evidence | Fix direction | Proposed channel |
|---|---|---|---|---|---|---|---|
| A (H1, H1b, H1c) | `--max-learners` is checked at apply time against each member's own flag | Membership and raft ConfState diverge. Starting the extra learner makes the other members **panic** (likely a crash loop on restart, by code reading). Promoting such learners can reach voter sets with disjoint majorities (model) | Members started with different `--max-learners`; learners added up to the higher limit | 3.6.0+ and main. Not 3.5 (limit is a constant) | `TestH1MixedMaxLearners`, `TestH1cExtraLearnerStartPanics` (3/3), model `MCH1bWitness`, membership traces | Enforce the limit only when proposing (leader); keep apply-time validation independent of local flags; don't panic on attribute updates for unknown members | Public issue. Admin-only trigger, but a panic: maintainers may prefer the security form; your call |
| B (H2) | Promote guard ignores whether the learner and voters are reachable now | Promoting a caught-up learner that has since stopped, while a voter is down, loses quorum; StrictReconfigCheck accepts it | One voter down; learner caught up, then stopped; operator promotes | Every release since 3.4.16 (guard from #11640), and main | `TestH2PromoteDeadLearner` (3/3), model H2, membership trace | Count only voters connected for HealthInterval, plus require the learner connected (model: exhaustive pass, `H2fix`) | Public issue |
| C (H3) | Guards run on the receiving member's local view, not where changes are serialized | Two consecutive or concurrent membership changes through different members can lose quorum under StrictReconfigCheck | Even voter count (2 or 4) with one voter down; the second change reaches a member that hasn't applied the first, or both are checked before either commits | Remove-based: all checked versions (code identical in v3.5.29, v3.6.10, main). Add-based: v3.6.11+, v3.5.30+, main (after #21641) | `TestH3StaleViewAddVoter`, `TestH3StaleViewRemove` (3/3), guard enumeration, model H3, membership traces | Re-run the guard on the leader when it appends the entry (pending-change rule serializes it), or carry the checked config index and refuse if it changed (model: no violation within bounds, `Hleader`) | Public issue |
| D | `etcd-io/raft` TLA+ spec vs code | The spec admits two leaders in one term (false alarm against the code) and doesn't enforce one change at a time; upstream trace validation can't handle restarts | n/a (spec and tooling) | `etcd-io/raft` `tla/` at v3.7.0 | `verification/raft/SOURCE.md` F1–F6, T1; `MCwitness` | The fork's F1–F6 and T1 changes | Public issue or PR on `etcd-io/raft` |

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
