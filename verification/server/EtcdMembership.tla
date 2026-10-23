--------------------------- MODULE EtcdMembership ---------------------------
\* Server-layer model of etcd cluster membership (P3; see
\* verification/PLAN.md and verification/membership-map.md).
\*
\* Raft is abstracted to a single, totally ordered log of committed conf
\* changes (justified by P2). On top of it, each member has its own view of
\* the membership and runs the code's checks against that view:
\*   - proposal-time guards (StrictReconfigCheck): server.go mayAddMember,
\*     mayPromoteMember, mayRemoveMember; cluster.go IsReadyTo*; util.go;
\*   - raft's one-change-at-a-time rule (pendingConfIndex);
\*   - apply-time validation, with the member's own --max-learners
\*     (cluster.go ValidateConfigurationChange); a rejected entry is a no-op;
\*   - durable state = in-memory state at some earlier applied index
\*     (member write, consistent index and ConfState share a bbolt commit);
\*     a crash reverts to it;
\*   - snapshots copy another member's state;
\*   - a member that applies its own removal stops.
\* Member liveness, "started" (has published its name) and the leader's
\* view of a learner's progress are explicit variables.
EXTENDS Naturals, FiniteSets, Sequences, TLC

CONSTANTS
    Server,                 \* every member id that may ever exist
    InitVoters,             \* initial voting members (all started)
    MaxLearners,            \* [Server -> Nat]: each member's --max-learners
    StrictReconfigCheck,    \* BOOLEAN
    MaxOps,                 \* bound on committed + in-flight conf changes
    MaxFaults,              \* bound on crashes + restarts
    \* Variants (FALSE = current code):
    FixStaleView,           \* proposer must have applied the whole log first
    FixPromoteLiveness,     \* promote guard counts only reachable voters + live learner
    FixGuardAtCommit,       \* leader re-runs the guard on its view when it appends
    FixCAS,                 \* conf change carries the membership its guard saw;
                            \* rejected at apply time if the membership differs
    FixLearnerLimitAtPropose, \* --max-learners checked by the proposer, not at apply
    ConnLag                 \* guards see liveness through a lagging observation

ASSUME InitVoters \subseteq Server /\ InitVoters # {}
ASSUME MaxLearners \in [Server -> Nat]
ASSUME \A b \in {StrictReconfigCheck, FixStaleView, FixPromoteLiveness, FixGuardAtCommit, FixCAS, FixLearnerLimitAtPropose, ConnLag} : b \in BOOLEAN

VARIABLES
    log,        \* Seq of committed entries [kind, id, cas, base]; with cas,
                \* base is the membership the guard checked (FixCAS)
    applied,    \* [Server -> Nat]
    mem,        \* [Server -> View]: in-memory membership view
    dur,        \* [Server -> [view: View, ci: Nat]]: backend (durable)
    alive,      \* [Server -> BOOLEAN]
    started,    \* [Server -> BOOLEAN]: has published its name (IsStarted)
    seen,       \* [Server -> BOOLEAN]: liveness as the guards observe it
    caughtUp,   \* [Server -> BOOLEAN]: leader saw this learner's Match catch up
    props,      \* set of [op, by, up] that passed a guard, not yet committed/dropped;
                \* up = members alive when the guard ran
    unsafe,     \* ghost: a committed change took the cluster from quorum to no quorum
    faults      \* crashes + restarts so far

vars == <<log, applied, mem, dur, alive, started, seen, caughtUp, props, unsafe, faults>>

Kinds == {"addVoter", "addLearner", "promote", "remove"}
Ops == [kind : Kinds, id : Server]
View == [voters : SUBSET Server, learners : SUBSET Server, removed : SUBSET Server]
InitView == [voters |-> InitVoters, learners |-> {}, removed |-> {}]

\* FixCAS: the membership a guard ran against (voters and learners only, as
\* in membership.MembershipDigest).
BaseOf(v) == [voters |-> v.voters, learners |-> v.learners]

q(n) == n \div 2 + 1
Members(v) == v.voters \cup v.learners

\* Liveness as the guards see it (transport ActiveSince, HealthInterval).
Up(x) == IF ConnLag THEN seen[x] ELSE alive[x]

