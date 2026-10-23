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

package e2e

import (
	"context"
	"testing"
	"time"

	"github.com/stretchr/testify/require"

	"go.etcd.io/etcd/server/v3/etcdserver"
	"go.etcd.io/etcd/tests/v3/framework/config"
	"go.etcd.io/etcd/tests/v3/framework/e2e"
)

// TestMemberReconfigStaleView ensures that the strict reconfig checks on a
// member that has not yet applied a committed membership change take that
// change into account.
//
// Four voters, one of them down. A first change through the leader is
// accepted. A second change through a follower that is still applying the
// first would be accepted against the follower's old view, and would leave
// the cluster without a quorum; against the current view it is refused.
func TestMemberReconfigStaleView(t *testing.T) {
	for _, tc := range []struct {
		name string
		// first runs through the leader; second through the stale follower.
		first, second func(ctx context.Context, epc *e2e.EtcdProcessCluster, lead, stale, other int, ids map[int]uint64) error
	}{
		{
			// 4 voters, 1 down. Adding a voter (not started) leaves 5 with 3
			// up, which is enough. Adding a second leaves 6 with 3 up.
			name: "add",
			first: func(ctx context.Context, epc *e2e.EtcdProcessCluster, lead, _, _ int, _ map[int]uint64) error {
				_, err := epc.Procs[lead].Etcdctl().MemberAdd(ctx, "n0", []string{"http://127.0.0.1:41001"})
				return err
			},
			second: func(ctx context.Context, epc *e2e.EtcdProcessCluster, _, stale, _ int, _ map[int]uint64) error {
				_, err := epc.Procs[stale].Etcdctl().MemberAdd(ctx, "n1", []string{"http://127.0.0.1:41002"})
				return err
			},
		},
		{
			// 4 voters, 1 down. Removing a running voter leaves 3 with 2 up,
			// which is enough. Removing the stale follower too leaves 2 with
			// 1 up.
			name: "remove",
			first: func(ctx context.Context, epc *e2e.EtcdProcessCluster, lead, _, other int, ids map[int]uint64) error {
				_, err := epc.Procs[lead].Etcdctl().MemberRemove(ctx, ids[other])
				return err
			},
			second: func(ctx context.Context, epc *e2e.EtcdProcessCluster, _, stale, _ int, ids map[int]uint64) error {
				_, err := epc.Procs[stale].Etcdctl().MemberRemove(ctx, ids[stale])
				return err
			},
		},
	} {
		t.Run(tc.name, func(t *testing.T) {
			e2e.BeforeTest(t)
			ctx := t.Context()
			epc, err := e2e.NewEtcdProcessCluster(ctx, t, e2e.WithClusterSize(4), e2e.WithGoFailEnabled(true))
			require.NoError(t, err)
			defer epc.Close()

			lead := epc.WaitLeader(t)
			stale, down, other := (lead+1)%4, (lead+2)%4, (lead+3)%4
			ids := map[int]uint64{}
			resp, err := epc.Procs[lead].Etcdctl().MemberList(ctx, false)
			require.NoError(t, err)
			for i, p := range epc.Procs {
				for _, m := range resp.Members {
					if m.Name == p.Config().Name {
						ids[i] = m.ID
					}
				}
			}
			require.Len(t, ids, 4)

			require.NoError(t, epc.Procs[down].Stop())
			// The checks count peers connected for HealthInterval.
			time.Sleep(etcdserver.HealthInterval + time.Second)

			// The stale follower applies the next membership change late.
			// Keep the delay below the election timeout (1s), so the leader
			// keeps its quorum while the follower is busy.
			require.NoError(t, epc.Procs[stale].Failpoints().SetupHTTP(ctx, "beforeApplyOneConfChange", `sleep(500)`))
			if tc.name == "remove" {
				// A removed member closes its connections once it applies its
				// own removal. Delay that too, so the stale follower still
				// counts it as connected, as it would within its own lag.
				require.NoError(t, epc.Procs[other].Failpoints().SetupHTTP(ctx, "beforeApplyOneConfChange", `sleep(500)`))
			}

			require.NoError(t, tc.first(ctx, epc, lead, stale, other, ids))
			// Without the fix the second change is applied; a member removing
			// itself may then stop before replying ("server stopped").
			err = tc.second(ctx, epc, lead, stale, other, ids)
			require.ErrorContains(t, err, "unhealthy cluster")

			require.NoError(t, epc.Procs[stale].Failpoints().DeactivateHTTP(ctx, "beforeApplyOneConfChange"))
			putCtx, cancel := context.WithTimeout(ctx, 5*time.Second)
			defer cancel()
			_, err = epc.Procs[lead].Etcdctl().Put(putCtx, "foo", "bar", config.PutOptions{})
			require.NoErrorf(t, err, "cluster should keep its quorum")
		})
	}
}
