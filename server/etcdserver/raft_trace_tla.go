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

//go:build with_tla

package etcdserver

import (
	"encoding/json"
	"os"
	"sync"
	"time"

	"go.uber.org/zap"

	"go.etcd.io/raft/v3"
)

// RaftTraceFileEnv names the file that raft state-machine traces are
// appended to, in the NDJSON format read by the raft TLA+ trace spec
// (verification/raft/Traceetcdraft.tla). Unset: no tracing.
const RaftTraceFileEnv = "ETCD_TLA_TRACE_FILE"

var (
	traceMu    sync.Mutex
	traceFiles = map[string]*os.File{}
)

// raftTraceWriter appends events to one file shared by every member in the
// process. Writes are serialized, so the file order is a total order that
// respects each message's send-before-receive.
type raftTraceWriter struct {
	f *os.File
}

type traceLine struct {
	TS    float64            `json:"ts"`
	Tag   string             `json:"tag"`
	Event *raft.TracingEvent `json:"event"`
}

func (w raftTraceWriter) TraceEvent(ev *raft.TracingEvent) {
	b, err := json.Marshal(traceLine{
		TS:    float64(time.Now().UnixNano()) / 1e9,
		Tag:   "trace",
		Event: ev,
	})
	if err != nil {
		return
	}
	traceMu.Lock()
	defer traceMu.Unlock()
	w.f.Write(append(b, '\n'))
}

func setRaftTraceLogger(c *raft.Config, lg *zap.Logger) {
	path := os.Getenv(RaftTraceFileEnv)
	if path == "" {
		return
	}
	traceMu.Lock()
	defer traceMu.Unlock()
	f, ok := traceFiles[path]
	if !ok {
		var err error
		f, err = os.OpenFile(path, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o644)
		if err != nil {
			lg.Warn("cannot open raft trace file", zap.String("path", path), zap.Error(err))
			return
		}
		traceFiles[path] = f
	}
	c.TraceLogger = raftTraceWriter{f: f}
	lg.Info("raft state-machine tracing enabled", zap.String("path", path))
}
