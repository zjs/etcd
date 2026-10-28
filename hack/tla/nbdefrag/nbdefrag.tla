------------------------------ MODULE nbdefrag ------------------------------
(***************************************************************************)
(* Model of etcd's non-blocking backend defragmentation                    *)
(* (server/storage/backend/backend.go: defragNonBlocking, catchUpDefrag,   *)
(* finishDefrag; server/etcdserver/server.go: Defragment, applySnapshot;   *)
(* server/storage/mvcc/kvstore_compaction.go: scheduleCompaction).         *)
(*                                                                         *)
(* Data: the live bbolt db is split into the committed state (what a new   *)
(* read tx sees) and the state of the always-open batch write tx.          *)
(*   Key   bucket: set of revisions (safe-range, append-only except        *)
(*                 compaction deletes).                                    *)
(*   Lease bucket: arbitrary put/delete (stands in for every non-safe-     *)
(*                 range bucket: lease, auth, members, alarm, ...).        *)
(*   Meta  bucket: consistent index, written by the pre-commit hook.       *)
(*                                                                         *)
(* Locks (Go semantics): bt = batchTx mutex; rt = readTx RWMutex;          *)
(* bmu = backend.mu; srd = safeRangeDeleteMu; bemu = EtcdServer.bemu.      *)
(* An RWMutex is [r: readers, w: writer, p: writer that has announced      *)
(* itself and is waiting for readers]; while p # Nil new RLock()s block.   *)
(***************************************************************************)
EXTENDS Naturals, FiniteSets, Sequences, TLC

CONSTANTS MaxRev,              \* key-bucket puts: revisions 1..MaxRev
          LeaseKeys,           \* keys of the non-safe-range bucket
          LeaseVals,           \* values; 0 means "absent"
          MaxLeaseOps,         \* bound on lease-bucket writes
          CompactRev,          \* compaction target; 0 disables compaction
          CompactionTakesLock, \* TRUE = scheduleCompaction holds srd.RLock (as coded)
          DefragHoldsBemu,     \* TRUE = Defragment holds bemu.RLock (as coded)
          WithSnapshot,        \* apply goroutine may install a leader snapshot
          NumCommits,          \* bound on periodic backend.run() commits
          Aux,                 \* enabled auxiliary goroutines
          ReleaseQueuedCompaction \* TRUE = compactBarrier closes ch when the store stops (fix)

Nil == "nil"
NoLock == [r |-> {}, w |-> Nil, p |-> Nil]
CanR(l) == l.w = Nil /\ l.p = Nil
Max(S) == CHOOSE x \in S : \A y \in S : x >= y

(* --algorithm nbdefrag {
variables
  \* live db
  cKey = {}, cLease = [k \in LeaseKeys |-> 0], cMeta = 0,   \* committed
  uKey = {}, uLease = [k \in LeaseKeys |-> 0],              \* open write tx
  applied = 0, nextRev = 1, leaseOps = 0, gen = 0,          \* gen: backend instance
  \* tmp db
  tKey = {}, tLease = [k \in LeaseKeys |-> 0], tMeta = 0, lastKey = 0,
  dGen = 0, defragDone = FALSE,
  \* compaction / snapshot
  compactScheduled = FALSE, compactDone = FALSE, stopCompaction = FALSE,
  snapDone = FALSE,
  boltReaders = {},
  \* locks
  bt = Nil, rt = NoLock, bmu = NoLock, srd = NoLock, bemu = NoLock;

define {
  \* The db renamed over the live one must hold exactly the live contents.
  CopyMatches == tKey = cKey /\ tLease = cLease /\ tMeta = cMeta
  \* Lock sanity.
  LockInv == /\ rt.w # Nil => rt.r = {}
             /\ bmu.w # Nil => bmu.r = {}
             /\ srd.w # Nil => srd.r = {}
             /\ bemu.w # Nil => bemu.r = {}
  DefragTerminates == <>defragDone
}

\* batchTxBuffered.Commit(): bt -> rt.Lock -> unsafeCommit -> begin(b.mu.RLock)
procedure ForceCommit() {
  fc1: await bt = Nil; bt := self;
  fc2: await rt.w = Nil /\ rt.p = Nil; rt.p := self;
  fc3: await rt.r = {}; rt := [rt EXCEPT !.w = self, !.p = Nil];
  fc4: await CanR(bmu);
       cKey := uKey || cLease := uLease || cMeta := applied;
  fc5: rt.w := Nil;
       bt := Nil;
       return;
}

\* Apply goroutine (EtcdServer.applyAll).
fair process (apply = "apply")
variables lk = Nil, lv = 0;
{
 aLoop:
  while (nextRev <= MaxRev \/ leaseOps < MaxLeaseOps
         \/ (CompactRev > 0 /\ ~compactScheduled) \/ (WithSnapshot /\ ~snapDone)) {
    \* VerifyBackendConsistency(s.Backend(), ...) after each batch: bemu.RLock/RUnlock
    aBemu: await CanR(bemu);
    either {
      \* Put: one new revision in the key bucket.
      await nextRev <= MaxRev;
      aPL: await bt = Nil; bt := "apply";
      aP:  uKey := uKey \cup {nextRev}; nextRev := nextRev + 1; applied := applied + 1;
      \* batchTxBuffered.Unlock(): writeback under readTx.Lock()
      aPWa: await rt.w = Nil /\ rt.p = Nil; rt.p := "apply";
      aPWb: await rt.r = {}; rt := [rt EXCEPT !.w = "apply", !.p = Nil];
      aPWc: rt.w := Nil;
            bt := Nil;
    } or {
      \* Lease-bucket put or delete (deletes commit immediately).
      await leaseOps < MaxLeaseOps;
      with (k \in LeaseKeys, v \in LeaseVals) { lk := k; lv := v };
      aLL: await bt = Nil; bt := "apply";
      aL:  uLease[lk] := lv; leaseOps := leaseOps + 1; applied := applied + 1;
      aLWa: await rt.w = Nil /\ rt.p = Nil; rt.p := "apply";
      aLWb: await rt.r = {}; rt := [rt EXCEPT !.w = "apply", !.p = Nil];
      aLWc: if (lv = 0) {
              await CanR(bmu);
              cKey := uKey || cLease := uLease || cMeta := applied;
            };
      aLWd: rt.w := Nil;
            bt := Nil;
    } or {
      \* Compact request: updateCompactRev -> ForceCommit; schedule the job.
      await CompactRev > 0 /\ ~compactScheduled /\ nextRev > CompactRev;
      aC: applied := applied + 1;
          call ForceCommit();
      aCs: compactScheduled := TRUE;
    } or {
      \* applySnapshot: bemu.Lock -> kv.Restore (fifoSched.Stop waits for the
      \* running compaction job) -> swap backend.
      await WithSnapshot /\ ~snapDone;
      aSa: await bemu.w = Nil /\ bemu.p = Nil; bemu.p := "apply";
      aSb: await bemu.r = {}; bemu := [bemu EXCEPT !.w = "apply", !.p = Nil];
      aSc: stopCompaction := TRUE;
      aSd: await pc["compactor"] \in {"cWait", "Done"};
           gen := gen + 1;
      aSe: bemu.w := Nil;
           snapDone := TRUE;
    }
  }
}

\* Periodic batch commit (backend.run).
fair process (committer = "committer")
variables n = 0;
{
 pLoop: while (n < NumCommits) {
   n := n + 1;
   call ForceCommit();
 }
}

\* Scheduled compaction job (store.scheduleCompaction), batch size 1.
fair process (compactor = "compactor")
variables cr = 1;
{
 cWait: await compactScheduled \/ stopCompaction;
        \* A job still queued when Restore stops the scheduler runs with a cancelled
        \* ctx and only reaches compactBarrier, which (as coded) drops its done channel.
        if (stopCompaction) {
          if (ReleaseQueuedCompaction) { compactDone := TRUE };
          goto Done;
        };
 cSR:   if (CompactionTakesLock) {
          await CanR(srd); srd.r := srd.r \cup {"compactor"};
        };
 cLoop: while (cr < CompactRev) {
   cBt:  await bt = Nil; bt := "compactor";
   cDel: uKey := uKey \ {cr}; cr := cr + 1;
   cWa:  await rt.w = Nil /\ rt.p = Nil; rt.p := "compactor";
   cWb:  await rt.r = {}; rt := [rt EXCEPT !.w = "compactor", !.p = Nil];
   cCm:  await CanR(bmu);
         cKey := uKey || cLease := uLease || cMeta := applied;
   cRel: rt.w := Nil;
         bt := Nil;
   cSleep: if (stopCompaction) { goto cEnd };
 };
 cEnd: if (CompactionTakesLock) { srd.r := srd.r \ {"compactor"} };
       compactDone := TRUE;
}

\* Compact RPC with physical=true: waits for the job, then
\* bemu.RLock -> be.ForceCommit -> bemu.RUnlock (v3_server.go).
fair process (physc = "physc")
{
 a_physc: if ("physc" \notin Aux) { goto Done };
 phW: await compactDone \/ CompactRev = 0;
 phB: await CanR(bemu); bemu.r := bemu.r \cup {"physc"};
 phF: call ForceCommit();
 phR: bemu.r := bemu.r \ {"physc"};
}

\* Corruption checker store.hash(): ForceCommit, then b.mu.RLock around db.View.
fair process (hasher = "hasher")
{
 a_hasher: if ("hasher" \notin Aux) { goto Done };
 hF: call ForceCommit();
 hM: await CanR(bmu); bmu.r := bmu.r \cup {"hasher"}; boltReaders := boltReaders \cup {"hasher"};
 hV: bmu.r := bmu.r \ {"hasher"}; boltReaders := boltReaders \ {"hasher"};
}

\* hashByRev / range reads: readTx.RLock held across the read.
fair process (reader = "reader")
{
 a_reader: if ("reader" \notin Aux) { goto Done };
 rR: await CanR(rt); rt.r := rt.r \cup {"reader"};
 rD: rt.r := rt.r \ {"reader"};
}

\* Maintenance Snapshot RPC: s.Backend() then be.Snapshot() (commit, then a
\* bolt read tx held while streaming).
fair process (snapsender = "snapsender")
{
 a_snapsender: if ("snapsender" \notin Aux) { goto Done };
 sB: await CanR(bemu);
 sF: call ForceCommit();
 sM: await CanR(bmu); boltReaders := boltReaders \cup {"snapsender"};
 sS: boltReaders := boltReaders \ {"snapsender"};
}

\* EtcdServer.Defragment -> backend.defragNonBlocking.
fair process (defrag = "defrag")
{
 dBemu: if (DefragHoldsBemu) { await CanR(bemu); bemu.r := bemu.r \cup {"defrag"} };
        dGen := gen;
 dSa:  await srd.w = Nil /\ srd.p = Nil; srd.p := "defrag";
 dSb:  await srd.r = {}; srd := [srd EXCEPT !.w = "defrag", !.p = Nil];
 dFc:  call ForceCommit();
 \* Phase 1: read-only snapshot of the live db; bulk-copy the key bucket.
 dP1:  await CanR(bmu);
       tKey := cKey;
       lastKey := IF cKey = {} THEN 0 ELSE Max(cKey);
 \* Phase 2: stop the world.
 dBt:  await bt = Nil; bt := "defrag";
 dMa:  await bmu.w = Nil /\ bmu.p = Nil; bmu.p := "defrag";
 dMb:  await bmu.r = {}; bmu := [bmu EXCEPT !.w = "defrag", !.p = Nil];
 dRa:  await rt.w = Nil /\ rt.p = Nil; rt.p := "defrag";
 dRb:  await rt.r = {}; rt := [rt EXCEPT !.w = "defrag", !.p = Nil];
 dCm:  cKey := uKey || cLease := uLease || cMeta := applied;  \* unsafeCommit(stop)
 dCu:  tKey := tKey \cup {r \in cKey : r > lastKey} || tLease := cLease || tMeta := cMeta;
 dChk: assert CopyMatches;
       assert dGen = gen;   \* still defragmenting the live backend
 \* finishDefrag: db.Close() waits for every open bolt read tx.
 dCl:  await boltReaders = {};
 dRel: rt.w := Nil;
       bmu.w := Nil;
       bt := Nil;
       srd.w := Nil;
 dEnd: if (DefragHoldsBemu) { bemu.r := bemu.r \ {"defrag"} };
       defragDone := TRUE;
}
} *)
\* BEGIN TRANSLATION (chksum(pcal) = "d4961226" /\ chksum(tla) = "9266935f")
VARIABLES pc, cKey, cLease, cMeta, uKey, uLease, applied, nextRev, leaseOps, 
          gen, tKey, tLease, tMeta, lastKey, dGen, defragDone, 
          compactScheduled, compactDone, stopCompaction, snapDone, 
          boltReaders, bt, rt, bmu, srd, bemu, stack

(* define statement *)
CopyMatches == tKey = cKey /\ tLease = cLease /\ tMeta = cMeta

LockInv == /\ rt.w # Nil => rt.r = {}
           /\ bmu.w # Nil => bmu.r = {}
           /\ srd.w # Nil => srd.r = {}
           /\ bemu.w # Nil => bemu.r = {}
DefragTerminates == <>defragDone

VARIABLES lk, lv, n, cr

vars == << pc, cKey, cLease, cMeta, uKey, uLease, applied, nextRev, leaseOps, 
           gen, tKey, tLease, tMeta, lastKey, dGen, defragDone, 
           compactScheduled, compactDone, stopCompaction, snapDone, 
           boltReaders, bt, rt, bmu, srd, bemu, stack, lk, lv, n, cr >>

ProcSet == {"apply"} \cup {"committer"} \cup {"compactor"} \cup {"physc"} \cup {"hasher"} \cup {"reader"} \cup {"snapsender"} \cup {"defrag"}

Init == (* Global variables *)
        /\ cKey = {}
        /\ cLease = [k \in LeaseKeys |-> 0]
        /\ cMeta = 0
        /\ uKey = {}
        /\ uLease = [k \in LeaseKeys |-> 0]
        /\ applied = 0
        /\ nextRev = 1
        /\ leaseOps = 0
        /\ gen = 0
        /\ tKey = {}
        /\ tLease = [k \in LeaseKeys |-> 0]
        /\ tMeta = 0
        /\ lastKey = 0
        /\ dGen = 0
        /\ defragDone = FALSE
        /\ compactScheduled = FALSE
        /\ compactDone = FALSE
        /\ stopCompaction = FALSE
        /\ snapDone = FALSE
        /\ boltReaders = {}
        /\ bt = Nil
        /\ rt = NoLock
        /\ bmu = NoLock
        /\ srd = NoLock
        /\ bemu = NoLock
        (* Process apply *)
        /\ lk = Nil
        /\ lv = 0
        (* Process committer *)
        /\ n = 0
        (* Process compactor *)
        /\ cr = 1
        /\ stack = [self \in ProcSet |-> << >>]
        /\ pc = [self \in ProcSet |-> CASE self = "apply" -> "aLoop"
                                        [] self = "committer" -> "pLoop"
                                        [] self = "compactor" -> "cWait"
                                        [] self = "physc" -> "a_physc"
                                        [] self = "hasher" -> "a_hasher"
                                        [] self = "reader" -> "a_reader"
                                        [] self = "snapsender" -> "a_snapsender"
                                        [] self = "defrag" -> "dBemu"]

fc1(self) == /\ pc[self] = "fc1"
             /\ bt = Nil
             /\ bt' = self
             /\ pc' = [pc EXCEPT ![self] = "fc2"]
             /\ UNCHANGED << cKey, cLease, cMeta, uKey, uLease, applied, 
                             nextRev, leaseOps, gen, tKey, tLease, tMeta, 
                             lastKey, dGen, defragDone, compactScheduled, 
                             compactDone, stopCompaction, snapDone, 
                             boltReaders, rt, bmu, srd, bemu, stack, lk, lv, n, 
                             cr >>

fc2(self) == /\ pc[self] = "fc2"
             /\ rt.w = Nil /\ rt.p = Nil
             /\ rt' = [rt EXCEPT !.p = self]
             /\ pc' = [pc EXCEPT ![self] = "fc3"]
             /\ UNCHANGED << cKey, cLease, cMeta, uKey, uLease, applied, 
                             nextRev, leaseOps, gen, tKey, tLease, tMeta, 
                             lastKey, dGen, defragDone, compactScheduled, 
                             compactDone, stopCompaction, snapDone, 
                             boltReaders, bt, bmu, srd, bemu, stack, lk, lv, n, 
                             cr >>

fc3(self) == /\ pc[self] = "fc3"
             /\ rt.r = {}
             /\ rt' = [rt EXCEPT !.w = self, !.p = Nil]
             /\ pc' = [pc EXCEPT ![self] = "fc4"]
             /\ UNCHANGED << cKey, cLease, cMeta, uKey, uLease, applied, 
                             nextRev, leaseOps, gen, tKey, tLease, tMeta, 
                             lastKey, dGen, defragDone, compactScheduled, 
                             compactDone, stopCompaction, snapDone, 
                             boltReaders, bt, bmu, srd, bemu, stack, lk, lv, n, 
                             cr >>

fc4(self) == /\ pc[self] = "fc4"
             /\ CanR(bmu)
             /\ /\ cKey' = uKey
                /\ cLease' = uLease
                /\ cMeta' = applied
             /\ pc' = [pc EXCEPT ![self] = "fc5"]
             /\ UNCHANGED << uKey, uLease, applied, nextRev, leaseOps, gen, 
                             tKey, tLease, tMeta, lastKey, dGen, defragDone, 
                             compactScheduled, compactDone, stopCompaction, 
                             snapDone, boltReaders, bt, rt, bmu, srd, bemu, 
                             stack, lk, lv, n, cr >>

fc5(self) == /\ pc[self] = "fc5"
             /\ rt' = [rt EXCEPT !.w = Nil]
             /\ bt' = Nil
             /\ pc' = [pc EXCEPT ![self] = Head(stack[self]).pc]
             /\ stack' = [stack EXCEPT ![self] = Tail(stack[self])]
             /\ UNCHANGED << cKey, cLease, cMeta, uKey, uLease, applied, 
                             nextRev, leaseOps, gen, tKey, tLease, tMeta, 
                             lastKey, dGen, defragDone, compactScheduled, 
                             compactDone, stopCompaction, snapDone, 
                             boltReaders, bmu, srd, bemu, lk, lv, n, cr >>

ForceCommit(self) == fc1(self) \/ fc2(self) \/ fc3(self) \/ fc4(self)
                        \/ fc5(self)

aLoop == /\ pc["apply"] = "aLoop"
         /\ IF nextRev <= MaxRev \/ leaseOps < MaxLeaseOps
               \/ (CompactRev > 0 /\ ~compactScheduled) \/ (WithSnapshot /\ ~snapDone)
               THEN /\ pc' = [pc EXCEPT !["apply"] = "aBemu"]
               ELSE /\ pc' = [pc EXCEPT !["apply"] = "Done"]
         /\ UNCHANGED << cKey, cLease, cMeta, uKey, uLease, applied, nextRev, 
                         leaseOps, gen, tKey, tLease, tMeta, lastKey, dGen, 
                         defragDone, compactScheduled, compactDone, 
                         stopCompaction, snapDone, boltReaders, bt, rt, bmu, 
                         srd, bemu, stack, lk, lv, n, cr >>

aBemu == /\ pc["apply"] = "aBemu"
         /\ CanR(bemu)
         /\ \/ /\ nextRev <= MaxRev
               /\ pc' = [pc EXCEPT !["apply"] = "aPL"]
               /\ UNCHANGED <<lk, lv>>
            \/ /\ leaseOps < MaxLeaseOps
               /\ \E k \in LeaseKeys:
                    \E v \in LeaseVals:
                      /\ lk' = k
                      /\ lv' = v
               /\ pc' = [pc EXCEPT !["apply"] = "aLL"]
            \/ /\ CompactRev > 0 /\ ~compactScheduled /\ nextRev > CompactRev
               /\ pc' = [pc EXCEPT !["apply"] = "aC"]
               /\ UNCHANGED <<lk, lv>>
            \/ /\ WithSnapshot /\ ~snapDone
               /\ pc' = [pc EXCEPT !["apply"] = "aSa"]
               /\ UNCHANGED <<lk, lv>>
         /\ UNCHANGED << cKey, cLease, cMeta, uKey, uLease, applied, nextRev, 
                         leaseOps, gen, tKey, tLease, tMeta, lastKey, dGen, 
                         defragDone, compactScheduled, compactDone, 
                         stopCompaction, snapDone, boltReaders, bt, rt, bmu, 
                         srd, bemu, stack, n, cr >>

aPL == /\ pc["apply"] = "aPL"
       /\ bt = Nil
       /\ bt' = "apply"
       /\ pc' = [pc EXCEPT !["apply"] = "aP"]
       /\ UNCHANGED << cKey, cLease, cMeta, uKey, uLease, applied, nextRev, 
                       leaseOps, gen, tKey, tLease, tMeta, lastKey, dGen, 
                       defragDone, compactScheduled, compactDone, 
                       stopCompaction, snapDone, boltReaders, rt, bmu, srd, 
                       bemu, stack, lk, lv, n, cr >>

aP == /\ pc["apply"] = "aP"
      /\ uKey' = (uKey \cup {nextRev})
      /\ nextRev' = nextRev + 1
      /\ applied' = applied + 1
      /\ pc' = [pc EXCEPT !["apply"] = "aPWa"]
      /\ UNCHANGED << cKey, cLease, cMeta, uLease, leaseOps, gen, tKey, tLease, 
                      tMeta, lastKey, dGen, defragDone, compactScheduled, 
                      compactDone, stopCompaction, snapDone, boltReaders, bt, 
                      rt, bmu, srd, bemu, stack, lk, lv, n, cr >>

aPWa == /\ pc["apply"] = "aPWa"
        /\ rt.w = Nil /\ rt.p = Nil
        /\ rt' = [rt EXCEPT !.p = "apply"]
        /\ pc' = [pc EXCEPT !["apply"] = "aPWb"]
        /\ UNCHANGED << cKey, cLease, cMeta, uKey, uLease, applied, nextRev, 
                        leaseOps, gen, tKey, tLease, tMeta, lastKey, dGen, 
                        defragDone, compactScheduled, compactDone, 
                        stopCompaction, snapDone, boltReaders, bt, bmu, srd, 
                        bemu, stack, lk, lv, n, cr >>

aPWb == /\ pc["apply"] = "aPWb"
        /\ rt.r = {}
        /\ rt' = [rt EXCEPT !.w = "apply", !.p = Nil]
        /\ pc' = [pc EXCEPT !["apply"] = "aPWc"]
        /\ UNCHANGED << cKey, cLease, cMeta, uKey, uLease, applied, nextRev, 
                        leaseOps, gen, tKey, tLease, tMeta, lastKey, dGen, 
                        defragDone, compactScheduled, compactDone, 
                        stopCompaction, snapDone, boltReaders, bt, bmu, srd, 
                        bemu, stack, lk, lv, n, cr >>

aPWc == /\ pc["apply"] = "aPWc"
        /\ rt' = [rt EXCEPT !.w = Nil]
        /\ bt' = Nil
        /\ pc' = [pc EXCEPT !["apply"] = "aLoop"]
        /\ UNCHANGED << cKey, cLease, cMeta, uKey, uLease, applied, nextRev, 
                        leaseOps, gen, tKey, tLease, tMeta, lastKey, dGen, 
                        defragDone, compactScheduled, compactDone, 
                        stopCompaction, snapDone, boltReaders, bmu, srd, bemu, 
                        stack, lk, lv, n, cr >>

aLL == /\ pc["apply"] = "aLL"
       /\ bt = Nil
       /\ bt' = "apply"
       /\ pc' = [pc EXCEPT !["apply"] = "aL"]
       /\ UNCHANGED << cKey, cLease, cMeta, uKey, uLease, applied, nextRev, 
                       leaseOps, gen, tKey, tLease, tMeta, lastKey, dGen, 
                       defragDone, compactScheduled, compactDone, 
                       stopCompaction, snapDone, boltReaders, rt, bmu, srd, 
                       bemu, stack, lk, lv, n, cr >>

aL == /\ pc["apply"] = "aL"
      /\ uLease' = [uLease EXCEPT ![lk] = lv]
      /\ leaseOps' = leaseOps + 1
      /\ applied' = applied + 1
      /\ pc' = [pc EXCEPT !["apply"] = "aLWa"]
      /\ UNCHANGED << cKey, cLease, cMeta, uKey, nextRev, gen, tKey, tLease, 
                      tMeta, lastKey, dGen, defragDone, compactScheduled, 
                      compactDone, stopCompaction, snapDone, boltReaders, bt, 
                      rt, bmu, srd, bemu, stack, lk, lv, n, cr >>

aLWa == /\ pc["apply"] = "aLWa"
        /\ rt.w = Nil /\ rt.p = Nil
        /\ rt' = [rt EXCEPT !.p = "apply"]
        /\ pc' = [pc EXCEPT !["apply"] = "aLWb"]
        /\ UNCHANGED << cKey, cLease, cMeta, uKey, uLease, applied, nextRev, 
                        leaseOps, gen, tKey, tLease, tMeta, lastKey, dGen, 
                        defragDone, compactScheduled, compactDone, 
                        stopCompaction, snapDone, boltReaders, bt, bmu, srd, 
                        bemu, stack, lk, lv, n, cr >>

aLWb == /\ pc["apply"] = "aLWb"
        /\ rt.r = {}
        /\ rt' = [rt EXCEPT !.w = "apply", !.p = Nil]
        /\ pc' = [pc EXCEPT !["apply"] = "aLWc"]
        /\ UNCHANGED << cKey, cLease, cMeta, uKey, uLease, applied, nextRev, 
                        leaseOps, gen, tKey, tLease, tMeta, lastKey, dGen, 
                        defragDone, compactScheduled, compactDone, 
                        stopCompaction, snapDone, boltReaders, bt, bmu, srd, 
                        bemu, stack, lk, lv, n, cr >>

aLWc == /\ pc["apply"] = "aLWc"
        /\ IF lv = 0
              THEN /\ CanR(bmu)
                   /\ /\ cKey' = uKey
                      /\ cLease' = uLease
                      /\ cMeta' = applied
              ELSE /\ TRUE
                   /\ UNCHANGED << cKey, cLease, cMeta >>
        /\ pc' = [pc EXCEPT !["apply"] = "aLWd"]
        /\ UNCHANGED << uKey, uLease, applied, nextRev, leaseOps, gen, tKey, 
                        tLease, tMeta, lastKey, dGen, defragDone, 
                        compactScheduled, compactDone, stopCompaction, 
                        snapDone, boltReaders, bt, rt, bmu, srd, bemu, stack, 
                        lk, lv, n, cr >>

aLWd == /\ pc["apply"] = "aLWd"
        /\ rt' = [rt EXCEPT !.w = Nil]
        /\ bt' = Nil
        /\ pc' = [pc EXCEPT !["apply"] = "aLoop"]
        /\ UNCHANGED << cKey, cLease, cMeta, uKey, uLease, applied, nextRev, 
                        leaseOps, gen, tKey, tLease, tMeta, lastKey, dGen, 
                        defragDone, compactScheduled, compactDone, 
                        stopCompaction, snapDone, boltReaders, bmu, srd, bemu, 
                        stack, lk, lv, n, cr >>

aC == /\ pc["apply"] = "aC"
      /\ applied' = applied + 1
      /\ stack' = [stack EXCEPT !["apply"] = << [ procedure |->  "ForceCommit",
                                                  pc        |->  "aCs" ] >>
                                              \o stack["apply"]]
      /\ pc' = [pc EXCEPT !["apply"] = "fc1"]
      /\ UNCHANGED << cKey, cLease, cMeta, uKey, uLease, nextRev, leaseOps, 
                      gen, tKey, tLease, tMeta, lastKey, dGen, defragDone, 
                      compactScheduled, compactDone, stopCompaction, snapDone, 
                      boltReaders, bt, rt, bmu, srd, bemu, lk, lv, n, cr >>

