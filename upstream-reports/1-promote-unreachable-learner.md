# Issue for etcd-io/etcd

**Title:** StrictReconfigCheck allows promoting an unreachable learner, which can lose quorum

### Bug report criteria

- [x] This bug report is not security related.
- [x] This is not a support request or question.
- [x] You have read the etcd bug reporting guidelines.
- [x] Existing open issues along with etcd FAQ have been checked and this is not a duplicate.

### What happened?

With `--strict-reconfig-check` (the default), member add and remove are refused when the result would leave too few *reachable* voters. Promote has no such check:

- `isLearnerReady` reads the leader's `Match` for the learner, which keeps its last value after the learner stops.
- `IsReadyToPromoteMember` counts voters that have *ever* started, and counts the learner as started.

So this sequence is accepted:

1. A 3-voter cluster has a learner that has caught up.
2. One voter goes down, and the learner stops.
3. An operator promotes the learner.

The promotion commits under the old configuration (2 of 3). The new configuration has 4 voters and needs 3, but only 2 are running. The leader steps down and writes fail until the learner or the down voter returns. If neither can return, recovery needs `--force-new-cluster` or a snapshot restore, because member remove itself needs quorum.

This is an availability loss only; there is no data or safety impact. It needs a double fault plus an operator action.

### What did you expect to happen?

The promotion is refused, as an add or remove that leaves the same number of reachable voters would be.

### How can we reproduce it (as minimally and precisely as possible)?

[`hack/repro/B-promote-unreachable-learner.sh`](https://github.com/zjs/etcd/blob/report/promote-unreachable-learner/hack/repro/B-promote-unreachable-learner.sh) (bash, stock `etcd` and `etcdctl`, about 20 seconds):

```
$ ETCD_BIN_DIR=./bin hack/repro/B-promote-unreachable-learner.sh
--- stop voter m1 and the learner
--- write with 2 of 3 voters: ok
--- promote the stopped learner c1239b2c1e97787c
Member c1239b2c1e97787c promoted in cluster f2cb1557076fcb4d
--- promote accepted
RESULT: write failed after the promote; quorum lost (bug reproduced)
Leader log:
"msg":"9e737febb6b99eee stepped down to follower since quorum is not active"
```

### Anything else we need to know?

- **History.** The promote guard has been based on "ever started" since learners were added in v3.4.0. The code is the same on release-3.4 to release-3.7 and main.
- **Related, smaller.** A promote sent to a follower is forwarded to the leader. If the leader refuses with `ErrNotEnoughStartedMembers`, the follower doesn't recognise the error and retries until the request times out.
- **Candidate fix.** Branch [`zjs/etcd:report/promote-unreachable-learner`](https://github.com/zjs/etcd/tree/report/promote-unreachable-learner) (two commits on main at d622ec5). With strict reconfig check, it requires the voters connected for `HealthInterval`, plus the learner if connected now, to be a quorum of the new voting membership. It also returns the leader's refusal through a forwarding follower. Open questions I'd like your view on before opening a PR:
  - The learner is only required to be connected *now*, not for `HealthInterval`. Requiring the interval broke `TestRuntimeReconfigGrowClusterSize`, because learners are commonly promoted right after catching up.
  - The check adds another consumer of `transport.ActiveSince`, so #22480 (peer status latching inactive) would cause false refusals here as it does for add and remove.
- **AI disclosure.** [see README.md, "Disclosure"]

### Etcd version (please run commands below)

```
$ etcd --version
etcd Version: 3.8.0-alpha.0
Git SHA: d622ec5
```

### Etcd configuration (command line flags or environment variables)

Defaults (`--strict-reconfig-check=true`); three members plus one learner on localhost. See the script.

### Relevant log output

See above.
