# Source of these files

Copied from `go.etcd.io/raft/v3@v3.7.0`, directory `tla/` (the
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

## Changes in this fork (P2)

The hashes above are of the upstream originals; `git log -p` on this
directory shows every change. Each change in the spec is marked `FORK` in
a comment.

| Id | File | Change | Why |
|---|---|---|---|
| F1 | `etcdraft.tla` `AddNewServer` | Promoting a learner removes it from `learners` | Code: `confchange.go` `makeVoter` deletes it from `Learners`. Upstream left it in both sets |
| F2 | `etcdraft.tla` `RequestVote` | Ask only voters for votes | Code: `raft.go` `campaign` iterates `trk.Voters`. Upstream also asked learners |
| F3 | `etcdraft.tla` `BecomeLeader` | Count only voters' grants | Code: `tracker.TallyVotes` skips learners. Upstream needed *every* grant to come from a voter, so one stray grant blocked an election (an under-approximation) |
| F4 | `etcdraft.tla` `Timeout` | New constant `CampaignRequiresAppliedConfig`: when TRUE, a node with committed but unapplied config entries can't campaign | Code: `raft.go` `hup` → `hasUnappliedConfChanges`. Set FALSE in all upstream configs to keep upstream behavior |
| F5 | `etcdraft.tla` `BecomeLeader`, `CanProposeConf`, `ApplySimpleConfChange` | New constant `LeaderPendingAtElection`: when TRUE, a new leader sets the pending marker to its last index, and a config change is allowed only if marker ≤ commit and no committed config is unapplied. Under F5 the marker is never cleared by `ApplySimpleConfChange` | Code: `raft.go` `becomeLeader` sets `pendingConfIndex = lastIndex`; `stepLeader` refuses while `pendingConfIndex > applied`. Upstream clears the marker when `marker >= k` (reversed); re-applying an old committed config is always enabled, so the one-change-at-a-time rule isn't enforced |
| F6 | `etcdraft.tla` `NoConflictAppendEntriesRequest` | New constant `AtomicAppendCommit`: when TRUE, a follower appends, learns the commit index and replies (match = last new index) in one step | Code: `raft.go` `handleAppendEntries` → `raftLog.maybeAppend` → `commitTo(min(m.Commit, lastnewi))`, then `MsgAppResp{Index: lastnewi}`. Upstream commits and replies in a later step. A first version (commit only) was caught by a real trace in P4 |
| T1 | `Traceetcdraft.tla` `RestartIfLogged`, `RestartBecomeFollowerIfLogged` | A restart's `InitState` line is not validated; the restored state is checked at the next `BecomeFollower` | raft logs `InitState` before `loadState` (raft.go `newRaft`), so on restart it shows zeros. Upstream could not validate any real restart |
| — | `etcdraft.tla` | New invariants `LearnersVotersDisjointInv`, `ConfigEntryDisjointInv`, `KnowsPrevConfigCommittedInv`, `AtMostOneUncommittedConfigInv` | P2 membership properties |
| — | `*.cfg` | `CampaignRequiresAppliedConfig`, `AtomicAppendCommit`, `LeaderPendingAtElection` set to FALSE in the upstream configs | Required by F4–F6 |

Known spec–code differences not yet changed:

- `BecomeLeader` doesn't append an empty entry; the code does
  (`raft.go` `becomeLeader`). A new leader's commit then waits for its
  next entry. This is more permissive about when config entries can be
  first in a term.
- No applied index: "applied" is approximated as described under F4/F5.
- `MCetcdraft.cfg` uses `SYMMETRY Permutations(Server)`, but `InitServer`
  and the order of the bootstrap log make the spec asymmetric. The
  reduction may be unsound. `MCmembership.cfg` doesn't use it.

Files added in this fork (not from upstream):

- `SOURCE.md`: this file.
- `MCetcdraft-smoke.cfg`: `MCetcdraft.cfg` with smaller bounds for quick
  checks (2 initial members + 1 spare, 1 reconfiguration, 1 client request,
  terms ≤ 3).
- `MCmembership.tla`: P2 experiments. A reliable-network next-state
  relation, an in-flight message cap, and directed-scenario wrappers.
- `MCmembership.cfg`: code-faithful (F4–F6 on), reliable network, 4
  servers, 2 reconfigurations, all invariants. For `-simulate`.
- `MCmembership-full.cfg`: the same with crashes, drops and duplicates.
- `MCmembership-upstream.cfg`: F4–F6 off, full network.
- `MCscenario.cfg`: directed scenario (who may act is fixed; interleavings
  are free). Too large for exhaustive search at the depth needed.
- `MCwitness.tla`, `MCwitness.cfg`: a 71-step hand-written behavior, checked
  by TLC, that elects two leaders in one term when F4 or F6 is off.
- `Traceetcdraft-faithful.cfg`: trace validation with F4–F6 on (P4).
