# Issue for etcd-io/etcd

**Title:** mvcc: a compaction queued when Restore runs never closes its done channel, so a physical Compact hangs

### Bug report criteria

- [x] This bug report is not security related.
- [x] This is not a support request or question.
- [x] You have read the etcd bug reporting guidelines.
- [x] Existing open issues along with etcd FAQ have been checked and this is not a duplicate.

### What happened?

`store.Restore` (leader snapshot install) closes `s.stopc` and stops the FIFO scheduler while holding `s.mu`. A compaction job still queued at that point runs with a cancelled context and goes straight to `compactBarrier`. With `s.stopc` closed, `compactBarrier` returns without closing the job's done channel and without rescheduling (since #11817 it doesn't reschedule in that case, to avoid a deadlock with `Restore`).

Nothing closes that channel afterwards. A `Compact` request with `physical=true` waits on it with no timeout (`v3_server.go`: `<-result.Physc`), so the client call hangs until its own deadline and the server goroutine is leaked.

Low severity: it needs a member to have a compaction queued behind a running one at the moment it installs a snapshot, and the cost is one hung RPC and one goroutine per occurrence.

### What did you expect to happen?

The waiter is released. A compaction interrupted while *running* already does this: `scheduleCompaction` returns an error and the job closes the channel.

### How can we reproduce it (as minimally and precisely as possible)?

Unit test `TestCompactionQueuedAcrossRestoreSignalsDone` on branch [`zjs/etcd:report/compaction-waiter-after-restore`](https://github.com/zjs/etcd/tree/report/compaction-waiter-after-restore). It queues a second compaction behind one that is sleeping between batches, calls `Restore`, and waits on both channels. On main (d622ec5) the second channel never closes.

### Anything else we need to know?

- **Candidate fix.** The same branch: `compactBarrier` closes the channel when the store is stopping (one line plus the test). Happy to open a PR if you agree.
- **How it was found.** A TLA+ model of non-blocking defragmentation and the goroutines that share its locks reported a deadlock on this path; the unit test confirms it in Go.
- **AI disclosure.** [see README.md, "Disclosure"]

### Etcd version (please run commands below)

```
$ etcd --version
etcd Version: 3.8.0-alpha.0
Git SHA: d622ec5
```

### Relevant log output

N/A.
