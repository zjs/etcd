------------------------- MODULE MCEtcdMembership ---------------------------
\* Model-checking wrapper: names for members and --max-learners settings.
EXTENDS EtcdMembership
CONSTANTS a, b, c, d, x, y, z
MLUniform == [s \in Server |-> 1]
\* Member a runs with --max-learners=2, everyone else with 1 (H1).
MLMixed == [s \in Server |-> IF s = a THEN 2 ELSE 1]
\* Member a runs with --max-learners=3, everyone else with 1.
MLMixed3 == [s \in Server |-> IF s = a THEN 3 ELSE 1]

\* H1b: only learner adds and promotions; no persist/snapshot steps (they
\* don't affect the split-brain question and blow up the state space).
H1bConstraint ==
    /\ \A i \in 1..Len(log) : log[i].kind \in {"addLearner", "promote"}
    /\ \A pr \in props : pr.op.kind \in {"addLearner", "promote"}
    /\ \A s \in Server : dur[s].ci = 0
=============================================================================