aCs == /\ pc["apply"] = "aCs"
       /\ compactScheduled' = TRUE
       /\ pc' = [pc EXCEPT !["apply"] = "aLoop"]
       /\ UNCHANGED << cKey, cLease, cMeta, uKey, uLease, applied, nextRev, 
                       leaseOps, gen, tKey, tLease, tMeta, lastKey, dGen, 
                       defragDone, compactDone, stopCompaction, snapDone, 
                       boltReaders, bt, rt, bmu, srd, bemu, stack, lk, lv, n, 
                       cr >>

aSa == /\ pc["apply"] = "aSa"
       /\ bemu.w = Nil /\ bemu.p = Nil
       /\ bemu' = [bemu EXCEPT !.p = "apply"]
       /\ pc' = [pc EXCEPT !["apply"] = "aSb"]
       /\ UNCHANGED << cKey, cLease, cMeta, uKey, uLease, applied, nextRev, 
                       leaseOps, gen, tKey, tLease, tMeta, lastKey, dGen, 
                       defragDone, compactScheduled, compactDone, 
                       stopCompaction, snapDone, boltReaders, bt, rt, bmu, srd, 
                       stack, lk, lv, n, cr >>

aSb == /\ pc["apply"] = "aSb"
       /\ bemu.r = {}
       /\ bemu' = [bemu EXCEPT !.w = "apply", !.p = Nil]
       /\ pc' = [pc EXCEPT !["apply"] = "aSc"]
       /\ UNCHANGED << cKey, cLease, cMeta, uKey, uLease, applied, nextRev, 
                       leaseOps, gen, tKey, tLease, tMeta, lastKey, dGen, 
                       defragDone, compactScheduled, compactDone, 
                       stopCompaction, snapDone, boltReaders, bt, rt, bmu, srd, 
                       stack, lk, lv, n, cr >>

