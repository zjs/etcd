# TLA+ model of non-blocking defragmentation

`nbdefrag.tla` (PlusCal, translated) models `backend.defragNonBlocking` together
with the goroutines that share its locks: the apply loop (puts, lease-bucket
put/delete, compaction requests, leader snapshot install), periodic batch
commits, the scheduled compaction job, the physical `Compact` RPC waiter, the
corruption-check hasher, range readers and the maintenance snapshot stream.
Go `RWMutex` semantics are modelled (a waiting writer blocks new readers).

Checked properties:

- `dChk` assertion: the db renamed over the live one equals the live committed
  contents (key, lease and meta buckets), and is still the live backend instance.
- No deadlock (TLC deadlock check) and `DefragTerminates` (`<>defragDone`).

## Configs

| Config | Expected result |
| --- | --- |
| `MCbase.cfg` | pass |
| `MChash_snapsend.cfg` | pass |
| `MCmut_compaction_nolock.cfg` | assertion failure: compaction without `LockForSafeRangeDelete` leaves deleted revisions in the defragmented db |
| `MCmut_defrag_nobemu.cfg` | assertion failure: `Defragment` without `bemu.RLock` defrags a backend replaced by a snapshot |
| `MCphysc_snapshot.cfg` | deadlock: a compaction queued when `Restore` runs never closes its done channel, so a physical `Compact` waits forever |
| `MCphysc_snapshot_fixed.cfg` | pass (with `compactBarrier` closing the channel on stop) |
| `MClive_snapshot_fixed.cfg` | pass, including liveness |

## Running

```sh
java -cp tla2tools.jar pcal.trans -nocfg nbdefrag.tla   # only after editing the algorithm
java -XX:+UseParallelGC -cp tla2tools.jar tlc2.TLC -workers auto -config MCbase.cfg nbdefrag.tla
```

Abstractions: bbolt transactions are atomic steps; the bulk copy reads an
immutable snapshot so it is one step; batch sizes are 1; bbolt mmap remapping
and crashes are not modelled.
