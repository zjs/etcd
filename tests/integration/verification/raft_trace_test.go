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

//go:build verification && with_tla

package verification

// Scenarios that record raft state-machine traces from a real in-process
// cluster, for validation against verification/raft/Traceetcdraft.tla:
//
//	VERIFICATION_TRACE_DIR=/some/dir go test -tags verification,with_tla \
//	    ./integration/verification/ -run TestTrace -v
//	verification/tools/validate-trace.sh /some/dir/*.ndjson
//
// A 100ms tick keeps traces short (validation slows sharply with length).

import (
	"context"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/stretchr/testify/require"

	"go.etcd.io/etcd/server/v3/etcdserver"
	"go.etcd.io/etcd/tests/v3/framework/integration"
)

func traceCluster(t *testing.T, name string, size int) *integration.Cluster {
	dir := os.Getenv("VERIFICATION_TRACE_DIR")
	if dir == "" {
		dir = t.TempDir()
	}
	path := filepath.Join(dir, name+".ndjson")
	require.NoError(t, os.RemoveAll(path))
	t.Setenv(etcdserver.RaftTraceFileEnv, path)
	t.Logf("raft trace: %s", path)
	return integration.NewCluster(t, &integration.ClusterConfig{
		Size: size, TickMs: 100, DisableStrictReconfigCheck: true,
	})
}

func TestTraceBasic(t *testing.T) {
	integration.BeforeTest(t)
	clus := traceCluster(t, "basic", 3)
	defer clus.Terminate(t)

	lead := clus.WaitLeader(t)
	ctx, cancel := context.WithTimeout(t.Context(), 10*time.Second)
	defer cancel()
	for i := 0; i < 3; i++ {
		_, err := clus.Client(lead).Put(ctx, "k", "v")
		require.NoError(t, err)
	}
}

func TestTraceLearnerPromote(t *testing.T) {
	integration.BeforeTest(t)
	clus := traceCluster(t, "learner-promote", 3)
	defer clus.Terminate(t)

	lead := clus.WaitLeader(t)
	cli := clus.Client(lead)
	ctx, cancel := context.WithTimeout(t.Context(), 20*time.Second)
	defer cancel()

	learner := clus.MustNewMember(t)
	resp, err := cli.MemberAddAsLearner(ctx, learner.PeerURLs.StringSlice())
	require.NoError(t, err)
	clus.InitializeMemberWithResponse(t, learner, resp)
	require.NoError(t, learner.Launch())

	_, err = cli.Put(ctx, "k", "v")
	require.NoError(t, err)
	require.Eventually(t, func() bool {
		_, err = cli.MemberPromote(ctx, resp.Member.ID)
		return err == nil
	}, 10*time.Second, 200*time.Millisecond, "promote kept failing: %v", err)
	_, err = cli.Put(ctx, "k", "v2")
	require.NoError(t, err)
}

func TestTraceRemoveMember(t *testing.T) {
	integration.BeforeTest(t)
	clus := traceCluster(t, "remove", 3)
	defer clus.Terminate(t)

	lead := clus.WaitLeader(t)
	follower := (lead + 1) % 3
	ctx, cancel := context.WithTimeout(t.Context(), 10*time.Second)
	defer cancel()
	require.NoError(t, clus.RemoveMember(t, clus.Client(lead), uint64(clus.Members[follower].Server.MemberID())))
	_, err := clus.Client(lead).Put(ctx, "k", "v")
	require.NoError(t, err)
}

func TestTraceRestartFollower(t *testing.T) {
	integration.BeforeTest(t)
	clus := traceCluster(t, "restart-follower", 3)
	defer clus.Terminate(t)

	lead := clus.WaitLeader(t)
	follower := (lead + 1) % 3
	ctx, cancel := context.WithTimeout(t.Context(), 20*time.Second)
	defer cancel()

	clus.Members[follower].Stop(t)
	_, err := clus.Client(lead).Put(ctx, "k", "v1")
	require.NoError(t, err)
	require.NoError(t, clus.Members[follower].Restart(t))
	clus.WaitMembersForLeader(t, clus.Members)
	_, err = clus.Client(lead).Put(ctx, "k", "v2")
	require.NoError(t, err)
}

func TestTraceRemoveLeader(t *testing.T) {
	integration.BeforeTest(t)
	clus := traceCluster(t, "remove-leader", 3)
	defer clus.Terminate(t)

	lead := clus.WaitLeader(t)
	other := (lead + 1) % 3
	ctx, cancel := context.WithTimeout(t.Context(), 20*time.Second)
	defer cancel()

	require.NoError(t, clus.RemoveMember(t, clus.Client(other), uint64(clus.Members[lead].Server.MemberID())))
	clus.WaitLeader(t)
	_, err := clus.Client(0).Put(ctx, "k", "v")
	require.NoError(t, err)
}
