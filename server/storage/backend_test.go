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

package storage

import (
	"errors"
	"os"
	"path/filepath"
	"testing"

	"github.com/stretchr/testify/require"
	"go.uber.org/zap/zaptest"

	"go.etcd.io/etcd/server/v3/config"
	"go.etcd.io/etcd/server/v3/etcdserver/api/snap"
	"go.etcd.io/etcd/server/v3/etcdserver/cindex"
	"go.etcd.io/raft/v3/raftpb"
)

func TestOpenSnapshotBackendSyncsDirectory(t *testing.T) {
	for _, tc := range []struct {
		name    string
		syncErr error
	}{
		{name: "success"},
		{name: "sync error", syncErr: errors.New("sync failed")},
	} {
		t.Run(tc.name, func(t *testing.T) {
			cfg := config.ServerConfig{Logger: zaptest.NewLogger(t), DataDir: t.TempDir()}
			require.NoError(t, os.MkdirAll(cfg.SnapDir(), 0o700))
			ss := snap.New(cfg.Logger, cfg.SnapDir())

			const index = uint64(5)
			snapPath := filepath.Join(cfg.SnapDir(), "0000000000000005.snap.db")
			require.NoError(t, os.WriteFile(snapPath, nil, 0o600))

			var synced []string
			old := fsyncDir
			fsyncDir = func(dir string) error {
				synced = append(synced, dir)
				return tc.syncErr
			}
			defer func() { fsyncDir = old }()

			snapshot := &raftpb.Snapshot{Metadata: &raftpb.SnapshotMetadata{Index: new(index)}}
			hooks := NewBackendHooks(cfg.Logger, cindex.NewFakeConsistentIndex(index))
			be, err := OpenSnapshotBackend(cfg, ss, snapshot, hooks)
			if be != nil {
				defer be.Close()
			}

			require.Equal(t, []string{filepath.Dir(cfg.BackendPath())}, synced)
			require.FileExists(t, cfg.BackendPath())
			require.NoFileExists(t, snapPath)
			if tc.syncErr != nil {
				require.ErrorIs(t, err, tc.syncErr)
				require.Nil(t, be)
				return
			}
			require.NoError(t, err)
			require.NotNil(t, be)
		})
	}
}
