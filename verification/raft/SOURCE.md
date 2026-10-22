# Source of these files

Copied unchanged from `go.etcd.io/raft/v3@v3.7.0`, directory `tla/` (the
version this repo's `go.mod` uses). Upstream: https://github.com/etcd-io/raft.
The files keep their original Apache-2.0 headers.

| File | SHA-256 at copy time |
|---|---|
| `etcdraft.tla` | `15c445684529c59a59877951c7fb7df9a40da250aaa445f056ef48f56bb27044` |
| `etcdraft.cfg` | `0279cc6c7c100f622e30230ad56d383eb9d9bd8ac99c996fe707710106a9960e` |
| `MCetcdraft.tla` | `3b206581c4d1e8795b543f6bec1c293ea69241183acbdec6537c0265234a72b6` |
| `MCetcdraft.cfg` | `5cc769549deb7acdf280a8b2600d87c88810c299f5102b15f5176f64a9ae04a9` |
| `Traceetcdraft.tla` | `93e46f774c6602674d6f6db90c75ddc4144cfadc101c2f1cb31fd1ce2e90b0bc` |
| `Traceetcdraft.cfg` | `f146d25a0311f6944f5f3b3a89dcd66409d7fc3aac9326373b7cebf70a0b1795` |
| `README.md` | `97a96cd4fcc5429da35a7d36e2c8fbca01cebbac844c0c88188a75a1d9fd1e78` |
| `example.ndjson` | `cd02768bd1849a717d9abaf29612d7901efe8048d2b3fa25d9a66ba3df7f7db7` |
| `validate.sh` | `f3e9cd5de811a76072a3973850778c9172fcd91723f6105f0df19c4a8f8447b5` |
| `validate-model.sh` | `212f61a008bc1f1bc808bdc280b5d5f08d9fd156b4f0bf9d4ecc812379ebe1ee` |

Upstream's `validate*.sh` download tools from `nightly.tlapl.us` and GitHub,
which may be unreachable from cloud sessions. Use `../tools/tlc.sh` instead.

Files added in this fork (not from upstream):

- `SOURCE.md`: this file.
- `MCetcdraft-smoke.cfg`: `MCetcdraft.cfg` with smaller bounds for quick
  checks (2 initial members + 1 spare, 1 reconfiguration, 1 client request,
  terms ≤ 3).
