---------------------------- MODULE MCmembership ----------------------------
\* FORK: P2 experiments on membership changes (verification/PLAN.md).
\* Same model as MCetcdraft, plus a reliable-network next-state relation
\* (no crashes, drops or duplicates) and a cap on in-flight messages, so
\* exhaustive search finishes at small bounds.
EXTENDS MCetcdraft

CONSTANT MaxInflight
ASSUME MaxInflight \in Nat

\* Server names, so the directed scenario can refer to them.
CONSTANTS s1, s2, s3, s4

NextReliableDynamic ==
    \/ NextAsync
    \/ \E i, j \in Server : AddNewServer(i, j)
    \/ \E i, j \in Server : AddLearner(i, j)
    \/ \E i, j \in Server : DeleteServer(i, j)
    \/ \E i \in Server : ApplySimpleConfChange(i)

mc_reliableSpec == Init /\ [][NextReliableDynamic]_vars

InflightConstraint ==
    BagCardinality(messages) + BagCardinality(pendingMessages) <= MaxInflight

\* Directed scenario (MCscenario.cfg): narrows WHO acts, not HOW messages
\* interleave, so any violation found is a behavior of the full spec.
\* Servers 1..4; initial config {1,2,3}.
\*   - Only server 1 runs the first election (term 1 -> 2).
\*   - Server 1 adds 4 (C1 = {1,2,3,4}), then removes 3 (C2 = {1,2,4}).
\*   - Only servers 2 and 3 may start the next election (term 2 -> 3).
\* Question: can 3 (still on C0 = {1,2,3}) and 2 (on C2) both win term 3?
\* C0 and C2 have disjoint quorums ({1,3} and {2,4}).
ScTimeout(i) ==
    /\ MCTimeout(i)
    /\ IF currentTerm[i] <= 1 THEN i = s1 ELSE i \in {s2, s3}

ScAddNewServer(i, j) == /\ i = s1 /\ j = s4 /\ reconfigCount = 0 /\ MCAddNewServer(i, j)
ScDeleteServer(i, j) == /\ i = s1 /\ j = s3 /\ reconfigCount = 1 /\ MCDeleteServer(i, j)
ScAddLearner(i, j)   == FALSE
=============================================================================
