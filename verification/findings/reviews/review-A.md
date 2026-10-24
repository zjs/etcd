# Review: issue A (`--max-learners`) and branch `fix/max-learners-at-propose` (94c96e081, a78cd5195)

**(a) Verdict: needs changes.** The bug is real and the report is mostly
accurate. But the branch has two problems, both reproduced:
- Commit 1 leaves members with the lower `--max-learners` unable to restart.
- Commit 2 removes the panic that is currently the only thing preventing
  the split-brain scenario the issue warns about.

I would not merge either commit as is.

## (b) Issue-report feedback

**Correct as written**
- **[run]** Steps 1–3 work on upstream `main`.
  - `TestMaxLearnerMixedConfig` from the branch, run against upstream
    server code, fails with "members disagree on learners".
  - m1 and m2 log `Validation on configuration change failed ... too many
    learner members`.
- **[run]** The panic is real. Starting the extra learner on upstream gives
  `PANIC m2 failed to update; member unknown`.
- **[code]** 3.5 is not affected (`const maxLearners = 1` in v3.5.34).
  - v3.6.0–v3.6.15 have the flag, the apply-time check and the panic.

**Overclaimed or wrong**
1. **The disjoint-majorities claim does not hold for upstream.** **[run]**
   - The extra learner publishes its attributes as soon as it starts.
   - m1 and m2 panic before an operator can promote it, and m0 alone has
     no quorum.
   - So the TLA+ witness cannot happen on upstream: the model has no
     attribute-publish step. It *does* happen once the panic is removed
     (code finding 2).
   - Drop the paragraph, or reframe it as "the panic is currently what
     prevents a voter-set split".
2. **"Detecting mismatches as a follow-up; we found no implementation" is
   misleading.** **[code]**
   - #13377 itself added startup checks of the local flag against the
     actual learner count (`bootstrap.go` at join and in `Finalize`, on
     every restart). Step 4 needs `--max-learners=2` because of the join
     check.
   - The issue should name these checks and say why they don't catch the
     divergence: they compare the flag with membership, not with the other
     members' flags.
3. **Affected versions are incomplete.** **[code]**
   - v3.7.0-beta.0 is also affected, so list 3.6.x, 3.7 and main.
   - Say plainly that a fix gated on 3.8 does nothing for 3.6 and 3.7.
   - Fix the SHA mismatch: the issue says main is `bf9cadf`; the branch is
     based on `3aaab3479`.
4. **Lead with the legitimate premise.** **[judgment]**
   - As written, the setup reads like an artificial misconfiguration.
   - The realistic trigger is raising `--max-learners` by restarting
     members one at a time, with a learner added before the last member is
     restarted.
   - Also note the flag's help text ("in the cluster membership") implies a
     cluster-wide limit, yet it is per member.
5. **Make the reproduction precise.**
   - **[run]** "Make it leader" isn't needed for steps 1–3; it is needed for
     step 4. Say how: `etcdctl move-leader`.
   - **[code]** Step 4 depends on peer order.
     - `getClusterFromRemotePeers` asks peers in sorted-URL order and uses
       the first that answers.
     - If m1 or m2 answers first, `ValidateClusterAndAssignIDs` fails on
       mismatched counts.
     - State that the joining learner must fetch membership from member 0.
6. **State the recovery cost.** **[code + judgment]**
   - On restart, m1 and m2 replay the same `ClusterMemberAttrSet` entry,
     which is above their consistent index.
   - Raising their flag doesn't help: the backend membership already lacks
     the learner.
   - With 2 of 3 voters crash-looping, recovery means disaster recovery.
7. **Fix the description of where the check runs.** **[code]** Direction 1
   says "on the leader". `mayAddMember` runs on the member that *receives*
   the request.

## (c) Code findings

1. **Members with the lower limit can no longer restart (`bootstrap.go`
   `Finalize`, and the join check).** **[run]**
   - After commit 1, m1 and m2 (limit 1) apply both learners.
   - Restarting m1 then fails with `membership: too many learner members in
     cluster`.
   - Even with a single limit, a proposal-time check on a lagging view can
     let an extra learner in, and then every member refuses to restart.
   - Suggested: make the restart check a warning if the limit becomes a
     proposal-time limit, or carry the limit in the ConfChange. Add a
     restart test either way.
2. **Commit 2 removes the fail-stop that prevents voter-set divergence.**
   **[run]**
   - Setup: upstream plus commit 2 only, which is also the full branch
     below cluster version 3.8. m0 at limit 3, the others at 1.
   - Learners y and z start. m1 and m2 log "skipped attributes update of
     unknown member" and keep running.
   - Both promotions through m0 succeed. m0 has voters {m0,m1,m2,y,z}; m1
     and m2 have {m0,m1,m2}.
   - The majorities {m0,y,z} and {m1,m2} don't intersect.
   - Suggested: drop commit 2. If the crash loop needs addressing, propose
     a design that still stops the member from serving or voting on a
     diverged view.
3. **The comment overstates the change.** It says the limit is enforced at
   proposal "and not when it is applied", but below 3.8 it is still checked
   at apply.
4. **The version gate is hard-coded.**
   - `V3_8` is correct and deterministic: cluster version changes only
     through `SetVersion` in apply.
   - But it must change if 3.8 has branched by the time this merges. Say
     so, or use a named constant.
5. **The downgrade "open question" is answerable.** **[code]**
   - `ValidateConfigurationChange` returns nil when `!shouldApplyV3`.
   - A 3.7 binary starts only after the storage version is downgraded,
     which happens after the downgrade entry is applied.
   - The remaining downgrade problem is finding 1.
6. **Process.** No `Signed-off-by` (DCO). Author is a bot identity. No
   CHANGELOG entry. Two PRs, given finding 2.

## (d) Test findings

- **`TestMaxLearnerMixedConfig`:**
  - **[run]** Passes 5/5 on the branch, fails on upstream.
  - Should also check that members can restart.
  - Comment why `DisableStrictReconfigCheck` is needed: m0 has just
    restarted, so the `HealthInterval` guard would otherwise reject the
    add.
- **The gating unit test** covers nil, 3.7 and 3.8; add ≥3.9.
- **Missing:**
  - a unit test of the new `mayAddMember` branch;
  - an e2e mixed-version or downgrade test.

## (e) Alternatives a maintainer would likely prefer [judgment]

1. Carry the proposer's `MaxLearners` in `ConfigChangeContext` and validate
   at apply against it: deterministic and serialized, still version-gated.
2. A cluster-wide limit stored in the backend, set through raft.
3. Document that the flag must be uniform and reject mismatches at join.
   This doesn't help when the flag is changed one member at a time.

## (f) Likely maintainer questions

- How did you hit this? Is it realistic outside a one-member-at-a-time
  flag change?
- Why not carry the limit in the ConfChange?
- What happens on restart when membership has more learners than the local
  flag?
- What is the backport plan for 3.6 and 3.7?
- Why remove a deliberate invariant panic?
- Can you add a mixed-version or downgrade e2e test?

## Fine as is

- Gating apply behaviour on cluster version, rather than on a per-member
  feature gate.
- Checking at proposal time even without strict reconfig check.
- The unchanged error mapping (`ErrGRPCTooManyLearners`).
- Logging style, and commit prefixes.
