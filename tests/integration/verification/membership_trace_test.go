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

// Records server-layer membership traces for validation against
// verification/server/TraceEtcdMembership.tla:
//
//	VERIFICATION_TRACE_DIR=/some/dir go test -tags verification,with_tla \
//	    ./integration/verification/ -run TestMembershipTrace -v
//	verification/tools/validate-membership-trace.sh /some/dir/membership-*.ndjson

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

func membershipTraceCluster(t *testing.T, name string, size int) *integration.Cluster {
	dir := os.Getenv("VERIFICATION_TRACE_DIR")
	if dir == "" {
		dir = t.TempDir()
	}
	path := filepath.Join(dir, "membership-"+name+".ndjson")
	require.NoError(t, os.RemoveAll(path))
	t.Setenv(etcdserver.MembershipTraceFileEnv, path)
	t.Logf("membership trace: %s", path)
	return integration.NewCluster(t, &integration.ClusterConfig{Size: size}) // strict reconfig check on
}

func TestMembershipTraceLifecycle(t *testing.T) {
	integration.BeforeTest(t)
	clus := membershipTraceCluster(t, "lifecycle", 3)
	defer clus.Terminate(t)

	lead := clus.WaitLeader(t)
	cli := clus.Client(lead)
	ctx, cancel := context.WithTimeout(t.Context(), 60*time.Second)
	defer cancel()
	time.Sleep(6 * time.Second) // guards need HealthInterval of connectivity

	// Learner: add, start, promote (retry while not ready).
	learner := clus.MustNewMember(t)
	resp, err := cli.MemberAddAsLearner(ctx, learner.PeerURLs.StringSlice())
	require.NoError(t, err)
	clus.InitializeMemberWithResponse(t, learner, resp)
	require.NoError(t, learner.Launch())
	require.Eventually(t, func() bool {
		_, err = cli.MemberPromote(ctx, resp.Member.ID)
		return err == nil
	}, 20*time.Second, 300*time.Millisecond, "promote kept failing: %v", err)

	// A voter goes down; adding another voter is refused by the guard.
	follower := -1
	for i := range clus.Members {
		if i != lead && clus.Members[i] != learner {
			follower = i
			break
		}
	}
	clus.Members[follower].Stop(t)
	time.Sleep(3 * time.Second)
	_, err = cli.MemberAdd(ctx, []string{"http://127.0.0.1:11201"})
	require.Error(t, err, "expected the add guard to refuse")

	// Restart it, then remove it.
	require.NoError(t, clus.Members[follower].Restart(t))
	clus.WaitMembersForLeader(t, clus.Members)
	time.Sleep(6 * time.Second)
	require.NoError(t, clus.RemoveMember(t, cli, uint64(clus.Members[follower].Server.MemberID())))
}