----------------------------------------------------------------------------
\* Apply-time validation (cluster.go ValidateConfigurationChange) on member
\* s's view, with s's own --max-learners.
Valid(op, v, s) ==
    /\ ("cas" \in DOMAIN op /\ op.cas) => op.base = BaseOf(v)
    /\ op.id \notin v.removed
    /\ CASE op.kind = "addVoter"   -> op.id \notin Members(v)
         [] op.kind = "addLearner" -> /\ op.id \notin Members(v)
                                      /\ FixLearnerLimitAtPropose \/ Cardinality(v.learners) + 1 <= MaxLearners[s]
         [] op.kind = "promote"    -> op.id \in v.learners
         [] op.kind = "remove"     -> op.id \in Members(v)

Effect(op, v) ==
    CASE op.kind = "addVoter"   -> [v EXCEPT !.voters = @ \cup {op.id}]
      [] op.kind = "addLearner" -> [v EXCEPT !.learners = @ \cup {op.id}]
      [] op.kind = "promote"    -> [v EXCEPT !.voters = @ \cup {op.id}, !.learners = @ \ {op.id}]
      [] op.kind = "remove"     -> [voters |-> v.voters \ {op.id}, learners |-> v.learners \ {op.id},
                                    removed |-> v.removed \cup {op.id}]

ApplyOp(op, v, s) == IF Valid(op, v, s) THEN Effect(op, v) ELSE v

\* View after replaying the first n log entries from scratch, as member s.
RECURSIVE Replay(_, _)
Replay(n, s) == IF n = 0 THEN InitView ELSE ApplyOp(log[n], Replay(n - 1, s), s)

----------------------------------------------------------------------------
\* Proposal-time guards, evaluated by proposer p on its own view.
NStarted(X) == Cardinality({x \in X : started[x]})
NConn(p, X) == Cardinality({x \in X : x = p \/ Up(x)})

\* server.go mayAddMember: IsReadyToAddVotingMember (voters only) and
\* isConnectedToQuorumAfterAddingNewMemberSince (voters and learners).
GuardAdd(isVoter, p) ==
    LET V == mem[p].voters
        nm == Cardinality(V) + 1
        ns == NStarted(V)
    IN /\ isVoter => ((ns = 1 /\ nm = 2) \/ ns >= q(nm))
       /\ Cardinality(V) = 1 \/ NConn(p, V) >= q(Cardinality(V) + 1)

\* server.go mayRemoveMember.
GuardRemove(x, p) ==
    LET V == mem[p].voters
        rest == V \ {x}
    IN \/ x \in mem[p].learners
       \/ /\ x \in V
          /\ NStarted(rest) >= q(Cardinality(rest))
          /\ \/ x # p /\ ~Up(x)
             \/ NConn(p, V) - 1 >= q(Cardinality(V) - 1)

\* server.go mayPromoteMember (run on the leader): IsReadyToPromoteMember
\* counts the learner as started; isLearnerReady uses the leader's Match.
GuardPromote(x, p) ==
    LET V == mem[p].voters IN
    IF FixPromoteLiveness
    THEN NConn(p, V) + (IF Up(x) THEN 1 ELSE 0) >= q(Cardinality(V) + 1)
    ELSE NStarted(V) + 1 >= q(Cardinality(V) + 1)

Guard(op, p) ==
    CASE op.kind = "addVoter"   -> GuardAdd(TRUE, p)
      [] op.kind = "addLearner" -> GuardAdd(FALSE, p)
      [] op.kind = "promote"    -> GuardPromote(op.id, p)
      [] op.kind = "remove"     -> GuardRemove(op.id, p)

\* Is p the raft leader for practical purposes? An alive voter in its own
\* view whose config has a reachable quorum.
CanLead(l) ==
    /\ alive[l]
    /\ l \in mem[l].voters
    /\ Cardinality({v \in mem[l].voters : alive[v]}) >= q(Cardinality(mem[l].voters))

AvailWith(v, up) == Cardinality(v.voters \cap up) >= q(Cardinality(v.voters))

----------------------------------------------------------------------------
Init ==
    /\ log = <<>>
    /\ applied = [s \in Server |-> 0]
    /\ mem = [s \in Server |-> InitView]
    /\ dur = [s \in Server |-> [view |-> InitView, ci |-> 0]]
    /\ alive = [s \in Server |-> s \in InitVoters]
    /\ started = [s \in Server |-> s \in InitVoters]
    \* With ConnLag, peers start unobserved: the guards need HealthInterval
    \* of connectivity, which a just-started cluster doesn't have yet.
    /\ seen = IF ConnLag THEN [s \in Server |-> FALSE] ELSE alive
    /\ caughtUp = [s \in Server |-> FALSE]
    /\ props = {}
    /\ unsafe = FALSE
    /\ faults = 0