aSc == /\ pc["apply"] = "aSc"
       /\ stopCompaction' = TRUE
       /\ pc' = [pc EXCEPT !["apply"] = "aSd"]
       /\ UNCHANGED << cKey, cLease, cMeta, uKey, uLease, applied, nextRev, 
                       leaseOps, gen, tKey, tLease, tMeta, lastKey, dGen, 
                       defragDone, compactScheduled, compactDone, snapDone, 
                       boltReaders, bt, rt, bmu, srd, bemu, stack, lk, lv, n, 
                       cr >>

aSd == /\ pc["apply"] = "aSd"
       /\ pc["compactor"] \in {"cWait", "Done"}
       /\ gen' = gen + 1
       /\ pc' = [pc EXCEPT !["apply"] = "aSe"]
       /\ UNCHANGED << cKey, cLease, cMeta, uKey, uLease, applied, nextRev, 
                       leaseOps, tKey, tLease, tMeta, lastKey, dGen, 
                       defragDone, compactScheduled, compactDone, 
                       stopCompaction, snapDone, boltReaders, bt, rt, bmu, srd, 
                       bemu, stack, lk, lv, n, cr >>

aSe == /\ pc["apply"] = "aSe"
       /\ bemu' = [bemu EXCEPT !.w = Nil]
       /\ snapDone' = TRUE
       /\ pc' = [pc EXCEPT !["apply"] = "aLoop"]
       /\ UNCHANGED << cKey, cLease, cMeta, uKey, uLease, applied, nextRev, 
                       leaseOps, gen, tKey, tLease, tMeta, lastKey, dGen, 
                       defragDone, compactScheduled, compactDone, 
                       stopCompaction, boltReaders, bt, rt, bmu, srd, stack, 
                       lk, lv, n, cr >>

