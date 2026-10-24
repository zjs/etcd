# Review: issue C (stale membership guard), option 1 (`fix/membership-check-committed-view`) and option 2 (`fix/membership-check-cas`)

## (a) Verdicts

- **Option 1: needs changes (small).**
  - The mechanism is correct and idiomatic. It follows the same pattern as
    `MemberList(Linearizable)`, and it can be backported.
  - Missing: a test and an honest scope statement.
- **Option 2: would reject in its current form.**
  - A CAS-rejected remove replayed on restart makes the member stop itself,
    or makes peers cut off a live member.
  - The digest is captured at an unsafe point.
  - There is a downgrade/WAL-versioning gap.
  - It has only a unit test.

## (b) Issue-report feedback

1. **The bug is real.** **[test]**
   - The add case with a longer election timeout
     (`integration.ElectionTicks=300`) reproduces on upstream main: the
     stale follower accepted op2.
   - On option 1 it was refused with `unhealthy cluster`.
2. **Versions.**
   - #21641 is also in **v3.7.0-beta.0**.
   - Cite current patches (v3.5.34, v3.6.15), not v3.5.29 / v3.6.10.
3. **A missing mechanism: the follower's raft loop blocks.** **[code:
   etcdserver raft.go]**
   - A follower with a committed but unapplied conf change blocks its raft
     loop until the apply finishes: no messages, no `Advance`.
   - So the frozen follower stops answering heartbeats, and its forwarded
     proposal leaves only after it applies C1.
   - The repro window must therefore stay below the election timeout.
   - This also means the scaffold's "not reproduced with option 1" is not
     evidence. **[test]** Under option 1 the original harness got `request
     timed out` and `leader changed`: the leader lost quorum while the
     follower was frozen.
4. **The concurrent case is overclaimed as written.**
   - Raft drops a second conf change while one is pending at the leader. So
     two requests checked at the leader usually end in a client timeout,
     not a double apply.
   - The real concurrent path: the second proposal is checked on a follower
     before C1's commit reaches it. Its MsgProp is held by the wait above
     and reaches the leader after the leader has applied C1.
5. **Frame impact fairly.**
   - Quorum loss is recoverable in both variants: start n0/n1, or bring
     back the down member.
   - The add case means adding two voters without starting the first,
     against the documented procedure.
   - The remove case is stronger. It needs B to still be connected to S,
     which holds for about 1s (`stopWithDelay(1s)`).
6. **Scope the enumeration claim** to what the script models.
7. **"No upstream-style test because the window is too short" is wrong.**
   - Upstream already has the gofail point `beforeApplyOneConfChange`,
     used with `sleep("2s")` by `TestCtlV3ConsistentMemberList`.
   - e2e can set it on one member via `Procs[i].Failpoints().SetupHTTP`.
8. **Make the reproduction runnable:** an e2e test or etcdctl steps using
   the failpoint, not a read-lock hack in an unpublished package.
9. **Rephrase direction 1.** "Re-run the guard on the leader when it
   appends" needs a raft change; the etcd-level equivalent is forwarding
   add/remove to the leader, as promote does.
10. **Process.** Bot author identity, no `Signed-off-by`, no CHANGELOG.

## (c) Code findings

**Option 2**
1. **Critical: replaying a CAS-rejected remove.** **[test]**
   - On `shouldApplyV3=false`, `ValidateConfigurationChange` returns nil.
     `applyConfChange` then runs the side effects anyway:
     - remove-self stops the server ("permanently removed");
     - remove-other calls `transport.RemovePeer` on a live member.
   - This is latent upstream; CAS makes it reachable.
   - Reproduced in a unit test (apply twice, `shouldStop=true` on replay)
     and in an integration test (after restart, S stops; another member
     removes S's peer).
   - A prerequisite fix would base the side effects on current state during
     replay.
2. **High: the digest is captured before the guard, not atomically with
   it.**
   - ABA example: capture D0; add X then remove X apply; the guard runs on
     D0+X; the change applies on D0 and the digest matches.
   - Promote captures it before `waitAppliedIndex`, which causes spurious
     rejections.
   - Fix: snapshot members once, and run the guard and compute the digest
     on that snapshot.
3. **High: downgrade.**
   - WAL version detection classifies every `EntryConfChange` as V3_0, so
     `etcdutl migrate` won't refuse a downgrade while CAS entries remain.
   - A 3.7 binary replaying such an entry above its consistent index
     accepts what 3.8 members rejected.
4. **Medium: error precedence.** The CAS check runs before the
   deterministic checks (ErrIDExists, ErrPeerURLexists, ...).
5. **Medium: the error isn't identifiable as retryable.**
   - It uses `FailedPrecondition`, the same code as non-retryable errors;
     `Aborted` fits better.
   - A forwarded promote falls through to 500 / "unknown error".
6. **Low:** new apply-time panic on a malformed remove context.
7. **Low:** digest content is sufficient (IDs and roles). Expect "why not an
   index?".
8. **Low:** gating on the proposer's cluster version is acceptable.

**Option 1**
1. **Medium: scope and errors.**
   - `LinearizableReadNotify` waits for `applied ≥ leader commit at
     ReadIndex`, and `applyConfChange` updates `s.cluster` before
     `setAppliedIndex`. So the guard sees every conf change committed
     before the barrier. Correct.
   - It does not cover a proposal checked before C1 commits.
   - Without a leader it now returns `ErrTimeout`/`ErrLeaderChanged` after
     `ReqTimeout`. Acceptable; note it.
2. **Low:** call `s.read.LinearizableReadNotify(ctx)` directly, as
   `MemberList` does. (Note: on current main `MemberList` calls
   `s.LinearizableReadNotify`; see the branch.)
3. **Cost:** one ReadIndex round trip per add/remove. Negligible.

## (d) Test findings

- **Option 1:** a deterministic e2e test with gofail is feasible.
  - Recipe: `SetupHTTP("beforeApplyOneConfChange", sleep(...))` on one
    follower; 4 members with one stopped; MemberAdd via the leader, then
    MemberAdd via the slept follower; assert `unhealthy cluster`.
  - Keep the sleep below the election timeout.
  - Add the remove variant for backports.
- **Option 2** would need, at minimum:
  - apply and replay tests;
  - a determinism test;
  - an emission-gating test;
  - an e2e repro;
  - mixed-version and downgrade e2e tests;
  - error-mapping tests.

## (e) Likely maintainer questions

1. Can you reproduce it with an e2e test and `beforeApplyOneConfChange`?
2. Is the quorum loss permanent? Does it happen with the documented
   learner-first procedure?
3. StrictReconfigCheck is best-effort anyway. Why close this hole?
4. How does raft's pending-conf-change drop interact with the "concurrent"
   claim?
5. Backports to 3.5/3.6? (Only option 1 is backportable.)
6. Why a digest in JSON, and not serializing on the leader? WAL version
   detection? Downgrade?
7. Why `FailedPrecondition`, and should clients retry?
8. Duplicates? Related: #21640/#21641, #16798. No exact duplicate found.

## (f) Recommendation

- Ship option 1 first, as a small bug fix with an e2e failpoint test and
  backports.
- Re-scope the issue to the stale-view case, plus a precisely described
  residual case.
- Treat the concurrent case as a separate design discussion. Option 2 is
  viable only after:
  - the replay side-effect fix;
  - an atomic digest;
  - WAL version detection;
  - an error-code decision.
