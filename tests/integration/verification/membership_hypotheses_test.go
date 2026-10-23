// Copyright 2026 The etcd Authors
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

//go:build verification

// Package verification holds tests that check hypotheses from
// verification/membership-map.md against a real in-process cluster.
//
// Each test fails while the behavior it reproduces exists. They are behind
// the "verification" build tag so they don't run with the normal suite:
//
//	go test -tags verification ./integration/verification/ -v
package verification

import (
	"context"
	"os"
	"path/filepath"
	"sort"
	"testing"
	"time"

	"github.com/stretchr/testify/require"
	"go.uber.org/zap/zaptest"

	"go.etcd.io/etcd/client/pkg/v3/types"
	clientv3 "go.etcd.io/etcd/client/v3"
	"go.etcd.io/etcd/server/v3/storage/schema"
	"go.etcd.io/etcd/tests/v3/framework/integration"
)

// memberView is one member's local view of cluster membership.
type memberView struct {
	Members  []string // "id" or "id(learner)", sorted
	Voters   []uint64 // persisted raft ConfState
	Learners []uint64
}

func viewOf(t *testing.T, m *integration.Member) memberView {
	var v memberView
	for _, mm := range m.Server.Cluster().Members() {
		s := mm.ID.String()
		if mm.IsLearner {
			s += "(learner)"
		}
		v.Members = append(v.Members, s)
	}
	sort.Strings(v.Members)

	be := m.Server.Backend()
	be.ForceCommit()
	tx := be.ReadTx()
	tx.RLock()
	cs := schema.UnsafeConfStateFromBackend(zaptest.NewLogger(t), tx)
	tx.RUnlock()
	if cs != nil {
		v.Voters = append(v.Voters, cs.Voters...)
		v.Learners = append(v.Learners, cs.Learners...)
		sort.Slice(v.Voters, func(i, j int) bool { return v.Voters[i] < v.Voters[j] })
		sort.Slice(v.Learners, func(i, j int) bool { return v.Learners[i] < v.Learners[j] })
	}
	return v
}

// TestH1MixedMaxLearners checks whether members configured with different
// --max-learners values can apply the same committed conf change
// differently (invariant I1).
func TestH1MixedMaxLearners(t *testing.T) {
	integration.BeforeTest(t)
	traceMembership(t, "h1")

	// The proposal-time guard is off so adds aren't refused while peer
	// connections are young; the learner limit is checked at apply time
	// regardless (cluster.go ValidateConfigurationChange).
	clus := integration.NewCluster(t, &integration.ClusterConfig{Size: 3, MaxLearners: 1, DisableStrictReconfigCheck: true})
	defer clus.Terminate(t)

	// Restart member 0 with a higher limit; members 1 and 2 keep 1.
	m0 := clus.Members[0]
	m0.Stop(t)
	m0.MaxLearners = 2
	require.NoError(t, m0.Restart(t))
	clus.WaitLeader(t)

	ctx, cancel := context.WithTimeout(t.Context(), 10*time.Second)
	defer cancel()

	// First learner fits every member's limit.
	_, err := clus.Client(0).MemberAddAsLearner(ctx, []string{"http://127.0.0.1:11001"})
	require.NoError(t, err)

	// Second learner: member 0 allows it, members 1 and 2 do not. The client
	// talks to member 0, so it reports member 0's apply result.
	_, err = clus.Client(0).MemberAddAsLearner(ctx, []string{"http://127.0.0.1:11002"})
	t.Logf("second learner add via member 0: err=%v", err)

	// Let every member apply the entry.
	_, err = clus.Client(1).Put(ctx, "sync", "1")
	require.NoError(t, err)
	time.Sleep(time.Second)

	views := make([]memberView, 3)
	for i := 0; i < 3; i++ {
		views[i] = viewOf(t, clus.Members[i])
		t.Logf("member %d (max-learners=%d): members=%v confState voters=%v learners=%v",
			i, clus.Members[i].MaxLearners, views[i].Members, views[i].Voters, views[i].Learners)
	}

	if !(equalView(views[0], views[1]) && equalView(views[1], views[2])) {
		t.Errorf("H1 reproduced: members disagree on membership after applying the same log")
	}
}