apply == aLoop \/ aBemu \/ aPL \/ aP \/ aPWa \/ aPWb \/ aPWc \/ aLL \/ aL
            \/ aLWa \/ aLWb \/ aLWc \/ aLWd \/ aC \/ aCs \/ aSa \/ aSb
            \/ aSc \/ aSd \/ aSe

pLoop == /\ pc["committer"] = "pLoop"
         /\ IF n < NumCommits
               THEN /\ n' = n + 1
                    /\ stack' = [stack EXCEPT !["committer"] = << [ procedure |->  "ForceCommit",
                                                                    pc        |->  "pLoop" ] >>
                                                                \o stack["committer"]]
                    /\ pc' = [pc EXCEPT !["committer"] = "fc1"]
               ELSE /\ pc' = [pc EXCEPT !["committer"] = "Done"]
                    /\ UNCHANGED << stack, n >>
         /\ UNCHANGED << cKey, cLease, cMeta, uKey, uLease, applied, nextRev, 
                         leaseOps, gen, tKey, tLease, tMeta, lastKey, dGen, 
                         defragDone, compactScheduled, compactDone, 
                         stopCompaction, snapDone, boltReaders, bt, rt, bmu, 
                         srd, bemu, lk, lv, cr >>

committer == pLoop

cWait == /\ pc["compactor"] = "cWait"
         /\ compactScheduled \/ stopCompaction
         /\ IF stopCompaction
               THEN /\ IF ReleaseQueuedCompaction
                          THEN /\ compactDone' = TRUE
                          ELSE /\ TRUE
                               /\ UNCHANGED compactDone
                    /\ pc' = [pc EXCEPT !["compactor"] = "Done"]
               ELSE /\ pc' = [pc EXCEPT !["compactor"] = "cSR"]
                    /\ UNCHANGED compactDone
         /\ UNCHANGED << cKey, cLease, cMeta, uKey, uLease, applied, nextRev, 
                         leaseOps, gen, tKey, tLease, tMeta, lastKey, dGen, 
                         defragDone, compactScheduled, stopCompaction, 
                         snapDone, boltReaders, bt, rt, bmu, srd, bemu, stack, 
                         lk, lv, n, cr >>

