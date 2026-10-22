----------------------------- MODULE MCwitness ------------------------------
\* FORK: a hand-written behavior of the spec, checked step by step by TLC.
\* Question: with config changes taking effect when APPLIED (etcd raft), can
\* two leaders be elected in one term when a node campaigns on a config two
\* changes old?  Servers s1..s4, initial config C0 = {s1,s2,s3}.
\*   A. s1 wins term 2 with s2's vote.
\*   B. s1 adds s4 (C1 = {s1..s4}); commits with s2; applies.
\*   C. s1 removes s3 (C2 = {s1,s2,s4}); sends to s2, s3, s4. s3 appends but
\*      has not yet processed the commit index (the spec splits append and
\*      commit-update into two steps). C2 commits with s1,s2,s4; s2 learns
\*      the commit from a heartbeat and applies C2.
\*   D. Term 3: s3 (still on C0) wins with {s3,s1}; s2 (on C2) wins with
\*      {s2,s4}. C0 and C2 have disjoint quorums.
\* If a step is not enabled, TLC reports a deadlock at that step.
EXTENDS MCmembership

VARIABLE step

Rcv(t, src, dst) ==
    \E m \in DOMAIN messages : /\ m.mtype = t /\ m.msource = src /\ m.mdest = dst
                               /\ Receive(m)

\* Receiving an AppendEntriesRequest has two spec actions: append (message
\* kept) and commit-update + reply (message consumed). After the append,
\* the append action stays enabled as a no-op, so name the one intended.
RcvAppend(src, dst) ==
    \E m \in DOMAIN messages : /\ m.mtype = AppendEntriesRequest /\ m.msource = src /\ m.mdest = dst
                               /\ Receive(m) /\ log'[dst] # log[dst]
RcvAck(src, dst) ==
    \E m \in DOMAIN messages : /\ m.mtype = AppendEntriesRequest /\ m.msource = src /\ m.mdest = dst
                               /\ Receive(m) /\ messages' # messages

Script ==
    CASE step = 0  -> Timeout(s1)
      [] step = 1  -> RequestVote(s1, s1)
      [] step = 2  -> RequestVote(s1, s2)
      [] step = 3  -> Ready(s1)
      [] step = 4  -> Rcv(RequestVoteResponse, s1, s1)
      [] step = 5  -> Rcv(RequestVoteRequest, s1, s2)   \* s2: UpdateTerm
      [] step = 6  -> Rcv(RequestVoteRequest, s1, s2)   \* s2 grants
      [] step = 7  -> Ready(s2)
      [] step = 8  -> Rcv(RequestVoteResponse, s2, s1)
      [] step = 9  -> BecomeLeader(s1)
      [] step = 10 -> AddNewServer(s1, s4)   \* B: add s4
      [] step = 11 -> AppendEntriesToSelf(s1)
      [] step = 12 -> AppendEntries(s1, s2, <<4, 5>>)
      [] step = 13 -> Ready(s1)
      [] step = 14 -> Rcv(AppendEntriesResponse, s1, s1)
      [] step = 15 -> RcvAppend(s1, s2)   \* append idx 4
      [] step = 16 -> RcvAck(s1, s2)   \* commit-update + reply
      [] step = 17 -> Ready(s2)
      [] step = 18 -> Rcv(AppendEntriesResponse, s2, s1)
      [] step = 19 -> AdvanceCommitIndex(s1)   \* commit 4
      [] step = 20 -> ApplySimpleConfChange(s1)   \* s1 on C1
      [] step = 21 -> DeleteServer(s1, s3)   \* C: remove s3
      [] step = 22 -> AppendEntriesToSelf(s1)
      [] step = 23 -> AppendEntries(s1, s2, <<5, 6>>)
      [] step = 24 -> AppendEntries(s1, s4, <<1, 5>>)   \* s4 gets 1..4
      [] step = 25 -> AppendEntries(s1, s3, <<4, 6>>)
      [] step = 26 -> Ready(s1)
      [] step = 27 -> Rcv(AppendEntriesResponse, s1, s1)
      [] step = 28 -> RcvAppend(s1, s2)   \* append idx 5
      [] step = 29 -> RcvAck(s1, s2)
      [] step = 30 -> Ready(s2)
      [] step = 31 -> Rcv(AppendEntriesRequest, s1, s4)   \* s4: UpdateTerm
      [] step = 32 -> RcvAppend(s1, s4)
      [] step = 33 -> RcvAck(s1, s4)
      [] step = 34 -> Ready(s4)
      [] step = 35 -> Rcv(AppendEntriesResponse, s4, s1)   \* match 4
      [] step = 36 -> AppendEntries(s1, s4, <<5, 6>>)   \* s4 gets 5
      [] step = 37 -> Ready(s1)
      [] step = 38 -> RcvAppend(s1, s4)
      [] step = 39 -> RcvAck(s1, s4)
      [] step = 40 -> Ready(s4)
      [] step = 41 -> Rcv(AppendEntriesRequest, s1, s3)   \* s3: UpdateTerm
      [] step = 42 -> RcvAppend(s1, s3)   \* s3 appends 4..5 (no separate commit step)
      [] step = 43 -> Rcv(AppendEntriesResponse, s2, s1)
      [] step = 44 -> Rcv(AppendEntriesResponse, s4, s1)   \* match 5
      [] step = 45 -> AdvanceCommitIndex(s1)   \* commit 5
      [] step = 46 -> ApplySimpleConfChange(s1)   \* s1 on C2
      [] step = 47 -> Heartbeat(s1, s2)
      [] step = 48 -> Ready(s1)
      [] step = 49 -> RcvAck(s1, s2)   \* heartbeat: s2 commit 5
      [] step = 50 -> ApplySimpleConfChange(s2)   \* s2 on C2
      [] step = 51 -> Timeout(s3)   \* D: s3 campaigns on C0
      [] step = 52 -> Timeout(s2)   \* s2 campaigns on C2
      [] step = 53 -> RequestVote(s3, s3)
      [] step = 54 -> RequestVote(s3, s1)
      [] step = 55 -> Ready(s3)
      [] step = 56 -> RequestVote(s2, s2)
      [] step = 57 -> RequestVote(s2, s4)
      [] step = 58 -> Ready(s2)
      [] step = 59 -> Rcv(RequestVoteRequest, s3, s1)   \* s1: UpdateTerm
      [] step = 60 -> Rcv(RequestVoteRequest, s3, s1)   \* s1 grants s3
      [] step = 61 -> Ready(s1)
      [] step = 62 -> Rcv(RequestVoteRequest, s2, s4)   \* s4: UpdateTerm
      [] step = 63 -> Rcv(RequestVoteRequest, s2, s4)   \* s4 grants s2
      [] step = 64 -> Ready(s4)
      [] step = 65 -> Rcv(RequestVoteResponse, s3, s3)
      [] step = 66 -> Rcv(RequestVoteResponse, s1, s3)
      [] step = 67 -> BecomeLeader(s3)
      [] step = 68 -> Rcv(RequestVoteResponse, s2, s2)
      [] step = 69 -> Rcv(RequestVoteResponse, s4, s2)
      [] step = 70 -> BecomeLeader(s2)

WitnessSpec == (Init /\ step = 0) /\ [][Script /\ step' = step + 1]_<<vars, step>>
=============================================================================
