------------------------------ MODULE leasecp ------------------------------
(***************************************************************************)
(* One etcd lease under lease checkpointing (server/lease/lessor.go and   *)
(* the checkpointer in server/etcdserver/server.go).                      *)
(*                                                                         *)
(* - The leader keeps the lease expiry in memory (exp).                    *)
(* - rem is the replicated remainingTTL: set by applied checkpoint         *)
(*   entries, used by the next leader's Promote.                           *)
(* - Scheduled checkpoints propose exp-now; Renew proposes rem := 0 first  *)
(*   when rem > 0, then refreshes exp and acks the client.                 *)
(* - Proposals may commit, or be dropped (leader transfer, overload).      *)
(*                                                                         *)
(* Safety: the lease is never revoked before the TTL promised by the last *)
(* acknowledged keepalive.                                                 *)
(***************************************************************************)
EXTENDS Naturals, Sequences, FiniteSets

CONSTANTS TTL, ET, MaxTime, MaxProps, MaxEpoch,
          Mode   \* "bug" (as coded), "fixerr", "fixall"

\* fixerr: Renew acks only if its clear checkpoint applied while still leader.
\* fixall: fixerr, plus a per-lease lock so a scheduled checkpoint is never
\*         computed or in flight while a Renew is between its clear decision
\*         and its refresh.

None == [ep |-> 0, cid |-> 0]

VARIABLES now, epoch, exp, rem, pend, applied, dropped, renew, ack, revoked, nextId

vars == <<now, epoch, exp, rem, pend, applied, dropped, renew, ack, revoked, nextId>>

Init == /\ now = 0 /\ epoch = 1
        /\ exp = TTL          \* granted at time 0
        /\ rem = 0
        /\ pend = <<>>
        /\ applied = {} /\ dropped = {}
        /\ renew = None
        /\ ack = 0            \* grant counts as the first promise
        /\ revoked = FALSE
        /\ nextId = 1

Propose(kind, val) ==
  /\ nextId <= MaxProps
  /\ pend' = Append(pend, [id |-> nextId, val |-> val, kind |-> kind])
  /\ nextId' = nextId + 1

Tick == /\ now < MaxTime /\ ~revoked
        /\ now' = now + 1
        /\ UNCHANGED <<epoch, exp, rem, pend, applied, dropped, renew, ack, revoked, nextId>>

\* lessor.findDueScheduledCheckpoints: remaining = expiry - now, skipped when >= ttl.
SchedCheckpoint ==
  /\ ~revoked /\ exp > now /\ exp - now < TTL
  /\ Mode = "fixall" => /\ renew = None
                        /\ \A i \in 1..Len(pend) : pend[i].kind # "sched"
  /\ Propose("sched", exp - now)
  /\ UNCHANGED <<now, epoch, exp, rem, applied, dropped, renew, ack, revoked>>

\* lessor.Renew up to the checkpointer call.
RenewBegin ==
  /\ ~revoked /\ renew = None /\ exp > now
  \* fixall: a per-lease checkpoint lock is held by Renew from its decision to
  \* clear until it refreshes, and by a scheduled checkpoint from computing
  \* its value until it is applied or fails.
  /\ Mode = "fixall" => \A i \in 1..Len(pend) : pend[i].kind # "sched"
  /\ IF rem > 0
       THEN /\ Propose("clear", 0)
            /\ renew' = [ep |-> epoch, cid |-> nextId]
            /\ UNCHANGED <<exp>>
            /\ UNCHANGED <<ack>>
       ELSE /\ exp' = now + TTL /\ ack' = now
            /\ UNCHANGED <<pend, nextId, renew>>
  /\ UNCHANGED <<now, epoch, rem, applied, dropped, revoked>>

\* Checkpointer returns; Renew refreshes and returns the TTL to the client.
RenewEnd ==
  /\ renew # None
  /\ renew.cid \in applied \cup dropped
  /\ LET ok == CASE revoked -> FALSE                     \* ErrLeaseNotFound
                  [] Mode = "bug" -> TRUE                 \* checkpointer error ignored
                  [] OTHER -> renew.cid \in applied /\ renew.ep = epoch
     IN /\ exp' = IF ok /\ renew.ep = epoch THEN now + TTL ELSE exp
        /\ ack' = IF ok THEN now ELSE ack
  /\ renew' = None
  /\ UNCHANGED <<now, epoch, rem, pend, applied, dropped, revoked, nextId>>

\* Raft commits a pending proposal; every member applies lessor.Checkpoint.
\* Unordered modes: proposals from different goroutines may enter raft in
\* either order relative to when their value was computed.
Commit ==
  \E i \in 1..Len(pend) :
    /\ rem' = pend[i].val
    /\ applied' = applied \cup {pend[i].id}
    /\ pend' = SubSeq(pend, 1, i-1) \o SubSeq(pend, i+1, Len(pend))
    /\ UNCHANGED <<now, epoch, exp, dropped, renew, ack, revoked, nextId>>

Drop ==
  \E i \in 1..Len(pend) :
    /\ dropped' = dropped \cup {pend[i].id}
    /\ pend' = SubSeq(pend, 1, i-1) \o SubSeq(pend, i+1, Len(pend))
    /\ UNCHANGED <<now, epoch, exp, rem, applied, renew, ack, revoked, nextId>>

\* New leader applies all earlier entries, then Promote(ElectionTimeout).
LeaderChange ==
  /\ ~revoked /\ pend = <<>> /\ epoch < MaxEpoch
  /\ epoch' = epoch + 1
  /\ exp' = now + (IF rem > 0 THEN rem ELSE TTL) + ET
  /\ UNCHANGED <<now, rem, pend, applied, dropped, renew, ack, revoked, nextId>>

Revoke ==
  /\ ~revoked /\ exp <= now
  /\ revoked' = TRUE
  /\ UNCHANGED <<now, epoch, exp, rem, pend, applied, dropped, renew, ack, nextId>>

Next == Tick \/ SchedCheckpoint \/ RenewBegin \/ RenewEnd \/ Commit \/ Drop
        \/ LeaderChange \/ Revoke

Spec == Init /\ [][Next]_vars

NoPrematureExpiry == revoked => now >= ack + TTL
=============================================================================