func equalView(a, b memberView) bool {
	if len(a.Members) != len(b.Members) || len(a.Voters) != len(b.Voters) || len(a.Learners) != len(b.Learners) {
		return false
	}
	for i := range a.Members {
		if a.Members[i] != b.Members[i] {
			return false
		}
	}
	for i := range a.Voters {
		if a.Voters[i] != b.Voters[i] {
			return false
		}
	}
	for i := range a.Learners {
		if a.Learners[i] != b.Learners[i] {
			return false
		}
	}
	return true
}

// TestH2PromoteDeadLearner checks whether StrictReconfigCheck lets a learner
// that is caught up but no longer running be promoted while a voter is down,
// leaving the cluster without a reachable quorum (invariant I10).
func TestH2PromoteDeadLearner(t *testing.T) {
	integration.BeforeTest(t)
	traceMembership(t, "h2")

	clus := integration.NewCluster(t, &integration.ClusterConfig{Size: 3}) // strict reconfig check on
	defer clus.Terminate(t)

	leaderIdx := clus.WaitLeader(t)
	leaderCli := clus.Client(leaderIdx)

	ctx, cancel := context.WithTimeout(t.Context(), 30*time.Second)
	defer cancel()

	// Add and start a learner, and let it catch up.
	// The add guard needs peers connected for HealthInterval (5s) first.
	learner := clus.MustNewMember(t)
	var resp *clientv3.MemberAddResponse
	var err error
	require.Eventually(t, func() bool {
		resp, err = leaderCli.MemberAddAsLearner(ctx, learner.PeerURLs.StringSlice())
		return err == nil
	}, 20*time.Second, 500*time.Millisecond, "learner add kept failing: %v", err)
	learnerID := resp.Member.ID
	clus.InitializeMemberWithResponse(t, learner, resp)
	require.NoError(t, learner.Launch())
	for i := 0; i < 10; i++ {
		_, err = leaderCli.Put(ctx, "k", "v")
		require.NoError(t, err)
	}
	require.Eventually(t, func() bool {
		return learner.Server.AppliedIndex() >= clus.Members[leaderIdx].Server.AppliedIndex()
	}, 10*time.Second, 100*time.Millisecond, "learner did not catch up")

	// One voter (not the leader) goes down, then the learner goes down.
	downVoter := (leaderIdx + 1) % 3
	clus.Members[downVoter].Stop(t)
	learner.Stop(t)
	// Give the transport time to notice both are gone.
	time.Sleep(3 * time.Second)

	// Control: 2 of 3 voters still form a quorum, so writes succeed.
	putCtx, putCancel := context.WithTimeout(t.Context(), 5*time.Second)
	_, err = leaderCli.Put(putCtx, "before-promote", "v")
	putCancel()
	require.NoError(t, err, "control write before promotion failed")

	_, err = leaderCli.MemberPromote(ctx, learnerID)
	t.Logf("promote with 1 of 3 voters down and learner down: err=%v", err)
	if err != nil {
		t.Logf("H2 not reproduced: guard rejected the promotion")
		return
	}

	// 4 voters now, quorum 3, only 2 running.
	putCtx, putCancel = context.WithTimeout(t.Context(), 15*time.Second)
	_, err = leaderCli.Put(putCtx, "after-promote", "v")
	putCancel()
	t.Logf("put after promotion: err=%v", err)
	if err != nil {
		t.Errorf("H2 reproduced: promotion accepted under StrictReconfigCheck, cluster lost quorum (put: %v)", err)
	}

	// Recovery (informational): restarting the learner should restore a quorum.
	require.NoError(t, learner.Restart(t))
	recovered := false
	deadline := time.Now().Add(15 * time.Second)
	for time.Now().Before(deadline) && !recovered {
		putCtx, putCancel = context.WithTimeout(t.Context(), 2*time.Second)
		_, err = leaderCli.Put(putCtx, "after-recovery", "v")
		putCancel()
		recovered = err == nil
	}
	t.Logf("after restarting the learner, writes succeed again: %v", recovered)
}