cSR == /\ pc["compactor"] = "cSR"
       /\ IF CompactionTakesLock
             THEN /\ CanR(srd)
                  /\ srd' = [srd EXCEPT !.r = srd.r \cup {"compactor"}]
             ELSE /\ TRUE
                  /\ srd' = srd
       /\ pc' = [pc EXCEPT !["compactor"] = "cLoop"]
       /\ UNCHANGED << cKey, cLease, cMeta, uKey, uLease, applied, nextRev, 
                       leaseOps, gen, tKey, tLease, tMeta, lastKey, dGen, 
                       defragDone, compactScheduled, compactDone, 
                       stopCompaction, snapDone, boltReaders, bt, rt, bmu, 
                       bemu, stack, lk, lv, n, cr >>

cLoop == /\ pc["compactor"] = "cLoop"
         /\ IF cr < CompactRev
               THEN /\ pc' = [pc EXCEPT !["compactor"] = "cBt"]
               ELSE /\ pc' = [pc EXCEPT !["compactor"] = "cEnd"]
         /\ UNCHANGED << cKey, cLease, cMeta, uKey, uLease, applied, nextRev, 
                         leaseOps, gen, tKey, tLease, tMeta, lastKey, dGen, 
                         defragDone, compactScheduled, compactDone, 
                         stopCompaction, snapDone, boltReaders, bt, rt, bmu, 
                         srd, bemu, stack, lk, lv, n, cr >>

cBt == /\ pc["compactor"] = "cBt"
       /\ bt = Nil
       /\ bt' = "compactor"
       /\ pc' = [pc EXCEPT !["compactor"] = "cDel"]
       /\ UNCHANGED << cKey, cLease, cMeta, uKey, uLease, applied, nextRev, 
                       leaseOps, gen, tKey, tLease, tMeta, lastKey, dGen, 
                       defragDone, compactScheduled, compactDone, 
                       stopCompaction, snapDone, boltReaders, rt, bmu, srd, 
                       bemu, stack, lk, lv, n, cr >>

cDel == /\ pc["compactor"] = "cDel"
        /\ uKey' = uKey \ {cr}
        /\ cr' = cr + 1
        /\ pc' = [pc EXCEPT !["compactor"] = "cWa"]
        /\ UNCHANGED << cKey, cLease, cMeta, uLease, applied, nextRev, 
                        leaseOps, gen, tKey, tLease, tMeta, lastKey, dGen, 
                        defragDone, compactScheduled, compactDone, 
                        stopCompaction, snapDone, boltReaders, bt, rt, bmu, 
                        srd, bemu, stack, lk, lv, n >>

cWa == /\ pc["compactor"] = "cWa"
       /\ rt.w = Nil /\ rt.p = Nil
       /\ rt' = [rt EXCEPT !.p = "compactor"]
       /\ pc' = [pc EXCEPT !["compactor"] = "cWb"]
       /\ UNCHANGED << cKey, cLease, cMeta, uKey, uLease, applied, nextRev, 
                       leaseOps, gen, tKey, tLease, tMeta, lastKey, dGen, 
                       defragDone, compactScheduled, compactDone, 
                       stopCompaction, snapDone, boltReaders, bt, bmu, srd, 
                       bemu, stack, lk, lv, n, cr >>

cWb == /\ pc["compactor"] = "cWb"
       /\ rt.r = {}
       /\ rt' = [rt EXCEPT !.w = "compactor", !.p = Nil]
       /\ pc' = [pc EXCEPT !["compactor"] = "cCm"]
       /\ UNCHANGED << cKey, cLease, cMeta, uKey, uLease, applied, nextRev, 
                       leaseOps, gen, tKey, tLease, tMeta, lastKey, dGen, 
                       defragDone, compactScheduled, compactDone, 
                       stopCompaction, snapDone, boltReaders, bt, bmu, srd, 
                       bemu, stack, lk, lv, n, cr >>

cCm == /\ pc["compactor"] = "cCm"
       /\ CanR(bmu)
       /\ /\ cKey' = uKey
          /\ cLease' = uLease
          /\ cMeta' = applied
       /\ pc' = [pc EXCEPT !["compactor"] = "cRel"]
       /\ UNCHANGED << uKey, uLease, applied, nextRev, leaseOps, gen, tKey, 
                       tLease, tMeta, lastKey, dGen, defragDone, 
                       compactScheduled, compactDone, stopCompaction, snapDone, 
                       boltReaders, bt, rt, bmu, srd, bemu, stack, lk, lv, n, 
                       cr >>

cRel == /\ pc["compactor"] = "cRel"
        /\ rt' = [rt EXCEPT !.w = Nil]
        /\ bt' = Nil
        /\ pc' = [pc EXCEPT !["compactor"] = "cSleep"]
        /\ UNCHANGED << cKey, cLease, cMeta, uKey, uLease, applied, nextRev, 
                        leaseOps, gen, tKey, tLease, tMeta, lastKey, dGen, 
                        defragDone, compactScheduled, compactDone, 
                        stopCompaction, snapDone, boltReaders, bmu, srd, bemu, 
                        stack, lk, lv, n, cr >>

cSleep == /\ pc["compactor"] = "cSleep"
          /\ IF stopCompaction
                THEN /\ pc' = [pc EXCEPT !["compactor"] = "cEnd"]
                ELSE /\ pc' = [pc EXCEPT !["compactor"] = "cLoop"]
          /\ UNCHANGED << cKey, cLease, cMeta, uKey, uLease, applied, nextRev, 
                          leaseOps, gen, tKey, tLease, tMeta, lastKey, dGen, 
                          defragDone, compactScheduled, compactDone, 
                          stopCompaction, snapDone, boltReaders, bt, rt, bmu, 
                          srd, bemu, stack, lk, lv, n, cr >>

