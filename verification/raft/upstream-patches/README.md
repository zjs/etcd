# Patches for etcd-io/raft

A series of 7 commits for `tla/` in etcd-io/raft. It applies with `git am`
to `main` at `c51f010` (2026-10-24); `tla/` is unchanged since v3.7.0.

```sh
cd raft && git am /path/to/upstream-patches/*.patch
```

| # | Commit | Corresponds to (`../SOURCE.md`) |
|---|---|---|
| 1 | Restore only persisted log entries on restart | new (maintainer-perspective review, `../../findings/reviews/review-D.md`) |
| 2 | Model learner promotion and voting as the code does | F1–F3 |
| 3 | Model the pending conf change rule as the code does | F5, unconditional; `reconfigCount` at proposal |
| 4 | Model hup's conf change check and maybeAppend's atomic commit | F4, F6, unconditional |
| 5 | Check membership invariants; drop the symmetry reduction | invariants; `SYMMETRY` removed |
| 6 | Validate restarts at the BecomeFollower after loading state | T1, tightened |
| 7 | Document the applied-config assumption; changelog | — |

Unlike this fork's spec, the series has no switches: the code-faithful rules
are unconditional. The behaviors that the switches demonstrated are
replayable witnesses instead: `../../findings/repro/D/`.

The patches have no `Signed-off-by` lines yet.

Checked:

| Check | Result |
|---|---|
| SANY: `etcdraft`, `MCetcdraft`, `Traceetcdraft` at each commit | parse |
| `TwoLeadersWitness` | violates `MoreThanOneLeaderInv` on `main` and up to commit 3; deadlocks (blocked) from commit 4 |
| `RestartWitness` | violates on the series without commit 1; deadlocks on the full series (on `main` it stops earlier: its script needs commit 4) |
| Trace validation, 5 etcd traces (basic, learner promote, remove follower, remove leader, restart follower) | pass |
| Negative controls | a corrupted restart trace fails; the real restart trace fails on `main`'s trace spec |
| Trace validation, `example.ndjson` | see the PLAN session log |
| `MCetcdraft.cfg` simulation, depth 100, 15 minutes, 2 workers | no violation (about 97k behaviors, 10.1M states) |

The draft issue and PR description are in `../../findings/issue-D-raft-tla.md`.
