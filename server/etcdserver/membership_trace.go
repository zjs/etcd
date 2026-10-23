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

//go:build !with_tla

package etcdserver

import (
	"go.etcd.io/etcd/client/pkg/v3/types"
	"go.etcd.io/etcd/server/v3/etcdserver/api/membership"
	"go.etcd.io/raft/v3/raftpb"
)

// Membership tracing hooks; no-ops unless built with the with_tla tag
// (see membership_trace_tla.go).

func (s *EtcdServer) traceMemberRequest(string, types.ID, error) {}

func cloneConfChangeForTrace(*raftpb.ConfChange) *raftpb.ConfChange { return nil }

func (s *EtcdServer) traceConfChangeApplied(*raftpb.ConfChange, membership.ShouldApplyV3) {}

func (s *EtcdServer) traceMemberStart() {}

func (s *EtcdServer) traceMemberStop() {}
