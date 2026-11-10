# Comment for etcd-io/etcd PR #22650 (no new issue; see README.md for why)

Propagating the error is needed, but with only that change a renewed lease can still expire early after a leader change. There is an ordering race that involves no failed proposal:

1. The checkpoint loop computes `remainingTTL = R` for a lease from its current expiry and proposes it.
2. Before that entry is applied, the client renews. `Renew` looks at the *applied* `remainingTTL`, sees 0, so it proposes no clearing checkpoint, and refreshes the expiry to the full TTL.
3. The checkpoint from step 1 is applied: the replicated `remainingTTL` is now `R`, computed before the renewal.
4. The leader changes before the next renewal or checkpoint. The new leader restores the lease from `R` and expires it before the TTL the renewal promised.

It matters to clients that renew late in the TTL or stop renewing and rely on the promised TTL; a client renewing every TTL/3 usually clears the stale value first.

Evidence:

- Unit test `TestLessorRenewDuringScheduledCheckpoint` on [`zjs/etcd:report/lease-checkpoint-renew-race`](https://github.com/zjs/etcd/tree/report/lease-checkpoint-renew-race). Without the lessor change it fails with "lease expires 2.99s before the TTL promised by the renewal (remainingTTL=3)". It uses a fake checkpointer, so it fails the same way with this PR applied.
- A small TLA+ model on the same branch (`hack/tla/leasecp`). `NoPrematureExpiry` is violated for the current code, still violated when only checkpointer errors are reported (`MCfixerr.cfg`), and holds when a renewal and a scheduled checkpoint of the same lease can't overlap (`MCfixall.cfg`, 213,725 distinct states).

The branch closes the race with a per-lease mutex, which a renewal holds across its clearing proposal and the checkpoint loop takes with `TryLock`. That means a keepalive can wait behind a checkpoint batch's raft round trip, so I'm not confident it is the design you'd want; an alternative is to tag checkpoints with a per-lease renewal counter and ignore stale ones at apply. I'm raising it here rather than as a separate PR so the two changes don't collide.

Also on the branch: `Renew` returns `ErrNotPrimary` if the lessor was demoted while it waited for its checkpoint, instead of acknowledging the renewal.

AI disclosure: found with an AI agent (Claude Code) under my direction; I have run the checks above myself and will answer follow-ups myself.
