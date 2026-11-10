# Upstream reports: ready-to-post text

Prepared 2026-11-10 against `etcd-io/etcd` main `d622ec5` and `etcd-io/raft`
main `c51f010`. Nothing here has been posted.

## What to post, in order

| # | File | Where | Branch it links to |
|---|---|---|---|
| 1 | `1-promote-unreachable-learner.md` | new issue, etcd-io/etcd | `zjs/etcd:report/promote-unreachable-learner` |
| 2 | `2-reconfig-check-stale-view.md` | new issue, etcd-io/etcd | `zjs/etcd:report/reconfig-check-stale-view` |
| 3 | `3-compaction-waiter-after-restore.md` | new issue, etcd-io/etcd | `zjs/etcd:report/compaction-waiter-after-restore` |
| 4 | `4-max-learners-divergence.md` | new issue, etcd-io/etcd (design discussion, no fix) | `zjs/etcd:report/max-learners-divergence` (repro only) |
| 5 | `8-raft-469-review.md`, then `5-raft-tla-comments.md` | review on etcd-io/raft #469; comments on #458 and #456 | `zjs/raft:report/tla-membership-restart` |
| 6 | `6-defrag-dir-fsync-comment.md` | comment on etcd-io/etcd #22498 | `zjs/etcd:report/defrag-dir-fsync` |
| 7 | `7-lease-checkpoint-comment.md` | comment on etcd-io/etcd PR #22650 | `zjs/etcd:report/lease-checkpoint-renew-race` |
| 8 | `9-etcd-22702-confirmation.md` | comment on etcd-io/etcd PR #22702 (someone else's fix, confirmed independently) | none |

1 and 2 share a code path and a design question (where the strict reconfig
checks should run); post them together and cross-link them.

## Disclosure

Suggested wording, to replace each `[see README.md, "Disclosure"]`. Adjust
it until every sentence is true of what you did yourself.

For the issues with a candidate fix (1, 2, 3):

> **AI disclosure.** This was found by an AI agent (Claude Code) that I
> directed to model this part of etcd in TLA+ and check the model against
> the code. The agent also wrote the reproduction, the linked branch and the
> first draft of this report. I have run the reproduction and read the code
> paths described here, and I'll answer questions myself. I haven't opened a
> PR because I'd rather you decide on the approach first.

For 4, drop "the linked branch" and the last sentence. For the comments
(5, 6, 7), one line is enough:

> AI disclosure: found with an AI agent (Claude Code) under my direction; I
> have run the witness/test above myself and will answer follow-ups myself.

## Before posting

- **Run each reproduction yourself.** The disclosure says you did.
- **Commits are authored by `Claude <noreply@anthropic.com>` with no
  sign-off and no AI trailers.** Before any PR:
  `git rebase upstream/main --exec 'git commit --amend --reset-author -s --no-edit'`
- **Rewrite commit messages in your own words before a PR.** etcd's PR
  template defers to the Kubernetes AI guidance, which disallows AI-written
  commit messages, AI co-author or `assisted-by` trailers, and AI-written
  replies to review.
- The `hack/repro` and `hack/tla` commits and raft's `tla/witness` commit
  are reference material; leave them out of any PR.

## Why 5, 6 and 7 are comments, not issues

**5 (raft TLA+).** The `hup` guard is already reported in #456 with two open
PRs, #458 and #469, neither reviewed. On #456 a maintainer said no
maintainer knows TLA+ well enough to review, and suggested giving `tla/`
its own approvers. A third PR would join that queue. What is scarce is
review, and the branch gives you something concrete to offer: the
`TwoLeadersWitness` schedule still violates `MoreThanOneLeaderInv` with
either PR applied (checked with TLC on both PR heads).

**6 (directory fsync).** The `OpenSnapshotBackend` half is issue #22498, with
two competing open PRs (#22499, #22518) and no maintainer response. Only the
defrag half is new, so the branch now contains only that. #22314, the
merged fix for `SaveDBFrom`, was accepted on a code-reading argument plus a
reproduction on non-journaled ext2; nobody questioned whether it matters.

**7 (lease checkpoint).** The swallowed error is issue #22649 / PR #22650
(opened 2026-10-23, no maintainer response). The ordering race is not
covered by that PR, and the unit test and model show the PR alone doesn't
close it. The feature is alpha and off by default, and its tracking issue
#13776 was closed as stale, so expect low priority.
