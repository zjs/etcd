# Issue for etcd-io/etcd

Each `###` section below is one field of the bug report form; paste what is
under the heading, not the heading. Tick the four "Bug report criteria" boxes
in the form itself. Three fields come prefilled and the last one renders as a
code block; those sections say what to do.

**Title:** mvcc: a compaction queued when Restore runs never closes its done channel, so a physical Compact hangs

### What happened?

`store.Restore` (leader snapshot install) closes `s.stopc` and stops the FIFO scheduler while holding `s.mu`. A compaction job still queued at that point runs with a cancelled context and goes straight to `compactBarrier`. With `s.stopc` closed, `compactBarrier` returns without closing the job's done channel and without rescheduling (since #11817 it doesn't reschedule in that case, to avoid a deadlock with `Restore`).

Nothing closes that channel afterwards. A `Compact` request with `physical=true` waits on it with no timeout (`v3_server.go`: `<-result.Physc`), so the client call hangs until its own deadline and the server goroutine is leaked.

Low severity: it needs a member to have a compaction queued behind a running one at the moment it installs a snapshot, and the cost is one hung RPC and one leaked goroutine per occurrence.

### What did you expect to happen?

The waiter is released. A compaction interrupted while *running* already does this: `scheduleCompaction` returns an error and the job closes the channel.

### How can we reproduce it (as minimally and precisely as possible)?

Add the test below to `server/storage/mvcc/kvstore_test.go` and run it. It queues a second compaction behind one that is sleeping between batches, calls `Restore`, and waits on both done channels.

```
$ cd server && go test -count=1 -run '^TestCompactionQueuedAcrossRestoreSignalsDone$' ./storage/mvcc/
--- FAIL: TestCompactionQueuedAcrossRestoreSignalsDone (3.12s)
    kvstore_test.go:520: compaction 2: done channel never closed after Restore
FAIL
FAIL	go.etcd.io/etcd/server/v3/storage/mvcc	3.134s
FAIL
```

<details>
<summary>TestCompactionQueuedAcrossRestoreSignalsDone</summary>

```go
// A compaction that is still queued when Restore runs must still signal
// its done channel; otherwise a physical Compact RPC waits forever.
func TestCompactionQueuedAcrossRestoreSignalsDone(t *testing.T) {
	b, _ := betesting.NewDefaultTmpBackend(t)
	s := NewStore(zaptest.NewLogger(t), b, &lease.FakeLessor{}, StoreConfig{
		CompactionBatchLimit:    1,
		CompactionSleepInterval: time.Hour, // keep the first job busy between batches
	})
	defer cleanup(s, b)

	for i := 0; i < 5; i++ {
		s.Put([]byte("foo"), []byte("bar"), lease.NoLease)
	}

	ch1, err := s.Compact(traceutil.TODO(), 3) // runs, then sleeps after its first batch
	if err != nil {
		t.Fatal(err)
	}
	ch2, err := s.Compact(traceutil.TODO(), 4) // queued behind the first job
	if err != nil {
		t.Fatal(err)
	}
	time.Sleep(100 * time.Millisecond)

	if err := s.Restore(b); err != nil {
		t.Fatal(err)
	}

	for i, ch := range []<-chan struct{}{ch1, ch2} {
		select {
		case <-ch:
		case <-time.After(3 * time.Second):
			t.Fatalf("compaction %d: done channel never closed after Restore", i+1)
		}
	}
}
```

</details>

### Anything else we need to know?

- **Candidate fix.** One commit on main at d622ec5, with the test above:
  https://github.com/etcd-io/etcd/compare/main...zjs:etcd:report/compaction-waiter-after-restore
  `compactBarrier` closes the channel when the store is stopping. With it, the test passes.
- **How it was found.** A TLA+ model of non-blocking defragmentation and the goroutines that share its locks reported a deadlock on this path; the test confirms it in Go.
- **AI disclosure.** This was found by an AI agent (Claude Code) that I directed to model this part of etcd in TLA+ and check the model against the code. The agent also wrote the reproduction, the linked branch and the first draft of this report. I have run the reproduction and read the code paths described here, and I'll answer questions myself. If you accept this issue as valid and would find it useful, I'll open a PR based on the candidate fix above.

### Etcd version (please run commands below)

Replace the field's prefilled text with:

<details>

```console
$ etcd --version
etcd Version: 3.8.0-alpha.0
Git SHA: d622ec5
Go Version: go1.27.3
Go OS/Arch: linux/amd64

$ etcdctl version
etcdctl version: 3.8.0-alpha.0
API version: 3.8
```

</details>

### Etcd configuration (command line flags or environment variables)

Replace the field's prefilled text with:

<details>

N/A: unit test, no cluster.

</details>

### Etcd debug information (please run commands below, feel free to obfuscate the IP address or FQDN in the output)

Replace the field's prefilled text with:

N/A: unit test, no cluster.

### Relevant log output

This field renders as a code block by itself, so paste only the text below, with no backticks:

N/A.