cEnd == /\ pc["compactor"] = "cEnd"
        /\ IF CompactionTakesLock
              THEN /\ srd' = [srd EXCEPT !.r = srd.r \ {"compactor"}]
              ELSE /\ TRUE
                   /\ srd' = srd
        /\ compactDone' = TRUE
        /\ pc' = [pc EXCEPT !["compactor"] = "Done"]
        /\ UNCHANGED << cKey, cLease, cMeta, uKey, uLease, applied, nextRev, 
                        leaseOps, gen, tKey, tLease, tMeta, lastKey, dGen, 
                        defragDone, compactScheduled, stopCompaction, snapDone, 
                        boltReaders, bt, rt, bmu, bemu, stack, lk, lv, n, cr >>

compactor == cWait \/ cSR \/ cLoop \/ cBt \/ cDel \/ cWa \/ cWb \/ cCm
                \/ cRel \/ cSleep \/ cEnd

a_physc == /\ pc["physc"] = "a_physc"
           /\ IF "physc" \notin Aux
                 THEN /\ pc' = [pc EXCEPT !["physc"] = "Done"]
                 ELSE /\ pc' = [pc EXCEPT !["physc"] = "phW"]
           /\ UNCHANGED << cKey, cLease, cMeta, uKey, uLease, applied, nextRev, 
                           leaseOps, gen, tKey, tLease, tMeta, lastKey, dGen, 
                           defragDone, compactScheduled, compactDone, 
                           stopCompaction, snapDone, boltReaders, bt, rt, bmu, 
                           srd, bemu, stack, lk, lv, n, cr >>

phW == /\ pc["physc"] = "phW"
       /\ compactDone \/ CompactRev = 0
       /\ pc' = [pc EXCEPT !["physc"] = "phB"]
       /\ UNCHANGED << cKey, cLease, cMeta, uKey, uLease, applied, nextRev, 
                       leaseOps, gen, tKey, tLease, tMeta, lastKey, dGen, 
                       defragDone, compactScheduled, compactDone, 
                       stopCompaction, snapDone, boltReaders, bt, rt, bmu, srd, 
                       bemu, stack, lk, lv, n, cr >>

phB == /\ pc["physc"] = "phB"
       /\ CanR(bemu)
       /\ bemu' = [bemu EXCEPT !.r = bemu.r \cup {"physc"}]
       /\ pc' = [pc EXCEPT !["physc"] = "phF"]
       /\ UNCHANGED << cKey, cLease, cMeta, uKey, uLease, applied, nextRev, 
                       leaseOps, gen, tKey, tLease, tMeta, lastKey, dGen, 
                       defragDone, compactScheduled, compactDone, 
                       stopCompaction, snapDone, boltReaders, bt, rt, bmu, srd, 
                       stack, lk, lv, n, cr >>

phF == /\ pc["physc"] = "phF"
       /\ stack' = [stack EXCEPT !["physc"] = << [ procedure |->  "ForceCommit",
                                                   pc        |->  "phR" ] >>
                                               \o stack["physc"]]
       /\ pc' = [pc EXCEPT !["physc"] = "fc1"]
       /\ UNCHANGED << cKey, cLease, cMeta, uKey, uLease, applied, nextRev, 
                       leaseOps, gen, tKey, tLease, tMeta, lastKey, dGen, 
                       defragDone, compactScheduled, compactDone, 
                       stopCompaction, snapDone, boltReaders, bt, rt, bmu, srd, 
                       bemu, lk, lv, n, cr >>

phR == /\ pc["physc"] = "phR"
       /\ bemu' = [bemu EXCEPT !.r = bemu.r \ {"physc"}]
       /\ pc' = [pc EXCEPT !["physc"] = "Done"]
       /\ UNCHANGED << cKey, cLease, cMeta, uKey, uLease, applied, nextRev, 
                       leaseOps, gen, tKey, tLease, tMeta, lastKey, dGen, 
                       defragDone, compactScheduled, compactDone, 
                       stopCompaction, snapDone, boltReaders, bt, rt, bmu, srd, 
                       stack, lk, lv, n, cr >>

physc == a_physc \/ phW \/ phB \/ phF \/ phR

a_hasher == /\ pc["hasher"] = "a_hasher"
            /\ IF "hasher" \notin Aux
                  THEN /\ pc' = [pc EXCEPT !["hasher"] = "Done"]
                  ELSE /\ pc' = [pc EXCEPT !["hasher"] = "hF"]
            /\ UNCHANGED << cKey, cLease, cMeta, uKey, uLease, applied, 
                            nextRev, leaseOps, gen, tKey, tLease, tMeta, 
                            lastKey, dGen, defragDone, compactScheduled, 
                            compactDone, stopCompaction, snapDone, boltReaders, 
                            bt, rt, bmu, srd, bemu, stack, lk, lv, n, cr >>

hF == /\ pc["hasher"] = "hF"
      /\ stack' = [stack EXCEPT !["hasher"] = << [ procedure |->  "ForceCommit",
                                                   pc        |->  "hM" ] >>
                                               \o stack["hasher"]]
      /\ pc' = [pc EXCEPT !["hasher"] = "fc1"]
      /\ UNCHANGED << cKey, cLease, cMeta, uKey, uLease, applied, nextRev, 
                      leaseOps, gen, tKey, tLease, tMeta, lastKey, dGen, 
                      defragDone, compactScheduled, compactDone, 
                      stopCompaction, snapDone, boltReaders, bt, rt, bmu, srd, 
                      bemu, lk, lv, n, cr >>

hM == /\ pc["hasher"] = "hM"
      /\ CanR(bmu)
      /\ bmu' = [bmu EXCEPT !.r = bmu.r \cup {"hasher"}]
      /\ boltReaders' = (boltReaders \cup {"hasher"})
      /\ pc' = [pc EXCEPT !["hasher"] = "hV"]
      /\ UNCHANGED << cKey, cLease, cMeta, uKey, uLease, applied, nextRev, 
                      leaseOps, gen, tKey, tLease, tMeta, lastKey, dGen, 
                      defragDone, compactScheduled, compactDone, 
                      stopCompaction, snapDone, bt, rt, srd, bemu, stack, lk, 
                      lv, n, cr >>

hV == /\ pc["hasher"] = "hV"
      /\ bmu' = [bmu EXCEPT !.r = bmu.r \ {"hasher"}]
      /\ boltReaders' = boltReaders \ {"hasher"}
      /\ pc' = [pc EXCEPT !["hasher"] = "Done"]
      /\ UNCHANGED << cKey, cLease, cMeta, uKey, uLease, applied, nextRev, 
                      leaseOps, gen, tKey, tLease, tMeta, lastKey, dGen, 
                      defragDone, compactScheduled, compactDone, 
                      stopCompaction, snapDone, bt, rt, srd, bemu, stack, lk, 
                      lv, n, cr >>

hasher == a_hasher \/ hF \/ hM \/ hV

a_reader == /\ pc["reader"] = "a_reader"
            /\ IF "reader" \notin Aux
                  THEN /\ pc' = [pc EXCEPT !["reader"] = "Done"]
                  ELSE /\ pc' = [pc EXCEPT !["reader"] = "rR"]
            /\ UNCHANGED << cKey, cLease, cMeta, uKey, uLease, applied, 
                            nextRev, leaseOps, gen, tKey, tLease, tMeta, 
                            lastKey, dGen, defragDone, compactScheduled, 
                            compactDone, stopCompaction, snapDone, boltReaders, 
                            bt, rt, bmu, srd, bemu, stack, lk, lv, n, cr >>

rR == /\ pc["reader"] = "rR"
      /\ CanR(rt)
      /\ rt' = [rt EXCEPT !.r = rt.r \cup {"reader"}]
      /\ pc' = [pc EXCEPT !["reader"] = "rD"]
      /\ UNCHANGED << cKey, cLease, cMeta, uKey, uLease, applied, nextRev, 
                      leaseOps, gen, tKey, tLease, tMeta, lastKey, dGen, 
                      defragDone, compactScheduled, compactDone, 
                      stopCompaction, snapDone, boltReaders, bt, bmu, srd, 
                      bemu, stack, lk, lv, n, cr >>

