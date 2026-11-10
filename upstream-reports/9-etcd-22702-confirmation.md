# Comment for etcd-io/etcd PR #22702

Rerun the commands yourself before posting; the comment says you did.

---

Independent confirmation, in case it helps triage while this waits for `/ok-to-test`. I cherry-picked the commit onto main at d622ec5 (applies cleanly) and ran the new test with and without the one-line change to `watch_broadcast.go`:

```
cd tests && go test -count=1 -run '^TestWatchProxyCatchUpNotCoalescedPastGap$' ./integration/proxy/grpcproxy/
```

| | Result, 3 runs each |
|---|---|
| without the change | fails 3/3: `watch_test.go:78: got 1000 events, want 2500` |
| with the change | passes 3/3 |

So on main, a watcher that starts at an old revision through the gRPC proxy, while another watcher on the same key is already current, received only the first 1,000 of 2,500 events before the test's 10-second timeout.

From reading the code, the mechanism is as the comment in the change says: a catch-up response carries the store's current revision in its header, `bcast` sets `nextrev` from the header, and `coalesce` then considers the catching-up broadcast level with the current one and merges it, skipping the events in between.

The rest of `./integration/proxy/grpcproxy/` still passes with the change. I did not run the wider proxy test configuration (`make test-grpcproxy-integration`).

AI disclosure: found with an AI agent (Claude Code) under my direction; I have run the checks above myself and will answer follow-ups myself.
