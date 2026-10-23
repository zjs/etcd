# Patches for etcd-io/raft

`0001-tla-align-membership-handling-with-the-implementation.patch` carries
this fork's spec changes F1–F6 and T1 (see `../SOURCE.md`) to `tla/` in
etcd-io/raft. Compared with the copies here:

- `FORK(...)` markers and references to this repository are removed.
- The three new constants are TRUE (code-faithful) in upstream's
  `etcdraft.cfg`, `MCetcdraft.cfg` and `Traceetcdraft.cfg`.
- `MCetcdraft.cfg` checks the new membership invariants.
- `etcdraft.tla`'s changelog has an entry.

It applies to etcd-io/raft `main` at `1931ff5` (2026-10-19), whose `tla/`
is identical to v3.7.0:

```sh
cd raft && git am /path/to/0001-*.patch
```

The patch has no `Signed-off-by` line yet.

Checked with the patched files:

| Check | Result |
|---|---|
| Trace validation, 5 traces from etcd integration runs (basic, learner promote, remove follower, remove leader, restart follower) | pass |
| Trace validation, upstream `example.ndjson` | see `../../PLAN.md` session log |
| `MCetcdraft.cfg`, simulation, depth 100, 15 minutes | no violation (about 106k behaviors, 11.1M states) |