rD == /\ pc["reader"] = "rD"
      /\ rt' = [rt EXCEPT !.r = rt.r \ {"reader"}]
      /\ pc' = [pc EXCEPT !["reader"] = "Done"]
      /\ UNCHANGED << cKey, cLease, cMeta, uKey, uLease, applied, nextRev, 
                      leaseOps, gen, tKey, tLease, tMeta, lastKey, dGen, 
                      defragDone, compactScheduled, compactDone, 
                      stopCompaction, snapDone, boltReaders, bt, bmu, srd, 
                      bemu, stack, lk, lv, n, cr >>

reader == a_reader \/ rR \/ rD

a_snapsender == /\ pc["snapsender"] = "a_snapsender"
                /\ IF "snapsender" \notin Aux
                      THEN /\ pc' = [pc EXCEPT !["snapsender"] = "Done"]
                      ELSE /\ pc' = [pc EXCEPT !["snapsender"] = "sB"]
                /\ UNCHANGED << cKey, cLease, cMeta, uKey, uLease, applied, 
                                nextRev, leaseOps, gen, tKey, tLease, tMeta, 
                                lastKey, dGen, defragDone, compactScheduled, 
                                compactDone, stopCompaction, snapDone, 
                                boltReaders, bt, rt, bmu, srd, bemu, stack, lk, 
                                lv, n, cr >>

sB == /\ pc["snapsender"] = "sB"
      /\ CanR(bemu)
      /\ pc' = [pc EXCEPT !["snapsender"] = "sF"]
      /\ UNCHANGED << cKey, cLease, cMeta, uKey, uLease, applied, nextRev, 
                      leaseOps, gen, tKey, tLease, tMeta, lastKey, dGen, 
                      defragDone, compactScheduled, compactDone, 
                      stopCompaction, snapDone, boltReaders, bt, rt, bmu, srd, 
                      bemu, stack, lk, lv, n, cr >>

sF == /\ pc["snapsender"] = "sF"
      /\ stack' = [stack EXCEPT !["snapsender"] = << [ procedure |->  "ForceCommit",
                                                       pc        |->  "sM" ] >>
                                                   \o stack["snapsender"]]
      /\ pc' = [pc EXCEPT !["snapsender"] = "fc1"]
      /\ UNCHANGED << cKey, cLease, cMeta, uKey, uLease, applied, nextRev, 
                      leaseOps, gen, tKey, tLease, tMeta, lastKey, dGen, 
                      defragDone, compactScheduled, compactDone, 
                      stopCompaction, snapDone, boltReaders, bt, rt, bmu, srd, 
                      bemu, lk, lv, n, cr >>

sM == /\ pc["snapsender"] = "sM"
      /\ CanR(bmu)
      /\ boltReaders' = (boltReaders \cup {"snapsender"})
      /\ pc' = [pc EXCEPT !["snapsender"] = "sS"]
      /\ UNCHANGED << cKey, cLease, cMeta, uKey, uLease, applied, nextRev, 
                      leaseOps, gen, tKey, tLease, tMeta, lastKey, dGen, 
                      defragDone, compactScheduled, compactDone, 
                      stopCompaction, snapDone, bt, rt, bmu, srd, bemu, stack, 
                      lk, lv, n, cr >>

sS == /\ pc["snapsender"] = "sS"
      /\ boltReaders' = boltReaders \ {"snapsender"}
      /\ pc' = [pc EXCEPT !["snapsender"] = "Done"]
      /\ UNCHANGED << cKey, cLease, cMeta, uKey, uLease, applied, nextRev, 
                      leaseOps, gen, tKey, tLease, tMeta, lastKey, dGen, 
                      defragDone, compactScheduled, compactDone, 
                      stopCompaction, snapDone, bt, rt, bmu, srd, bemu, stack, 
                      lk, lv, n, cr >>

snapsender == a_snapsender \/ sB \/ sF \/ sM \/ sS

dBemu == /\ pc["defrag"] = "dBemu"
         /\ IF DefragHoldsBemu
               THEN /\ CanR(bemu)
                    /\ bemu' = [bemu EXCEPT !.r = bemu.r \cup {"defrag"}]
               ELSE /\ TRUE
                    /\ bemu' = bemu
         /\ dGen' = gen
         /\ pc' = [pc EXCEPT !["defrag"] = "dSa"]
         /\ UNCHANGED << cKey, cLease, cMeta, uKey, uLease, applied, nextRev, 
                         leaseOps, gen, tKey, tLease, tMeta, lastKey, 
                         defragDone, compactScheduled, compactDone, 
                         stopCompaction, snapDone, boltReaders, bt, rt, bmu, 
                         srd, stack, lk, lv, n, cr >>

dSa == /\ pc["defrag"] = "dSa"
       /\ srd.w = Nil /\ srd.p = Nil
       /\ srd' = [srd EXCEPT !.p = "defrag"]
       /\ pc' = [pc EXCEPT !["defrag"] = "dSb"]
       /\ UNCHANGED << cKey, cLease, cMeta, uKey, uLease, applied, nextRev, 
                       leaseOps, gen, tKey, tLease, tMeta, lastKey, dGen, 
                       defragDone, compactScheduled, compactDone, 
                       stopCompaction, snapDone, boltReaders, bt, rt, bmu, 
                       bemu, stack, lk, lv, n, cr >>

dSb == /\ pc["defrag"] = "dSb"
       /\ srd.r = {}
       /\ srd' = [srd EXCEPT !.w = "defrag", !.p = Nil]
       /\ pc' = [pc EXCEPT !["defrag"] = "dFc"]
       /\ UNCHANGED << cKey, cLease, cMeta, uKey, uLease, applied, nextRev, 
                       leaseOps, gen, tKey, tLease, tMeta, lastKey, dGen, 
                       defragDone, compactScheduled, compactDone, 
                       stopCompaction, snapDone, boltReaders, bt, rt, bmu, 
                       bemu, stack, lk, lv, n, cr >>

dFc == /\ pc["defrag"] = "dFc"
       /\ stack' = [stack EXCEPT !["defrag"] = << [ procedure |->  "ForceCommit",
                                                    pc        |->  "dP1" ] >>
                                                \o stack["defrag"]]
       /\ pc' = [pc EXCEPT !["defrag"] = "fc1"]
       /\ UNCHANGED << cKey, cLease, cMeta, uKey, uLease, applied, nextRev, 
                       leaseOps, gen, tKey, tLease, tMeta, lastKey, dGen, 
                       defragDone, compactScheduled, compactDone, 
                       stopCompaction, snapDone, boltReaders, bt, rt, bmu, srd, 
                       bemu, lk, lv, n, cr >>

dP1 == /\ pc["defrag"] = "dP1"
       /\ CanR(bmu)
       /\ tKey' = cKey
       /\ lastKey' = (IF cKey = {} THEN 0 ELSE Max(cKey))
       /\ pc' = [pc EXCEPT !["defrag"] = "dBt"]
       /\ UNCHANGED << cKey, cLease, cMeta, uKey, uLease, applied, nextRev, 
                       leaseOps, gen, tLease, tMeta, dGen, defragDone, 
                       compactScheduled, compactDone, stopCompaction, snapDone, 
                       boltReaders, bt, rt, bmu, srd, bemu, stack, lk, lv, n, 
                       cr >>

dBt == /\ pc["defrag"] = "dBt"
       /\ bt = Nil
       /\ bt' = "defrag"
       /\ pc' = [pc EXCEPT !["defrag"] = "dMa"]
       /\ UNCHANGED << cKey, cLease, cMeta, uKey, uLease, applied, nextRev, 
                       leaseOps, gen, tKey, tLease, tMeta, lastKey, dGen, 
                       defragDone, compactScheduled, compactDone, 
                       stopCompaction, snapDone, boltReaders, rt, bmu, srd, 
                       bemu, stack, lk, lv, n, cr >>