// TestH3StaleViewAddVoter checks whether the add-voter guard, evaluated on a
// member that has not yet applied the previous membership change, accepts a
// change that the same guard rejects on an up-to-date member, leaving the
// cluster without a reachable quorum (invariant I10).
//
// Scenario (found by enumerating the guard formulas; such cases need an even
// number of voters):
//
//	4 voters, one down (3 alive).
//	op1: add voter n0 (not started) via the leader  -> 5 voters, 3 alive, quorum 3: ok.
//	op2: add voter n1 (not started) via a lagging follower that has not applied op1.
//	     Fresh view: connected 3 < quorum(6)=4 -> rejected.
//	     Stale view: connected 3 >= quorum(5)=3 -> accepted.
//	     Result: 6 voters, 3 alive, quorum 4: no quorum.
//
// To make the follower lag, the test holds a read lock on its backend and
// starts a commit, which waits for the write lock; new readers then queue
// behind it, so the follower's apply blocks in ValidateConfigurationChange
// before it updates its in-memory membership view. The lag must stay well
// under the election timeout (100ms in these tests).
func TestH3StaleViewAddVoter(t *testing.T) {
	integration.BeforeTest(t)
	traceMembership(t, "h3-add")

	clus := integration.NewCluster(t, &integration.ClusterConfig{Size: 4}) // strict reconfig check on
	defer clus.Terminate(t)

	leaderIdx := clus.WaitLeader(t)
	down := (leaderIdx + 1) % 4
	stale := (leaderIdx + 2) % 4

	ctx, cancel := context.WithTimeout(t.Context(), 30*time.Second)
	defer cancel()

	// Peers must be connected for HealthInterval (5s) before adds pass.
	time.Sleep(6 * time.Second)
	clus.Members[down].Stop(t)
	time.Sleep(2 * time.Second)

	// Freeze the stale member's apply loop at its next backend read.
	be := clus.Members[stale].Server.Backend()
	rtx := be.ReadTx()
	rtx.RLock()
	released := false
	release := func() {
		if !released {
			released = true
			rtx.RUnlock()
		}
	}
	defer release()
	go be.ForceCommit() // waits for the write lock; later readers queue behind it
	time.Sleep(50 * time.Millisecond)

	_, err := clus.Client(leaderIdx).MemberAdd(ctx, []string{"http://127.0.0.1:11101"})
	require.NoError(t, err, "op1 (add n0 via leader) failed")

	fresh := votersIn(clus.Members[leaderIdx])
	staleN := votersIn(clus.Members[stale])
	t.Logf("voters in view: leader=%d stale member=%d", fresh, staleN)

	// Control: the same request on the up-to-date leader is refused by the
	// guard (no raft round trip, so this keeps the stale window short).
	_, ctrlErr := clus.Client(leaderIdx).MemberAdd(ctx, []string{"http://127.0.0.1:11102"})
	t.Logf("control (same add via up-to-date leader): err=%v", ctrlErr)
	require.Error(t, ctrlErr, "control: up-to-date guard accepted the add")

	type result struct{ err error }
	done := make(chan result, 1)
	go func() {
		_, err := clus.Client(stale).MemberAdd(ctx, []string{"http://127.0.0.1:11102"})
		done <- result{err}
	}()
	time.Sleep(30 * time.Millisecond)
	release()

	r := <-done
	t.Logf("op2 (add n1 via stale member): err=%v", r.err)

	if r.err != nil {
		t.Logf("H3 not reproduced: stale-view request was rejected")
		return
	}
	putCtx, putCancel := context.WithTimeout(t.Context(), 15*time.Second)
	_, err = clus.Client(leaderIdx).Put(putCtx, "after", "v")
	putCancel()
	t.Logf("put after op2: err=%v; voters in leader view: %d", err, votersIn(clus.Members[leaderIdx]))
	if err != nil {
		t.Errorf("H3 reproduced: stale-view guard accepted a voter add that left no quorum (put: %v)", err)
	}
}

