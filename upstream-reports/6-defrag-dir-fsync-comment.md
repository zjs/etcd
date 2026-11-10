# Comment for etcd-io/etcd issue #22498 (no new issue; see README.md for why)

Defragmentation has the same gap, and it isn't covered by #22499 or #22518.

`finishDefrag` renames the defragmented `db.tmp.*` over the live db and reopens it, without syncing the directory. If the rename is lost in a power failure, the directory still names the pre-defrag file as `db`. Everything committed since the rename went to the defragmented file, which is still named `db.tmp.*` and is removed on bootstrap as an orphan.

What happens next depends on the WAL:

- Usually the member replays the WAL from the pre-defrag db's consistent index and recovers.
- If a raft snapshot newer than that index was saved in the window, the db is behind the snapshot and the member refuses to start.

I have not reproduced this with a real power loss; it is from reading the code, by analogy with the `SaveDBFrom` case fixed in #22314. The window is narrow on journaling filesystems, which usually persist the rename within seconds.

A candidate change, in case it is useful to whoever picks up this issue: [`zjs/etcd:report/defrag-dir-fsync`](https://github.com/zjs/etcd/tree/report/defrag-dir-fsync) (one commit; syncs the directory after the rename unless `--unsafe-no-fsync` is set, for both blocking and non-blocking defrag). I can open a PR, or it can be folded into whichever of the two existing PRs you prefer.

AI disclosure: [see README.md, "Disclosure"]
