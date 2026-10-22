--------------------------- MODULE MCH1bWitness -----------------------------
\* FORK (P3): hand-written behavior for H1b, checked step by step by TLC.
\* Members a, b, c; a runs with --max-learners=3, everyone else with 1.
\* a adds learners x, y, z (b and c reject y and z at apply time), then
\* promotes y and z. a ends with voters {a,b,c,y,z}, b and c with {a,b,c}:
\* their majorities can be disjoint ({a,y,z} vs {b,c}), which allows two
\* leaders in one term. If a step is not enabled, TLC reports a deadlock.
EXTENDS MCEtcdMembership

VARIABLE step

Script ==
    CASE step = 0  -> Request([kind |-> "addLearner", id |-> x], a)   \* a allows 3 learners
      [] step = 1  -> \E pr \in props : pr.op = [kind |-> "addLearner", id |-> x] /\ Commit(pr, a)
      [] step = 2  -> Apply(a)
      [] step = 3  -> Apply(b)
      [] step = 4  -> Apply(c)
      [] step = 5  -> Request([kind |-> "addLearner", id |-> y], a)   \* a allows 3 learners
      [] step = 6  -> \E pr \in props : pr.op = [kind |-> "addLearner", id |-> y] /\ Commit(pr, a)
      [] step = 7  -> Apply(a)
      [] step = 8  -> Apply(b)   \* b, c reject: over their limit of 1
      [] step = 9  -> Apply(c)
      [] step = 10 -> Request([kind |-> "addLearner", id |-> z], a)   \* a allows 3 learners
      [] step = 11 -> \E pr \in props : pr.op = [kind |-> "addLearner", id |-> z] /\ Commit(pr, a)
      [] step = 12 -> Apply(a)
      [] step = 13 -> Apply(b)   \* b, c reject
      [] step = 14 -> Apply(c)
      [] step = 15 -> Start(y)   \* y joins; it replays the log with its own limit
      [] step = 16 -> Apply(y)
      [] step = 17 -> Apply(y)
      [] step = 18 -> Apply(y)
      [] step = 19 -> CatchUp(y)   \* leader a sees y's Match catch up
      [] step = 20 -> Request([kind |-> "promote", id |-> y], a)
      [] step = 21 -> \E pr \in props : pr.op = [kind |-> "promote", id |-> y] /\ Commit(pr, a)
      [] step = 22 -> Apply(a)   \* a: voters {a,b,c,y}
      [] step = 23 -> Apply(b)   \* b: y not a member -> rejected
      [] step = 24 -> Apply(c)
      [] step = 25 -> Start(z)
      [] step = 26 -> Apply(z)
      [] step = 27 -> Apply(z)
      [] step = 28 -> Apply(z)
      [] step = 29 -> Apply(z)
      [] step = 30 -> CatchUp(z)
      [] step = 31 -> Request([kind |-> "promote", id |-> z], a)
      [] step = 32 -> \E pr \in props : pr.op = [kind |-> "promote", id |-> z] /\ Commit(pr, a)
      [] step = 33 -> Apply(a)   \* a: voters {a,b,c,y,z}
      [] step = 34 -> Apply(b)   \* b: voters {a,b,c}; majorities {a,y,z} and {b,c} are disjoint

WitnessSpec == (Init /\ step = 0) /\ [][Script /\ step' = step + 1]_<<vars, step>>
=============================================================================
