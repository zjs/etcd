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

package failpoint

import (
	"context"
	"fmt"
	"math/rand"
	"os"
	"strings"
	"testing"
	"time"

	"go.uber.org/zap"

	clientv3 "go.etcd.io/etcd/client/v3"
	"go.etcd.io/etcd/server/v3/etcdserver"
	"go.etcd.io/etcd/tests/v3/framework/e2e"
	"go.etcd.io/etcd/tests/v3/robustness/identity"
	"go.etcd.io/etcd/tests/v3/robustness/report"
	"go.etcd.io/etcd/tests/v3/robustness/traffic"
)

var (
	// MemberReplaceAsLearner removes a member, wipes its data, adds it back
	// as a learner, starts it and promotes it once it has caught up.
	MemberReplaceAsLearner Failpoint = memberReplaceAsLearner{churn: false}
	// MemberReplaceLearnerChurn is MemberReplaceAsLearner, except that the
	// learner is removed and added back once before it is promoted.
	MemberReplaceLearnerChurn Failpoint = memberReplaceAsLearner{churn: true}
)

type memberReplaceAsLearner struct {
	churn bool
}

func (f memberReplaceAsLearner) Name() string {
	if f.churn {
		return "MemberReplaceLearnerChurn"
	}
	return "MemberReplaceAsLearner"
}

func (f memberReplaceAsLearner) Available(config e2e.EtcdProcessClusterConfig, member e2e.EtcdProcess, profile traffic.Profile) bool {
	// Same conditions as MemberReplace: a lower etcd version may not be able
	// to join a cluster with a higher cluster version.
	return config.ClusterSize > 1 && (config.Version == e2e.QuorumLastVersion || member.Config().ExecPath == e2e.BinPath.Etcd)
}

func (f memberReplaceAsLearner) Timeout() time.Duration {
	return 2 * time.Minute
}

func (f memberReplaceAsLearner) Inject(ctx context.Context, t *testing.T, lg *zap.Logger, clus *e2e.EtcdProcessCluster, baseTime time.Time, ids identity.Provider) ([]report.ClientReport, error) {
	idx := rand.Int() % len(clus.Procs)
	member := clus.Procs[idx]
	cc, err := clientv3.New(clientv3.Config{
		Endpoints:            []string{clus.Procs[(idx+1)%len(clus.Procs)].EndpointsGRPC()[0]},
		Logger:               zap.NewNop(),
		DialKeepAliveTime:    10 * time.Second,
		DialKeepAliveTimeout: 100 * time.Millisecond,
	})
	if err != nil {
		return nil, err
	}
	defer cc.Close()

	id, found, err := getID(ctx, cc, member.Config().Name)
	if err != nil {
		return nil, err
	}
	if !found {
		return nil, fmt.Errorf("member %s not found", member.Config().Name)
	}

	// Guards need HealthInterval of connectivity before accepting changes.
	time.Sleep(etcdserver.HealthInterval)
	lg.Info("Removing member", zap.String("member", member.Config().Name))
	if _, err = cc.MemberRemove(ctx, id); err != nil {
		return nil, err
	}
	if err = stopAndWipe(ctx, lg, member); err != nil {
		return nil, err
	}

	learnerID, err := addAndStartLearner(ctx, lg, cc, member)
	if err != nil {
		return nil, err
	}

	if f.churn {
		time.Sleep(etcdserver.HealthInterval)
		lg.Info("Removing learner", zap.String("member", member.Config().Name))
		if err = retry(ctx, func(ctx context.Context) error {
			_, err := cc.MemberRemove(ctx, learnerID)
			return err
		}); err != nil {
			return nil, err
		}
		if err = stopAndWipe(ctx, lg, member); err != nil {
			return nil, err
		}
		if learnerID, err = addAndStartLearner(ctx, lg, cc, member); err != nil {
			return nil, err
		}
	}

	lg.Info("Promoting learner", zap.String("member", member.Config().Name))
	if err = retry(ctx, func(ctx context.Context) error {
		_, err := cc.MemberPromote(ctx, learnerID)
		return err
	}); err != nil {
		return nil, err
	}
	return nil, nil
}

// retry calls fn with a short per-attempt timeout until it succeeds or ctx
// ends (learner not ready, guards not yet satisfied, leader changes).
func retry(ctx context.Context, fn func(context.Context) error) error {
	for {
		reqCtx, cancel := context.WithTimeout(ctx, time.Second)
		err := fn(reqCtx)
		cancel()
		if err == nil {
			return nil
		}
		select {
		case <-ctx.Done():
			return fmt.Errorf("%w (last error: %w)", ctx.Err(), err)
		case <-time.After(200 * time.Millisecond):
		}
	}
}

func stopAndWipe(ctx context.Context, lg *zap.Logger, member e2e.EtcdProcess) error {
	for member.IsRunning() {
		if err := member.Kill(); err != nil {
			lg.Info("Sending kill signal failed", zap.Error(err))
		}
		if err := member.Wait(ctx); err != nil && !strings.Contains(err.Error(), "unexpected exit code") {
			return fmt.Errorf("failed to kill the process within %s, err: %w", triggerTimeout, err)
		}
	}
	lg.Info("Removing member data", zap.String("member", member.Config().Name))
	return os.RemoveAll(member.Config().DataDirPath)
}

func addAndStartLearner(ctx context.Context, lg *zap.Logger, cc *clientv3.Client, member e2e.EtcdProcess) (uint64, error) {
	lg.Info("Adding member back as learner", zap.String("member", member.Config().Name))
	var id uint64
	if err := retry(ctx, func(ctx context.Context) error {
		resp, err := cc.MemberAddAsLearner(ctx, []string{member.Config().PeerURL.String()})
		if err == nil {
			id = resp.Member.ID
		}
		return err
	}); err != nil {
		return 0, err
	}
	if err := patchArgs(member.Config().Args, "initial-cluster-state", "existing"); err != nil {
		return 0, err
	}
	lg.Info("Starting learner", zap.String("member", member.Config().Name))
	if err := member.Start(ctx); err != nil {
		return 0, err
	}
	return id, nil
}
