# Review: issue B (promote liveness) and branch `fix/promote-reachable-quorum` (a1d6043f6)

## (a) Verdict: needs changes

The bug is real and the approach is reasonable. But the branch breaks an
existing upstream test, the issue gets the affected versions wrong, and the
commit has no DCO sign-off.

## (b) Issue-report feedback

1. **Wrong version claim.**
   - #11640 shipped in **v3.4.4** (CHANGELOG-3.4), not "v3.4.16 and later".
   - The "ever started" guard predates it: it dates from learner support
     (3.4.0).
   - Say "all releases with learner support (3.4.0+)". release-3.4 still
     gets patch releases.
2. **Version line mismatch.**
   - It says "main at bf9cadf", but the branch is based on 3aaab3479.
   - Add the log lines the template asks for: the leader's `stepped down to
     follower since quorum is not active`, and the client timeout.
3. **Make the reproduction runnable by maintainers.**
   - "Integration test available" points to code behind a private build
     tag.
   - Give etcdctl steps or the self-contained test inline.
   - `TestMemberPromoteUnreachableLearner` fails on upstream main as
     expected, so it is a good repro.
4. **State the preconditions.**
   - On main, `mayAddMember` refuses a learner add while one of 3 voters is
     down, so the learner must be added while all voters are up.
   - Then a voter goes down *and* the learner stops, and only then does an
     operator promote.
   - That is a double fault plus an operator action.
5. **Severity.**
   - This is availability loss only; there is no safety or data impact.
   - It recovers if either the learner or the down voter returns.
   - If neither can (learner node decommissioned), recovery needs
     `--force-new-cluster` or a snapshot restore, because member remove
     itself needs quorum. That is the strongest argument for the fix.
6. **Wrong test citation.**
   - `TestReproduce20340` only promotes via
     `mustCreateNewClusterByPromotingMembers`, and only its 1→2 step needs
     the asymmetry.
   - `TestRuntimeReconfigGrowClusterSize` ("1 to 3 with learner") is the
     accurate citation.
7. **Trim the TLA+ material** to a footnote. Move the fix design notes into
   the PR description.
8. **State the residual gap:** a learner cut off without the connection
   closing still counts until the transport notices.

## (c) Code findings

1. **Regression: `TestMemberPromoteMemberNotLearner` fails.**
   - Promoting a *voter* on a freshly started cluster now returns
     `etcdserver: unhealthy cluster` instead of `can only promote a learner
     member`. The test is gofail-gated, so it skips in a default run.
   - Cause:
     - `isLearnerReady` returns nil for a voter.
     - The new check then counts the id once as a voter and once as the
       "learner", against quorum(n+1).
     - Voters connected for less than `HealthInterval` then cause a false
       `ErrUnhealthy`.
   - Fix: run the new check only when the target is a learner, and add a
     unit case with a voter.
2. **Mixed versions: an old follower forwarding to a new leader.**
   - The new leader returns 412 "unhealthy cluster". The old follower's
     `promoteMemberHTTP` doesn't recognize it.
   - `PromoteMember` then retries with no backoff until `ReqTimeout`. The
     same already happens today for `ErrNotEnoughStartedMembers` (500).
   - Document it in the PR. Reverse case: there is no protection until the
     leader runs the new version (the check only runs on the leader).
3. **Two changes in one commit.** The forwarding error mapping is a separate
   behavior fix (forwarded `ErrNotEnoughStartedMembers` timed out before
   too). Split it, with its own test; `etcdhttp/peer_test.go`'s
   `fakeServer` makes this easy.
4. **Wrong comment.** Catch-up is checked by `isLearnerReady`, not
   `IsReadyToPromoteMember`.
5. **"Connected now" is weaker than the message says.**
   - `ActiveSince` is one `peerStatus`, shared by the pipeline, the streams
     and the snapshot sender.
   - It is set on the first successful attach, dial or send, and resets on
     any write, heartbeat, dial or read error.
   - A clean stop is detected almost at once; a silent partition can take
     up to `ConnReadTimeout`/`ConnWriteTimeout` (5s).
   - The asymmetry is defensible (a caught-up Match implies a successful
     send). Reword "reachable" to "no transport failure observed", and
     state the gap.
6. **Logs.**
   - The existing promote log uses key `requested-member-remove-id`; fix it.
   - Add active-peer and quorum fields to the new warning.
7. **Process.**
   - No `Signed-off-by`.
   - A session URL trailer would land in upstream history.
   - Backports need CHANGELOG entries.

## (d) Test findings

- **`TestMemberPromoteUnreachableLearner`:**
  - Passes 3/3, and 2/2 with `-race -cpu=2`; fails on main. About 8.3s.
  - Replace the fixed 3s sleep with a wait on the leader's
    `etcd_network_active_peers` for the learner. If the leader hasn't yet
    noticed the stop, the promote succeeds and the test wedges.
  - Add a positive path: restart the learner, let it catch up, promote with
    the voter still down, and assert success plus a Put.
- **Unit tests:** add a voter-id case and a 5-voter case.
- **Error mapping:** no test for the peer handler's status mapping or for
  `promoteMemberHTTP`.
- **Gofail-gated tests:** run the promote tests with gofail enabled before
  claiming integration passes.

## (e) Likely maintainer questions

1. Isn't this operator error? Answer: strict-reconfig-check exists to
   refuse changes that break the active quorum, and add/remove already
   check connectivity. Stress the permanently-gone learner.
2. Why does the learner get a different window from the voters?
3. Why not put learner liveness in `isLearnerReady` and return
   `ErrLearnerNotReady`?
   - Old followers already return early on it, and tools retry on it.
   - Downside: it also changes behavior in non-strict mode.
4. Should a disconnected learner ever be promotable when the voters alone
   keep quorum? It matches add semantics, but leaves fault tolerance at 0.
5. Interaction with finding C? Promote's check runs only on the leader.
6. Behavior change: promote can now return `Unavailable` within 5s of a
   voter reconnecting. The client doesn't auto-retry `MemberPromote`.
7. Backport plan for 3.5/3.6?

## (f) Fine as is

- Running the check only on the leader.
- Reusing `numConnectedSince`/`HealthInterval`, `quorum(n+1)` and
  `ErrUnhealthy`.
- Rejecting promotion of a disconnected learner in a one-voter cluster.
- Error-string matching in `promoteMemberHTTP` (existing convention).
- The integration test's final Put check.
