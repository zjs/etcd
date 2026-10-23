# Draft issue (etcd-io/etcd): membership guards run on the receiving member's view, so back-to-back changes can lose quorum despite StrictReconfigCheck

**What happened?**

`mayAddMember` and `mayRemoveMember` run on whichever member receives the
request, against that member's local membership. They don't wait for it to
apply pending entries. Raft allows only one conf change in flight, but it
checks that at the leader, later, and it doesn't re-run the quorum checks.
So a change can be judged against a config it isn't applied to:

- **Stale view.** The member receiving the second change hasn't applied the
  first yet.
- **Concurrent requests.** Both changes pass their checks before either
  commits; raft then applies them in sequence.

Concrete case, 4 voters with one down:

1. Add voter n0 (not started yet) through the leader. Accepted: 5 voters,
   3 running, quorum 3.
2. The same add for n1, sent to the leader, is refused ("unhealthy
   cluster").
3. The same add for n1, sent to a follower that hasn't applied step 1 yet,
   is accepted: the follower still sees 4 voters.
4. Result: 6 voters, 3 running, quorum 4. Writes time out.

A remove-based variant needs only the remove guard:
1. 4 voters, one down. Remove B through the leader.
2. Remove S through S itself, before S has applied B's removal. S still
   counts B as connected, so it accepts.
3. Result: 2 voters, 1 running.

Enumerating the guard formulas for 1–5 voters, every case where only the
stale view accepts a quorum-losing change starts from 2 or 4 voters.

**What did you expect to happen?**

With `--strict-reconfig-check`, a change that the leader would refuse is
refused, whichever member receives it.

**How can we reproduce it?**

The window is the apply lag on a follower, which is short but routine.
Clients with several endpoints spread consecutive member commands across
members. Our integration tests widen the window deterministically by
holding the follower's backend read lock, which blocks its apply loop
before it updates its membership view. Both variants reproduce 3/3.

**Anything else we need to know?**

- #21641 (v3.6.11, v3.5.30) relaxed the add check from "connected to all
  voters" to "connected to a quorum after the add". The add-based case
  above needs one voter down, so it applies only from those versions on.
  The remove-based case applies to earlier versions too (identical remove
  guard in v3.5.29 and v3.6.10).
- Checking on an up-to-date view alone is not enough: two requests can
  both pass before either commits. Directions that close it in a TLA+
  model of the server's membership logic (no violation within bounds):
  1. Re-run the guard on the leader when it appends the entry, where raft's
     pending-change rule already serializes changes.
  2. Or carry the config index the guard checked and refuse at append time
     if the config changed.
- Connectivity is still observed with a lag (`HealthInterval`), so a crash
  the transport hasn't noticed yet remains a limitation either way.

**Etcd version:** main at bf9cadf; v3.5.29, v3.6.10 (remove guard, code
inspection).