func votersIn(m *integration.Member) int {
	n := 0
	for _, mm := range m.Server.Cluster().Members() {
		if !mm.IsLearner {
			n++
		}
	}
	return n
}

// freezeApply makes m's apply loop block at its next backend read, leaving
// its in-memory membership view stale while its raft transport stays up.
// It holds a read lock on the backend and starts a commit, which waits for
// the write lock; new readers then queue behind the waiting writer. The
// returned func releases it (safe to call more than once).
func freezeApply(m *integration.Member) (release func()) {
	be := m.Server.Backend()
	rtx := be.ReadTx()
	rtx.RLock()
	go be.ForceCommit()
	time.Sleep(50 * time.Millisecond)
	done := false
	return func() {
		if !done {
			done = true
			rtx.RUnlock()
		}
	}
}

// TestH3StaleViewRemove is the remove-based form of H3. It needs only the
// remove guard, which is unchanged since before PR #21641, so it also
// applies to releases older than v3.6.11 / v3.5.30.
//
//	4 voters A (down), B, L (leader), S.
//	op1: remove B via L -> 3 voters {A, L, S}, 2 alive, quorum 2: ok.
//	op2: remove S via S, while S has not applied op1 and B (removed, but
//	     not yet applied its own removal) is still connected to S.
//	     Fresh view on L: active {L,S}=2, 2-1 < quorum(2)=2 -> rejected.
//	     Stale view on S: active {S,B,L}=3, 3-1 >= quorum(3)=2 -> accepted.
//	     Result: 2 voters {A, L}, 1 alive: no quorum.
func TestH3StaleViewRemove(t *testing.T) {
	integration.BeforeTest(t)
	traceMembership(t, "h3-remove")

	clus := integration.NewCluster(t, &integration.ClusterConfig{Size: 4}) // strict reconfig check on
	defer clus.Terminate(t)

	l := clus.WaitLeader(t)
	a, b, s := (l+1)%4, (l+2)%4, (l+3)%4
	ctx, cancel := context.WithTimeout(t.Context(), 30*time.Second)
	defer cancel()

	// Peers must be connected for HealthInterval (5s) for the guard.
	time.Sleep(6 * time.Second)
	clus.Members[a].Stop(t)
	time.Sleep(2 * time.Second)

	bID := uint64(clus.Members[b].Server.MemberID())
	sID := uint64(clus.Members[s].Server.MemberID())

	releaseB := freezeApply(clus.Members[b])
	defer releaseB()
	releaseS := freezeApply(clus.Members[s])
	defer releaseS()

	_, err := clus.Client(l).MemberRemove(ctx, bID)
	require.NoError(t, err, "op1 (remove B via leader) failed")
	t.Logf("voters in view: leader=%d stale member=%d", votersIn(clus.Members[l]), votersIn(clus.Members[s]))

	// Control: the same removal evaluated on the up-to-date leader.
	_, ctrlErr := clus.Client(l).MemberRemove(ctx, sID)
	t.Logf("control (remove S via up-to-date leader): err=%v", ctrlErr)
	require.Error(t, ctrlErr, "control: up-to-date guard accepted the removal")

	done := make(chan error, 1)
	go func() {
		_, err := clus.Client(s).MemberRemove(ctx, sID)
		done <- err
	}()
	time.Sleep(30 * time.Millisecond)
	releaseS()
	releaseB()

	err = <-done
	t.Logf("op2 (remove S via S, stale view): err=%v", err)
	// S removes itself, so the client may see an error even when the
	// removal was applied. Judge by the leader's view instead.
	require.Eventually(t, func() bool { return votersIn(clus.Members[l]) <= 3 }, 5*time.Second, 50*time.Millisecond)
	time.Sleep(time.Second)
	if votersIn(clus.Members[l]) != 2 {
		t.Logf("H3 (remove) not reproduced: stale-view removal was not applied (leader view: %d voters)", votersIn(clus.Members[l]))
		return
	}
	putCtx, putCancel := context.WithTimeout(t.Context(), 15*time.Second)
	_, err = clus.Client(l).Put(putCtx, "after", "v")
	putCancel()
	t.Logf("put after op2: err=%v; voters in leader view: %d", err, votersIn(clus.Members[l]))
	if err != nil {
		t.Errorf("H3 reproduced (remove): stale-view guard accepted a removal that left no quorum (put: %v)", err)
	}
}

