---------------------------- MODULE RestartWitness ----------------------------
\* Copyright 2026 The etcd Authors
\*
\* Licensed under the Apache License, Version 2.0 (the "License");
\* you may not use this file except in compliance with the License.
\* You may obtain a copy of the License at
\*
\*     http://www.apache.org/licenses/LICENSE-2.0
\*
\* Unless required by applicable law or agreed to in writing, software
\* distributed under the License is distributed on an "AS IS" BASIS,
\* WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
\* See the License for the specific language governing permissions and
\* limitations under the License.
\*
\* A hand-written behavior of MCetcdraft, replayed step by step by TLC.
\*   A. s3 leads term 2, appends two value entries (4, 5) and persists them.
\*   B. s1 leads term 3 with s2; adds s4 (C1'), removes s3 (C2').
\*   C. s3 persists term 3 only, then overwrites 4, 5 with C1', C2' in
\*      memory (no Ready), and restarts. Restart keeps the in-memory log
\*      truncated to the persisted length, so s3 has C1', C2' with commit 3
\*      and config C0.
\*   D. Term 4: s3 wins on C0 with {s3,s1}; s2 wins on C2' with {s2,s4}.
\* Before Restart restores the persisted log, TLC reports
\* MoreThanOneLeaderInv violated at the last step. After, a step is not
\* enabled and TLC reports a deadlock there.
EXTENDS MCetcdraft

CONSTANTS s1, s2, s3, s4

VARIABLE step

Rcv(t, src, dst) ==
    \E m \in DOMAIN messages : /\ m.mtype = t /\ m.msource = src /\ m.mdest = dst
                               /\ Receive(m)

Script ==
    CASE step = 0  -> Timeout(s3)
      [] step = 1  -> RequestVote(s3, s3)
      [] step = 2  -> RequestVote(s3, s1)
      [] step = 3  -> Ready(s3)
      [] step = 4  -> Rcv(RequestVoteResponse, s3, s3)
      [] step = 5  -> Rcv(RequestVoteRequest, s3, s1)
      [] step = 6  -> Rcv(RequestVoteRequest, s3, s1)
      [] step = 7  -> Ready(s1)
      [] step = 8  -> Rcv(RequestVoteResponse, s1, s3)
      [] step = 9  -> BecomeLeader(s3)
      [] step = 10 -> ClientRequest(s3, 0)
      [] step = 11 -> ClientRequest(s3, 0)
      [] step = 12 -> Ready(s3)
      [] step = 13 -> Timeout(s1)
      [] step = 14 -> RequestVote(s1, s1)
      [] step = 15 -> RequestVote(s1, s2)
      [] step = 16 -> Ready(s1)
      [] step = 17 -> Rcv(RequestVoteResponse, s1, s1)
      [] step = 18 -> Rcv(RequestVoteRequest, s1, s2)
      [] step = 19 -> Rcv(RequestVoteRequest, s1, s2)
      [] step = 20 -> Ready(s2)
      [] step = 21 -> Rcv(RequestVoteResponse, s2, s1)
      [] step = 22 -> BecomeLeader(s1)
      [] step = 23 -> AddNewServer(s1, s4)
      [] step = 24 -> AppendEntriesToSelf(s1)
      [] step = 25 -> AppendEntries(s1, s2, <<4, 5>>)
      [] step = 26 -> Ready(s1)
      [] step = 27 -> Rcv(AppendEntriesResponse, s1, s1)
      [] step = 28 -> Rcv(AppendEntriesRequest, s1, s2)
      [] step = 29 -> Ready(s2)
      [] step = 30 -> Rcv(AppendEntriesResponse, s2, s1)
      [] step = 31 -> AdvanceCommitIndex(s1)
      [] step = 32 -> ApplySimpleConfChange(s1)
      [] step = 33 -> DeleteServer(s1, s3)
      [] step = 34 -> AppendEntriesToSelf(s1)
      [] step = 35 -> AppendEntries(s1, s2, <<5, 6>>)
      [] step = 36 -> AppendEntries(s1, s4, <<1, 6>>)
      [] step = 37 -> AppendEntries(s1, s3, <<4, 6>>)
      [] step = 38 -> Ready(s1)
      [] step = 39 -> Rcv(AppendEntriesResponse, s1, s1)
      [] step = 40 -> Rcv(AppendEntriesRequest, s1, s2)
      [] step = 41 -> Ready(s2)
      [] step = 42 -> Rcv(AppendEntriesRequest, s1, s4)
      [] step = 43 -> Rcv(AppendEntriesRequest, s1, s4)
      [] step = 44 -> Ready(s4)
      [] step = 45 -> Rcv(AppendEntriesResponse, s2, s1)
      [] step = 46 -> Rcv(AppendEntriesResponse, s4, s1)
      [] step = 47 -> AdvanceCommitIndex(s1)
      [] step = 48 -> ApplySimpleConfChange(s1)
      [] step = 49 -> Heartbeat(s1, s2)
      [] step = 50 -> Ready(s1)
      [] step = 51 -> Rcv(AppendEntriesRequest, s1, s2)
      [] step = 52 -> ApplySimpleConfChange(s2)
      [] step = 53 -> Rcv(AppendEntriesRequest, s1, s3)
      [] step = 54 -> Ready(s3)
      [] step = 55 -> Rcv(AppendEntriesRequest, s1, s3)
      [] step = 56 -> Rcv(AppendEntriesRequest, s1, s3)
      [] step = 57 -> Rcv(AppendEntriesRequest, s1, s3)
      [] step = 58 -> Restart(s3)
      [] step = 59 -> Timeout(s3)
      [] step = 60 -> Timeout(s2)
      [] step = 61 -> RequestVote(s3, s3)
      [] step = 62 -> RequestVote(s3, s1)
      [] step = 63 -> Ready(s3)
      [] step = 64 -> RequestVote(s2, s2)
      [] step = 65 -> RequestVote(s2, s4)
      [] step = 66 -> Ready(s2)
      [] step = 67 -> Rcv(RequestVoteRequest, s3, s1)
      [] step = 68 -> Rcv(RequestVoteRequest, s3, s1)
      [] step = 69 -> Ready(s1)
      [] step = 70 -> Rcv(RequestVoteRequest, s2, s4)
      [] step = 71 -> Rcv(RequestVoteRequest, s2, s4)
      [] step = 72 -> Ready(s4)
      [] step = 73 -> Rcv(RequestVoteResponse, s3, s3)
      [] step = 74 -> Rcv(RequestVoteResponse, s1, s3)
      [] step = 75 -> BecomeLeader(s3)
      [] step = 76 -> Rcv(RequestVoteResponse, s2, s2)
      [] step = 77 -> Rcv(RequestVoteResponse, s4, s2)
      [] step = 78 -> BecomeLeader(s2)

RestartWitnessSpec == (Init /\ step = 0) /\ [][Script /\ step' = step + 1]_<<vars, step>>
=============================================================================
