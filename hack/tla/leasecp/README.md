# TLA+ model of lease checkpointing

`leasecp.tla` models one lease under the `LeaseCheckpoint` feature: the
leader's in-memory expiry, the replicated `remainingTTL` set by applied
checkpoint entries, scheduled checkpoints, `Renew` (which first proposes a
checkpoint clearing `remainingTTL`), proposals that commit in any order or are
dropped, and leader changes (`Promote(ElectionTimeout)` restores expiries from
`remainingTTL`).

Checked property `NoPrematureExpiry`: the lease is never revoked before the TTL
promised by the last acknowledged keepalive.

| Config | Mode | Expected result |
| --- | --- | --- |
| `MCbug.cfg` | code before the fix | violated: a scheduled checkpoint computed before a renewal is applied after it (no dropped proposal needed); a dropped clearing checkpoint is also acknowledged |
| `MCfixerr.cfg` | only report checkpointer errors and re-check leadership | violated: the scheduled-checkpoint race remains |
| `MCfixall.cfg`, `MCfixall_big.cfg` | per-lease lock between `Renew` and scheduled checkpoints, plus the above | pass |

```sh
java -XX:+UseParallelGC -cp tla2tools.jar tlc2.TLC -workers auto -config MCfixall.cfg leasecp.tla
```

Abstractions: one lease and one client; a global discrete clock; the stale
leader window bounded by CheckQuorum is not modelled (a leader change is
observed at once).