// TestH1cExtraLearnerStartPanics follows H1 one step further: the learner
// that only member 0 accepted is started. When it publishes its name, the
// members that rejected it apply a ClusterMemberAttrSet for an unknown,
// non-removed member, and RaftCluster.UpdateAttributes panics.
//
// A member panic aborts the whole test process, so this test only runs
// with VERIFICATION_ALLOW_PANIC=1; the reproduction is the panic message
// "failed to update; member unknown" from members m1 and m2.
func TestH1cExtraLearnerStartPanics(t *testing.T) {
	if os.Getenv("VERIFICATION_ALLOW_PANIC") != "1" {
		t.Skip("set VERIFICATION_ALLOW_PANIC=1; a reproduction aborts the test process")
	}
	integration.BeforeTest(t)

	clus := integration.NewCluster(t, &integration.ClusterConfig{Size: 3, MaxLearners: 1, DisableStrictReconfigCheck: true})
	defer clus.Terminate(t)

	m0 := clus.Members[0]
	m0.Stop(t)
	m0.MaxLearners = 2
	require.NoError(t, m0.Restart(t))
	clus.WaitLeader(t)

	ctx, cancel := context.WithTimeout(t.Context(), 20*time.Second)
	defer cancel()

	// Only member 0's raft config will include the second learner, so it
	// gets replication (and can publish) only while member 0 leads.
	if lead := clus.WaitLeader(t); lead != 0 {
		_, err := clus.Client(lead).MoveLeader(ctx, uint64(m0.Server.MemberID()))
		require.NoError(t, err)
		require.Eventually(t, func() bool { return clus.WaitLeader(t) == 0 }, 10*time.Second, 100*time.Millisecond)
	}

	// First learner: accepted everywhere; never started.
	const firstURL = "http://127.0.0.1:11001"
	_, err := clus.Client(0).MemberAddAsLearner(ctx, []string{firstURL})
	require.NoError(t, err)

	// Second learner: accepted only by member 0. It runs with
	// --max-learners=2 itself, or it would refuse to join.
	l2 := clus.MustNewMember(t)
	l2.MaxLearners = 2
	_, err = clus.Client(0).MemberAddAsLearner(ctx, l2.PeerURLs.StringSlice())
	require.NoError(t, err)

	// Join through member 0, the only member that lists l2. The initial
	// cluster must name every member in member 0's view.
	l2.IsLearner = true
	l2.NewCluster = false
	l2.InitialPeerURLsMap = types.URLsMap{"first-learner": types.MustNewURLs([]string{firstURL})}
	for _, m := range clus.Members {
		l2.InitialPeerURLsMap[m.Name] = m.PeerURLs
	}
	l2.InitialPeerURLsMap[l2.Name] = l2.PeerURLs
	t.Logf("launching second learner %s", l2.Name)
	err = l2.Launch()
	t.Logf("launch returned: %v", err)
	clus.Members = append(clus.Members, l2) // cluster teardown cleans it up

	// If H1c holds, m1 and m2 panic while applying l2's attribute update.
	time.Sleep(10 * time.Second)
	t.Logf("no panic within 10s (H1c not reproduced)")
}

// traceMembership records a server-layer membership trace for this test
// when VERIFICATION_TRACE_DIR is set and the build has the with_tla tag
// (otherwise the server ignores the variable). Validate with
// verification/tools/validate-membership-trace.sh.
func traceMembership(t *testing.T, name string) {
	dir := os.Getenv("VERIFICATION_TRACE_DIR")
	if dir == "" {
		return
	}
	path := filepath.Join(dir, "membership-"+name+".ndjson")
	require.NoError(t, os.RemoveAll(path))
	t.Setenv("ETCD_TLA_MEMBERSHIP_TRACE_FILE", path)
	t.Logf("membership trace: %s", path)
}
