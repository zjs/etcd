# Draft issue (etcd-io/raft): `tla/etcdraft.tla` differs from the code in membership handling; can report two leaders in one term

While using `tla/` (v3.7.0) to check membership changes, we found
differences from the implementation. Some make the spec more permissive
than the code (false alarms), some less (missed behaviors), and the trace
spec can't validate restarts.

**Less permissive (missed behaviors):**
1. `AddNewServer` keeps a promoted learner in `learners`; `makeVoter`
   removes it.
2. `RequestVote` also asks learners; `campaign` asks only
   `trk.Voters`.
3. `BecomeLeader` requires `votesGranted ⊆ config`, so one vote from a
   non-voter blocks the election; `TallyVotes` ignores non-voters.

**More permissive:**

4. `ApplySimpleConfChange` clears `pendingConfChangeIndex` when
   `pending >= k`. Re-applying an older committed config is always
   enabled, so a leader can clear it at will and stack two uncommitted
   config entries. The code refuses while `pendingConfIndex > applied`,
   and `becomeLeader` sets `pendingConfIndex = lastIndex`.
5. `Timeout` doesn't model `hup`'s refusal to campaign with committed but
   unapplied conf changes.
6. A follower appends in one step and updates its commit index and replies
   in a later one; `handleAppendEntries` does all three at once.

With 5 and 6 as in the spec, a 71-step behavior elects two leaders in one
term:
1. Initial config {1,2,3}. Add 4, then remove 3.
2. Node 3 has both entries but doesn't know the first committed, and
   campaigns on the old config.

TLC confirms the behavior. It disappears only with both 5 and 6 modeled as
the code does. So it's a spec issue, but it also documents which code
rules this safety depends on.

**Trace validation:**

7. `newRaft` logs `InitState` before `loadState`, so a restart's
   `InitState` shows term 0 / commit 0 / empty config. `RestartIfLogged`
   validates against it and can't match a real restart. Checking the
   restored state at the following `BecomeFollower` works.

**Model checking config:**

8. `MCetcdraft.cfg` uses `SYMMETRY Permutations(Server)`, but `InitServer`
   and the bootstrap log's order make the spec asymmetric. The reduction
   may skip states.

A patch with 1–7 (5 and 6 behind constants so the current behavior stays
available) is ready. With it, the upstream example trace and traces from
etcd integration runs validate.

**Patch:** `verification/raft/upstream-patches/0001-*.patch` in our fork
(applies with `git am` to `main` at 1931ff5). The new constants are TRUE in
the shipped configs. With them, the upstream `example.ndjson` and 5 traces
from etcd integration runs (including a restart and leader removal)
validate, and a 15-minute
simulation of `MCetcdraft.cfg` (about 106k behaviors) finds no violation.
