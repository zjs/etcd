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
	"go.uber.org/zap"

	"go.etcd.io/raft/v3"
)

// setRaftTraceLogger is a no-op unless built with the with_tla tag
// (see raft_trace_tla.go).
func setRaftTraceLogger(*raft.Config, *zap.Logger) {}