\* A client sends a membership request to member p, which runs the guard.
\* Promote is forwarded to the leader, which waits for its applied index.
Request(op, p) ==
    /\ alive[p]
    /\ p \in mem[p].voters
    /\ Len(log) + Cardinality(props) < MaxOps
    /\ op.kind \in {"addVoter", "addLearner"} => op.id \notin InitVoters
    /\ op.kind = "promote" => /\ applied[p] = Len(log)
                              /\ op.id \in mem[p].learners
                              /\ caughtUp[op.id]          \* isLearnerReady
    /\ FixStaleView => applied[p] = Len(log)
    /\ (FixLearnerLimitAtPropose /\ op.kind = "addLearner") => Cardinality(mem[p].learners) + 1 <= MaxLearners[p]
    /\ StrictReconfigCheck => Guard(op, p)
    /\ props' = props \cup {[op |-> op, by |-> p, up |-> {s \in Server : alive[s]},
                              cas |-> FixCAS /\ StrictReconfigCheck, base |-> BaseOf(mem[p])]}
    /\ UNCHANGED <<log, applied, mem, dur, alive, started, seen, caughtUp, unsafe, faults>>

Entry(pr) == [kind |-> pr.op.kind, id |-> pr.op.id, cas |-> pr.cas, base |-> pr.base]

\* The raft leader accepts the proposal (no other change pending: it has
\* applied the whole log) and it commits under the leader's current config.
Commit(pr, l) ==
    /\ CanLead(l)
    /\ applied[l] = Len(log)
    \* Variant: the leader re-checks the guard on its own (current) view at
    \* append time, where raft's pending rule serializes changes.
    /\ (FixGuardAtCommit /\ StrictReconfigCheck) => Guard(pr.op, l)
    /\ log' = Append(log, Entry(pr))
    /\ props' = props \ {pr}
    \* The guard's contract: judged against liveness when it ran (later
    \* failures are out of its control), the change must not take the
    \* config from a reachable quorum to none. The config here is the one
    \* the change actually applies to, which differs from the proposer's
    \* view if that view was stale.
    \* (With FixGuardAtCommit the check runs now, so judge against now.)
    /\ LET up == IF FixGuardAtCommit THEN {s \in Server : alive[s]} ELSE pr.up
       IN unsafe' = (unsafe \/ (/\ StrictReconfigCheck
                                /\ AvailWith(mem[l], up)
                                /\ ~AvailWith(ApplyOp(Entry(pr), mem[l], l), up)))
    /\ UNCHANGED <<applied, mem, dur, alive, started, seen, caughtUp, faults>>

\* The request times out (or raft dropped it as a second pending change).
Drop(pr) ==
    /\ props' = props \ {pr}
    /\ UNCHANGED <<log, applied, mem, dur, alive, started, seen, caughtUp, unsafe, faults>>

\* Member s applies its next committed entry.
Apply(s) ==
    /\ alive[s]
    /\ applied[s] < Len(log)
    /\ LET op == log[applied[s] + 1]
           v2 == ApplyOp(op, mem[s], s)
       IN /\ mem' = [mem EXCEPT ![s] = v2]
          /\ applied' = [applied EXCEPT ![s] = @ + 1]
          \* A member that applies its own removal stops.
          /\ alive' = IF s \in v2.removed THEN [alive EXCEPT ![s] = FALSE] ELSE alive
    /\ UNCHANGED <<log, dur, started, seen, caughtUp, props, unsafe, faults>>

\* The backend commits: durable state catches up with memory.
Persist(s) ==
    /\ dur[s] # [view |-> mem[s], ci |-> applied[s]]
    /\ dur' = [dur EXCEPT ![s] = [view |-> mem[s], ci |-> applied[s]]]
    /\ UNCHANGED <<log, applied, mem, alive, started, seen, caughtUp, props, unsafe, faults>>

\* A lagging follower installs the leader's snapshot (bbolt file).
Snapshot(s, l) ==
    /\ alive[s] /\ alive[l]
    /\ applied[l] > applied[s]
    /\ mem' = [mem EXCEPT ![s] = mem[l]]
    /\ applied' = [applied EXCEPT ![s] = applied[l]]
    /\ dur' = [dur EXCEPT ![s] = [view |-> mem[l], ci |-> applied[l]]]
    /\ UNCHANGED <<log, alive, started, seen, caughtUp, props, unsafe, faults>>

