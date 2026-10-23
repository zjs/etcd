------------------------- MODULE TraceEtcdMembership -------------------------
\* Trace validation of server-layer membership events (P4b) against
\* EtcdMembership.tla. Events come from server/etcdserver/membership_trace_tla.go
\* (build tag with_tla, env ETCD_TLA_MEMBERSHIP_TRACE_FILE).
\*
\* Each logged line must be matched by a model step:
\*   Start   initial member: already running, view and position must match;
\*           new member: model Start (its in-memory view at start is
\*           bootstrap residue and is not checked); restart: model Start
\*           after a Crash, view and position must match.
\*   Stop    model Crash (a no-op if the model already stopped the member,
\*           e.g. after it applied its own removal).
\*   Request the model's guard must let the request through.
\*   Reject  the model must refuse the same request in the same state.
\*   Apply   the model applies its next entry, which must be the logged op,
\*           and the resulting view must equal the logged view.
\* Between lines, TLC may take any number of unlogged steps: Commit, Drop,
\* Persist, Observe (liveness as the guards see it) and CatchUp.
\*
\* Success = every line matched = the invariant TraceNotDone is violated.
\* On failure TLC finishes without error; POSTCONDITION prints the furthest
\* line matched.
EXTENDS EtcdMembership, Json, IOUtils

JsonFile == IF "JSON" \in DOMAIN IOEnv THEN IOEnv.JSON ELSE "membership.ndjson"
TraceLog == TLCEval(SelectSeq(ndJsonDeserialize(JsonFile),
                              LAMBDA x : "tag" \in DOMAIN x /\ x.tag = "trace"))
Ev(k) == TraceLog[k].event

ToSet(s) == {s[i] : i \in DOMAIN s}

TraceServer ==
    {Ev(k).nid : k \in 1..Len(TraceLog)}
    \cup {Ev(k).id : k \in {j \in 1..Len(TraceLog) : "id" \in DOMAIN Ev(j)}}

StartLines == {k \in 1..Len(TraceLog) : Ev(k).name = "Start"}
FirstStart == CHOOSE k \in StartLines : \A j \in StartLines : k <= j
TraceInitVoters == ToSet(Ev(FirstStart).voters)

\* A member's --max-learners is a constant in the model; take the value from
\* its last Start (a trace that changes it between restarts and depends on
\* the old value can't be matched).
TraceMaxLearners ==
    [s \in TraceServer |->
        IF \E k \in StartLines : Ev(k).nid = s
        THEN Ev(CHOOSE k \in StartLines : Ev(k).nid = s /\ \A j \in StartLines : Ev(j).nid = s => j <= k).maxLearners
        ELSE 1]

OpOf(e) == [kind |-> e.kind, id |-> e.id]
ViewOf(e) == [voters |-> ToSet(e.voters), learners |-> ToSet(e.learners), removed |-> ToSet(e.removed)]

VARIABLE l
tvars == <<vars, l>>

-----------------------------------------------------------------------------
StartLine(e) ==
    LET s == e.nid IN
    \/ /\ alive[s] /\ s \in InitVoters /\ applied[s] = 0     \* initial member
       /\ mem[s] = ViewOf(e) /\ e.pos = 0
       /\ UNCHANGED vars
    \/ /\ ~started[s]                                         \* new member
       /\ Start(s)
    \/ /\ started[s] /\ ~alive[s]                             \* restart
       /\ mem[s] = ViewOf(e) /\ applied[s] = e.pos
       /\ Start(s)

StopLine(e) ==
    IF alive[e.nid] THEN Crash(e.nid) ELSE UNCHANGED vars

RequestLine(e) == Request(OpOf(e), e.nid)

RejectLine(e) ==
    /\ ~ENABLED Request(OpOf(e), e.nid)
    /\ UNCHANGED vars

ApplyLine(e) ==
    /\ e.pos <= Len(log)
    /\ log[e.pos] = OpOf(e)
    /\ applied[e.nid] + 1 = e.pos
    /\ Apply(e.nid)
    /\ mem'[e.nid] = ViewOf(e)

LineStep ==
    LET e == Ev(l) IN
    CASE e.name = "Start"   -> StartLine(e)
      [] e.name = "Stop"    -> StopLine(e)
      [] e.name = "Request" -> RequestLine(e)
      [] e.name = "Reject"  -> RejectLine(e)
      [] e.name = "Apply"   -> ApplyLine(e)
      [] OTHER              -> FALSE

HiddenStep ==
    \/ \E pr \in props, ld \in Server : Commit(pr, ld)
    \/ \E pr \in props : Drop(pr)
    \/ \E s \in Server : Persist(s) \/ Observe(s) \/ CatchUp(s)

TraceInit ==
    /\ Init
    /\ l = 1
    /\ TLCSet(1, 0)

TraceNext ==
    \/ /\ l <= Len(TraceLog)
       /\ LineStep
       /\ l' = l + 1
       /\ TLCSet(1, IF l > TLCGet(1) THEN l ELSE TLCGet(1))
    \/ /\ HiddenStep
       /\ UNCHANGED l

TraceSpec == TraceInit /\ [][TraceNext]_tvars

TraceNotDone == l <= Len(TraceLog)

ReportFurthest == PrintT(<<"furthest trace line matched", TLCGet(1), "of", Len(TraceLog)>>)
=============================================================================