dMa == /\ pc["defrag"] = "dMa"
       /\ bmu.w = Nil /\ bmu.p = Nil
       /\ bmu' = [bmu EXCEPT !.p = "defrag"]
       /\ pc' = [pc EXCEPT !["defrag"] = "dMb"]
       /\ UNCHANGED << cKey, cLease, cMeta, uKey, uLease, applied, nextRev, 
                       leaseOps, gen, tKey, tLease, tMeta, lastKey, dGen, 
                       defragDone, compactScheduled, compactDone, 
                       stopCompaction, snapDone, boltReaders, bt, rt, srd, 
                       bemu, stack, lk, lv, n, cr >>

dMb == /\ pc["defrag"] = "dMb"
       /\ bmu.r = {}
       /\ bmu' = [bmu EXCEPT !.w = "defrag", !.p = Nil]
       /\ pc' = [pc EXCEPT !["defrag"] = "dRa"]
       /\ UNCHANGED << cKey, cLease, cMeta, uKey, uLease, applied, nextRev, 
                       leaseOps, gen, tKey, tLease, tMeta, lastKey, dGen, 
                       defragDone, compactScheduled, compactDone, 
                       stopCompaction, snapDone, boltReaders, bt, rt, srd, 
                       bemu, stack, lk, lv, n, cr >>

dRa == /\ pc["defrag"] = "dRa"
       /\ rt.w = Nil /\ rt.p = Nil
       /\ rt' = [rt EXCEPT !.p = "defrag"]
       /\ pc' = [pc EXCEPT !["defrag"] = "dRb"]
       /\ UNCHANGED << cKey, cLease, cMeta, uKey, uLease, applied, nextRev, 
                       leaseOps, gen, tKey, tLease, tMeta, lastKey, dGen, 
                       defragDone, compactScheduled, compactDone, 
                       stopCompaction, snapDone, boltReaders, bt, bmu, srd, 
                       bemu, stack, lk, lv, n, cr >>

dRb == /\ pc["defrag"] = "dRb"
       /\ rt.r = {}
       /\ rt' = [rt EXCEPT !.w = "defrag", !.p = Nil]
       /\ pc' = [pc EXCEPT !["defrag"] = "dCm"]
       /\ UNCHANGED << cKey, cLease, cMeta, uKey, uLease, applied, nextRev, 
                       leaseOps, gen, tKey, tLease, tMeta, lastKey, dGen, 
                       defragDone, compactScheduled, compactDone, 
                       stopCompaction, snapDone, boltReaders, bt, bmu, srd, 
                       bemu, stack, lk, lv, n, cr >>

dCm == /\ pc["defrag"] = "dCm"
       /\ /\ cKey' = uKey
          /\ cLease' = uLease
          /\ cMeta' = applied
       /\ pc' = [pc EXCEPT !["defrag"] = "dCu"]
       /\ UNCHANGED << uKey, uLease, applied, nextRev, leaseOps, gen, tKey, 
                       tLease, tMeta, lastKey, dGen, defragDone, 
                       compactScheduled, compactDone, stopCompaction, snapDone, 
                       boltReaders, bt, rt, bmu, srd, bemu, stack, lk, lv, n, 
                       cr >>

dCu == /\ pc["defrag"] = "dCu"
       /\ /\ tKey' = (tKey \cup {r \in cKey : r > lastKey})
          /\ tLease' = cLease
          /\ tMeta' = cMeta
       /\ pc' = [pc EXCEPT !["defrag"] = "dChk"]
       /\ UNCHANGED << cKey, cLease, cMeta, uKey, uLease, applied, nextRev, 
                       leaseOps, gen, lastKey, dGen, defragDone, 
                       compactScheduled, compactDone, stopCompaction, snapDone, 
                       boltReaders, bt, rt, bmu, srd, bemu, stack, lk, lv, n, 
                       cr >>

dChk == /\ pc["defrag"] = "dChk"
        /\ Assert(CopyMatches, "Failure of assertion at line 231, column 8.")
        /\ Assert(dGen = gen, "Failure of assertion at line 232, column 8.")
        /\ pc' = [pc EXCEPT !["defrag"] = "dCl"]
        /\ UNCHANGED << cKey, cLease, cMeta, uKey, uLease, applied, nextRev, 
                        leaseOps, gen, tKey, tLease, tMeta, lastKey, dGen, 
                        defragDone, compactScheduled, compactDone, 
                        stopCompaction, snapDone, boltReaders, bt, rt, bmu, 
                        srd, bemu, stack, lk, lv, n, cr >>

dCl == /\ pc["defrag"] = "dCl"
       /\ boltReaders = {}
       /\ pc' = [pc EXCEPT !["defrag"] = "dRel"]
       /\ UNCHANGED << cKey, cLease, cMeta, uKey, uLease, applied, nextRev, 
                       leaseOps, gen, tKey, tLease, tMeta, lastKey, dGen, 
                       defragDone, compactScheduled, compactDone, 
                       stopCompaction, snapDone, boltReaders, bt, rt, bmu, srd, 
                       bemu, stack, lk, lv, n, cr >>

dRel == /\ pc["defrag"] = "dRel"
        /\ rt' = [rt EXCEPT !.w = Nil]
        /\ bmu' = [bmu EXCEPT !.w = Nil]
        /\ bt' = Nil
        /\ srd' = [srd EXCEPT !.w = Nil]
        /\ pc' = [pc EXCEPT !["defrag"] = "dEnd"]
        /\ UNCHANGED << cKey, cLease, cMeta, uKey, uLease, applied, nextRev, 
                        leaseOps, gen, tKey, tLease, tMeta, lastKey, dGen, 
                        defragDone, compactScheduled, compactDone, 
                        stopCompaction, snapDone, boltReaders, bemu, stack, lk, 
                        lv, n, cr >>

dEnd == /\ pc["defrag"] = "dEnd"
        /\ IF DefragHoldsBemu
              THEN /\ bemu' = [bemu EXCEPT !.r = bemu.r \ {"defrag"}]
              ELSE /\ TRUE
                   /\ bemu' = bemu
        /\ defragDone' = TRUE
        /\ pc' = [pc EXCEPT !["defrag"] = "Done"]
        /\ UNCHANGED << cKey, cLease, cMeta, uKey, uLease, applied, nextRev, 
                        leaseOps, gen, tKey, tLease, tMeta, lastKey, dGen, 
                        compactScheduled, compactDone, stopCompaction, 
                        snapDone, boltReaders, bt, rt, bmu, srd, stack, lk, lv, 
                        n, cr >>

defrag == dBemu \/ dSa \/ dSb \/ dFc \/ dP1 \/ dBt \/ dMa \/ dMb \/ dRa
             \/ dRb \/ dCm \/ dCu \/ dChk \/ dCl \/ dRel \/ dEnd

(* Allow infinite stuttering to prevent deadlock on termination. *)
Terminating == /\ \A self \in ProcSet: pc[self] = "Done"
               /\ UNCHANGED vars

Next == apply \/ committer \/ compactor \/ physc \/ hasher \/ reader
           \/ snapsender \/ defrag
           \/ (\E self \in ProcSet: ForceCommit(self))
           \/ Terminating

Spec == /\ Init /\ [][Next]_vars
        /\ WF_vars(apply) /\ WF_vars(ForceCommit("apply"))
        /\ WF_vars(committer) /\ WF_vars(ForceCommit("committer"))
        /\ WF_vars(compactor)
        /\ WF_vars(physc) /\ WF_vars(ForceCommit("physc"))
        /\ WF_vars(hasher) /\ WF_vars(ForceCommit("hasher"))
        /\ WF_vars(reader)
        /\ WF_vars(snapsender) /\ WF_vars(ForceCommit("snapsender"))
        /\ WF_vars(defrag) /\ WF_vars(ForceCommit("defrag"))

Termination == <>(\A self \in ProcSet: pc[self] = "Done")

\* END TRANSLATION 
=============================================================================