Crash(s) ==
    /\ alive[s]
    /\ faults < MaxFaults
    /\ alive' = [alive EXCEPT ![s] = FALSE]
    /\ mem' = [mem EXCEPT ![s] = dur[s].view]
    /\ applied' = [applied EXCEPT ![s] = dur[s].ci]
    /\ faults' = faults + 1
    /\ UNCHANGED <<log, dur, started, seen, caughtUp, props, unsafe>>

\* (Re)start s: an existing member restarting, or a newly added member
\* starting for the first time. A removed member does not come back.
Start(s) ==
    /\ ~alive[s]
    /\ s \notin mem[s].removed
    /\ \/ started[s] /\ faults < MaxFaults /\ faults' = faults + 1
       \/ ~started[s] /\ \E l \in Server : alive[l] /\ s \in Members(mem[l])
          /\ UNCHANGED faults
    /\ alive' = [alive EXCEPT ![s] = TRUE]
    /\ started' = [started EXCEPT ![s] = TRUE]
    /\ UNCHANGED <<log, applied, mem, dur, seen, caughtUp, props, unsafe>>

\* The leader sees a running learner's Match catch up. It is not reset when
\* the learner later stops (H2).
CatchUp(x) ==
    /\ alive[x]
    /\ applied[x] = Len(log)
    /\ ~caughtUp[x]
    /\ caughtUp' = [caughtUp EXCEPT ![x] = TRUE]
    /\ UNCHANGED <<log, applied, mem, dur, alive, started, seen, props, unsafe, faults>>

\* Transport liveness observation catches up (only with ConnLag).
Observe(x) ==
    /\ ConnLag
    /\ seen[x] # alive[x]
    /\ seen' = [seen EXCEPT ![x] = alive[x]]
    /\ UNCHANGED <<log, applied, mem, dur, alive, started, caughtUp, props, unsafe, faults>>

Next ==
    \/ \E op \in Ops, p \in Server : Request(op, p)
    \/ \E pr \in props, l \in Server : Commit(pr, l)
    \/ \E pr \in props : Drop(pr)
    \/ \E s \in Server : Apply(s) \/ Persist(s) \/ Crash(s) \/ Start(s) \/ CatchUp(s) \/ Observe(s)
    \/ \E s, l \in Server : Snapshot(s, l)

Spec == Init /\ [][Next]_vars

----------------------------------------------------------------------------
\* Invariants (numbering from membership-map.md §4).

TypeOK ==
    /\ \A s \in Server : mem[s] \in View /\ dur[s].view \in View
    /\ \A i \in 1..Len(log) : [kind |-> log[i].kind, id |-> log[i].id] \in Ops

\* I10: with StrictReconfigCheck, no committed change takes the cluster
\* from a reachable quorum to none, judged against liveness when its guard
\* ran (see Commit).
NoUnsafeChangeInv == ~unsafe

\* I1: members that applied the same prefix agree on membership.
AgreementInv ==
    \A s, t \in Server : applied[s] = applied[t] => mem[s] = mem[t]

\* Two voter sets have disjoint majorities iff we can pick a majority of
\* each without overlap: fill each from its exclusive members first.
DisjointMajorities(V1, V2) ==
    LET need1 == q(Cardinality(V1)) - Cardinality(V1 \ V2)
        need2 == q(Cardinality(V2)) - Cardinality(V2 \ V1)
        pos(n) == IF n > 0 THEN n ELSE 0
    IN V1 # {} /\ V2 # {} /\ pos(need1) + pos(need2) <= Cardinality(V1 \cap V2)

\* Members at the same applied index must not hold configs with disjoint
\* majorities (that would allow two leaders in one term).
NoSplitBrainConfigInv ==
    \A s, t \in Server :
        applied[s] = applied[t] => ~DisjointMajorities(mem[s].voters, mem[t].voters)

\* I5: removed ids never come back.
RemovedStayRemovedInv ==
    \A s \in Server : mem[s].removed \cap Members(mem[s]) = {}

\* Voters and learners are disjoint.
DisjointRolesInv ==
    \A s \in Server : mem[s].voters \cap mem[s].learners = {}

\* I7: learner count within each member's own limit.
LearnerBoundInv ==
    \A s \in Server : Cardinality(mem[s].learners) <= MaxLearners[s]

\* I3: durable state equals replaying the log up to the consistent index
\* (holds without snapshots; a snapshot imports another member's view).
DurableMatchesReplayInv ==
    \A s \in Server : dur[s].view = Replay(dur[s].ci, s)
=============================================================================
