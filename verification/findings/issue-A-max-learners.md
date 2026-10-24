# Draft issue (etcd-io/etcd): raising `--max-learners` one member at a time can make members disagree on membership, then crash-loop

**What happened?**

`--max-learners` is a per-member flag. Its help text says "the maximum
number of learners that can be available in the cluster membership", but
each member enforces its own value. It is checked when a learner add is
*applied* (`RaftCluster.ValidateConfigurationChange`), so members with
different values decide differently on the same committed
`ConfChangeAddLearnerNode`:
- members whose limit allows it add the learner;
- the others apply it as a no-op (`Validation on configuration change
  failed ... too many learner members in cluster`).

Members legitimately run different values while an operator raises the
limit by restarting members one at a time. A learner added during that
window reaches only some members' membership and raft configuration.

Starting that learner then crashes the other members. When it publishes
its attributes, they apply a `ClusterMemberAttrSet` for a member they
neither know nor have removed, and panic:

```
"level":"panic","caller":"membership/cluster.go:481","msg":"failed to update; member unknown"
```

They panic again on every restart: the entry is above their consistent
index, so it is replayed. Raising their flag doesn't help, because their
stored membership lacks the learner. In a 3-member cluster where one
member had been restarted with the higher limit, the other two crash-loop
and the cluster has no quorum. Recovery needs `--force-new-cluster` on the
remaining member or a snapshot restore.

**What did you expect to happen?**

Every member makes the same decision for a committed conf change, whatever
its local flags. Changing `--max-learners` one member at a time should not
be able to split membership or take members down.

**How can we reproduce it?**

A self-contained script (bash and stock `etcd`/`etcdctl`) is attached:
`A-max-learners.sh`. It:
1. starts 3 members with `--max-learners=1`;
2. restarts m1 with `--max-learners=2` and moves leadership to it;
3. adds two learners through m1;
4. starts the second learner, which must fetch the membership from m1;
5. restarts m2.

Output on main (3aaab3479):

```
member list on m1:
    479287c882245543 (not started) learner
    61f97220ab052a12 m3 voter
    69b38ac7138de88d m1 voter
    9e737febb6b99eee m2 voter
    eb4d0350daa7067f (not started) learner
member list on m2:
    479287c882245543 (not started) learner
    61f97220ab052a12 m3 voter
    69b38ac7138de88d m1 voter
    9e737febb6b99eee m2 voter
...
--- start l2 (as configured on m1). It must fetch the membership from m1, whose peer URL sorts first.
m2: exited
"level":"panic",...,"msg":"failed to update; member unknown"
m3: exited
"level":"panic",...,"msg":"failed to update; member unknown"
--- restart m2: it replays the same entry
m2: exited again after restart
RESULT: 2 of 3 voters down; no quorum (bug reproduced)
```

Some details of the reproduction:
- **Step 3 must go through m1:** the response comes from the receiving
  member's apply.
- **Step 4 needs m1 as leader.** The others don't replicate to a member
  they don't know.
- **Step 4 depends on peer order.** The joining learner takes the
  membership from the first peer that answers, in sorted-URL order. If
  that is m2 or m3, it fails to join with a membership mismatch.
- **The panic is what stops this from going further.** Without it, the
  extra learners could be promoted through m1, giving m1 voters
  {m1,m2,m3,l1,l2} while m2 and m3 have {m1,m2,m3}. Majorities {m1,l1,l2}
  and {m2,m3} don't intersect. We reproduced this on an in-process cluster
  with the panic replaced by a log line.
  So the panic must stay until membership can't diverge.

**Anything else we need to know?**

- **Existing checks.** #13377 (which added the flag) also added startup
  checks: at join, and on every restart in `Finalize`. They compare the
  local flag with the current learner count, not with other members' flags,
  so they don't catch this. They do matter for any fix: a member whose flag
  is lower than the number of learners in its membership refuses to start.
- **Affected versions:** 3.6.x and 3.7.x (the flag, the apply-time check
  and the panic are unchanged in v3.6.16 and v3.7.3), and main. 3.5 is not
  affected (`maxLearners` is a constant).
- **Safe procedure today:** don't add learners until every member runs the
  new `--max-learners`. It's not documented; documenting it is the
  smallest mitigation, and the only one available to existing releases.
- **Design options.** We'd like maintainers' direction before writing a
  PR. Every option that changes the apply-time decision must be gated on
  cluster version, so that members of different versions still agree;
  cluster version changes are applied in log order. None of them helps
  3.6/3.7 within a minor release.

  1. **Make the limit cluster-wide state.**
     - Store it in the membership, set through raft, and check it at apply
       time against the replicated value.
     - The flag becomes the initial value or a request to change it.
     - Cleanest semantics; needs an API and a migration story.
  2. **Publish each member's limit in its attributes; check against the
     minimum.**
     - Attributes are replicated (`ClusterMemberAttrSet`); this needs a new
       attribute field. The apply-time
       check could use the minimum limit published by the current voters,
       so every member decides alike.
     - During a change of the flag, the old, lower limit applies until
       every member has restarted with the new one.
     - The learner count never exceeds any member's flag, so the startup
       checks keep passing.
  3. **Carry the proposer's limit in the conf change, and check it at
     apply time.**
     - Deterministic, and it keeps the check serialized in apply.
     - But members with a lower flag then hold more learners than their
       flag allows, and fail the startup check on restart. That check
       would have to become a warning.
  4. **Check only when proposing.**
     - We tried this. It removes the divergence, but it has the same
       restart problem as option 3.
     - Concurrent adds can also overshoot the limit.
     - Not recommended.
  5. **Refuse learner adds while members' limits differ**, e.g. by
     comparing published values as in option 2. It is simple, but it
     blocks adds during a change of the flag.

  Our preference is option 2 (or 1, if maintainers want the limit to be a
  cluster setting).

**Etcd version (please run commands below)**

```
$ etcd --version
etcd Version: 3.8.0-alpha.0
Git SHA: 3aaab3479
```

**Etcd configuration (command line flags or environment variables)**

`--max-learners=1` on m2 and m3, `--max-learners=2` on m1 and the
learner; otherwise defaults. See the script.

**Relevant log output**

See above.
