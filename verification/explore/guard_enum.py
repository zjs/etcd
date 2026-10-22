#!/usr/bin/env python3
# Enumerate StrictReconfigCheck guard outcomes on small clusters, comparing an
# up-to-date membership view with a view one change behind (hypothesis H3).
# Guard formulas copied from server.go, membership/cluster.go and util.go at bf9cadf.
# Usage: python3 -I verification/explore/guard_enum.py
import itertools
def q(n): return n//2+1

def guard(op, V, L, alive, started, P):
    """V voters, L learners in proposer P's view. connected(x) == alive[x] (steady state, >HealthInterval)."""
    conn = lambda xs: sum(1 for x in xs if x==P or alive.get(x,False))
    kind, x = op
    if kind=='addv':
        nm, ns = len(V)+1, sum(1 for v in V if started.get(v,False))
        if not ((ns==1 and nm==2) or ns >= q(nm)): return False
        return len(V)==1 or conn(V) >= q(len(V)+1)
    if kind=='addl':
        return len(V)==1 or conn(V) >= q(len(V)+1)
    if kind=='rm':
        if x in L: return True
        if x not in V: return False  # validation would reject anyway
        rest=[v for v in V if v!=x]
        if sum(1 for v in rest if started.get(v,False)) < q(len(rest)): return False
        if x!=P and not alive.get(x,False): return True
        return conn(V)-1 >= q(len(V)-1)
    if kind=='promote':
        if x not in L: return False
        # learner readiness assumed (Match caught up)
        return sum(1 for v in V if started.get(v,False))+1 >= q(len(V)+1)

def apply(op, V, L):
    kind,x=op; V=list(V); L=list(L)
    if kind=='addv': V.append(x)
    elif kind=='addl': L.append(x)
    elif kind=='rm':
        if x in V: V.remove(x)
        if x in L: L.remove(x)
    elif kind=='promote': L.remove(x); V.append(x)
    return V,L

def safe(V, alive): return sum(1 for v in V if alive.get(v,False)) >= q(len(V))

found=[]
for nv in range(1,6):
  for nl in range(0,2):
    V0=[f"v{i}" for i in range(nv)]; L0=[f"l{i}" for i in range(nl)]
    new=["n0","n1"]
    allm=V0+L0+new
    for alivebits in itertools.product([False,True], repeat=len(allm)):
      alive=dict(zip(allm,alivebits))
      started={m:True for m in V0+L0}  # existing members have published names; new ones haven't
      if not safe(V0,alive): continue
      ops1=[('addv','n0'),('addl','n0')]+[('rm',m) for m in V0+L0]+[('promote',m) for m in L0]
      for op1 in ops1:
        for P1 in V0:
          if not alive[P1] or not guard(op1,V0,L0,alive,started,P1): continue
          V1,L1=apply(op1,V0,L0)
          if not safe(V1,alive): continue   # op1 alone already unsafe: that's H2-like, not H3
          ops2=[('addv','n1'),('addl','n1')]+[('rm',m) for m in V1+L1]+[('promote',m) for m in L1]
          for op2 in ops2:
            V2,L2=apply(op2,V1,L1)
            if safe(V2,alive): continue
            for P2 in V0:
              if not alive[P2] or P2 not in V1: continue
              fresh=guard(op2,V1,L1,alive,started,P2)
              stale=guard(op2,V0,L0,alive,started,P2)
              if stale and not fresh:
                found.append((nv,nl,op1,P1,op2,P2,{k:v for k,v in alive.items()},V2))
found=[f for f in found if f[3]!=f[5]]
print(len(found))
import collections; print(collections.Counter((f[0],f[2][0],f[4][0]) for f in found))
seen=set()
for f in found:
  key=(f[0],f[1],f[2][0],f[4][0])
  if key in seen: continue
  seen.add(key); print(f)
