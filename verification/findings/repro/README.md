# Reproductions

Standalone scripts that reproduce each finding on stock upstream binaries
(bash, `etcd`, `etcdctl`, `curl`). Each runs local members on 127.0.0.1
(ports 21379–29380), keeps data in a temporary directory (`KEEP=1` keeps
it), and prints a `RESULT:` line.

```sh
make build                       # in an etcd checkout
ETCD_BIN_DIR=$PWD/bin verification/findings/repro/A-max-learners.sh
```

| Script | Finding | Needs | Expected on `main` (3aaab3479) | With the fix |
|---|---|---|---|---|
| `A-max-learners.sh` | A | — | member lists differ; m2, m3 panic (`failed to update; member unknown`) and panic again on restart; no quorum | (no fix yet) |
| `B-promote-unreachable-learner.sh` | B | — | promote accepted; write fails | promote refused (`unhealthy cluster`) |
| `C-stale-view.sh add` / `remove` | C | gofail build: `make gofail-enable && make build` | second change accepted; write fails | refused (`unhealthy cluster`) |
| `D/TwoLeadersWitness`, `D/RestartWitness` | D (etcd-io/raft) | TLC; copy into raft's `tla/` | see `../issue-D-raft-tla.md` | blocked (deadlock at a disabled step) |

All were run against binaries built from `main` at 3aaab3479 and from the
fix branches (2026-10-24).
