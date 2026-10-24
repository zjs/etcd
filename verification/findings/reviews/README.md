# Maintainer-perspective reviews (2026-10-23)

Each finding's draft issue and fix branch were reviewed by a separate
reviewer with no prior context. Each reviewer was asked to act as an
upstream maintainer seeing the issue and branch for the first time. The
reviews were read-only: nothing was pushed or posted.

The reports below are lightly edited (wording and formatting only). Tags
in the reports: **[run]/[test]** reproduced by the reviewer with a run,
**[code]** checked by reading code, **[judgment]** the reviewer's opinion.

| Finding | Review | Verdict | Outcome |
|---|---|---|---|
| A | [review-A.md](review-A.md) | Needs changes | Rewritten as an issue with design options; fix branch shelved |
| B | [review-B.md](review-B.md) | Needs changes | Fix revised (`fix/promote-reachable-quorum`) |
| C | [review-C.md](review-C.md) | Option 1: needs changes. Option 2: reject in its current form | Option 1 revised with an e2e test; option 2 shelved |
| D | [review-D.md](review-D.md) | Needs changes | Patch reworked into a series |

Claims re-checked by us after the reviews:
- B: `TestMemberPromoteMemberNotLearner` fails on the original branch with
  gofail enabled (promoting a voter returned `unhealthy cluster`). Confirmed.
- D: the reviewer's restart witness violates `MoreThanOneLeaderInv` on the
  patched spec with all three switches TRUE. Confirmed with TLC. Cause:
  `PersistState` stores only the log length, so `Restart` restores
  in-memory entries that were never persisted.
