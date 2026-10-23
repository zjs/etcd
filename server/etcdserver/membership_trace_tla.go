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
	errorspkg "errors"
	"os"
	"sort"
	"sync"
	"time"

	"google.golang.org/protobuf/proto"

	"go.etcd.io/etcd/client/pkg/v3/types"
	"go.etcd.io/etcd/server/v3/etcdserver/api/membership"
	"go.etcd.io/etcd/server/v3/etcdserver/errors"
	"go.etcd.io/raft/v3/raftpb"
)

// MembershipTraceFileEnv names the file that membership events are appended
// to, in the NDJSON format read by verification/server/TraceEtcdMembership.tla.
const MembershipTraceFileEnv = "ETCD_TLA_MEMBERSHIP_TRACE_FILE"

// Events:
//
//	Start   member started (view and consistent index restored)
//	Stop    member stopped
//	Request a membership request passed the proposal-time guard
//	Reject  a membership request was refused by the guard
//	Apply   a client-originated conf change was applied (ApplyBoth only)
//
// Conf changes are numbered by their position among client-originated conf
// changes in the raft log ("pos", 1-based), which is what the model's log
// index means. Bootstrap / force-new-cluster entries (cc.Id == 0) are not
// traced.
type memberTraceEvent struct {
	Name        string   `json:"name"`
	NodeID      string   `json:"nid"`
	Kind        string   `json:"kind,omitempty"`
	ID          string   `json:"id,omitempty"`
	Err         string   `json:"err,omitempty"`
	Pos         int      `json:"pos"`
	Voters      []string `json:"voters"`
	Learners    []string `json:"learners"`
	Removed     []string `json:"removed"`
	MaxLearners int      `json:"maxLearners"`
}

type memberTracer struct {
	mu   sync.Mutex
	f    *os.File
	pos  map[uint64]int // raft index -> position among traced conf changes
	next int
}

var (
	memberTracersMu sync.Mutex
	memberTracers   = map[string]*memberTracer{}
)

// getMemberTracer returns the tracer for the current value of
// MembershipTraceFileEnv (one per file, shared by all members in the
// process), or nil when tracing is off.
func getMemberTracer() *memberTracer {
	path := os.Getenv(MembershipTraceFileEnv)
	if path == "" {
		return nil
	}
	memberTracersMu.Lock()
	defer memberTracersMu.Unlock()
	if t, ok := memberTracers[path]; ok {
		return t
	}
	f, err := os.OpenFile(path, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o644)
	if err != nil {
		return nil
	}
	t := &memberTracer{f: f, pos: map[uint64]int{}, next: 1}
	memberTracers[path] = t
	return t
}

func (t *memberTracer) emit(ev memberTraceEvent) {
	b, err := json.Marshal(struct {
		TS    float64          `json:"ts"`
		Tag   string           `json:"tag"`
		Event memberTraceEvent `json:"event"`
	}{float64(time.Now().UnixNano()) / 1e9, "trace", ev})
	if err != nil {
		return
	}
	t.f.Write(append(b, '\n'))
}

// positionsUpTo counts traced conf changes at raft index <= idx. Caller
// holds t.mu.
func (t *memberTracer) positionsUpTo(idx uint64) int {
	n := 0
	for ri := range t.pos {
		if ri <= idx {
			n++
		}
	}
	return n
}

func ids(xs []types.ID) []string {
	out := make([]string, 0, len(xs))
	for _, x := range xs {
		out = append(out, x.String())
	}
	sort.Strings(out)
	return out
}

func (s *EtcdServer) memberView(ev *memberTraceEvent) {
	var voters, learners []types.ID
	for _, m := range s.cluster.Members() {
		if m.IsLearner {
			learners = append(learners, m.ID)
		} else {
			voters = append(voters, m.ID)
		}
	}
	ev.Voters, ev.Learners = ids(voters), ids(learners)
	ev.Removed = ids(s.cluster.RemovedIDsForTrace())
	ev.MaxLearners = s.Cfg.MaxLearners
}

func (s *EtcdServer) traceMemberRequest(kind string, id types.ID, err error) {
	t := getMemberTracer()
	if t == nil || errorspkg.Is(err, errors.ErrNotLeader) {
		return
	}
	ev := memberTraceEvent{Name: "Request", NodeID: s.MemberID().String(), Kind: kind, ID: id.String()}
	if err != nil {
		ev.Name, ev.Err = "Reject", err.Error()
	}
	t.mu.Lock()
	defer t.mu.Unlock()
	ev.Pos = t.positionsUpTo(s.consistIndex.ConsistentIndex())
	s.memberView(&ev)
	t.emit(ev)
}

func cloneConfChangeForTrace(cc *raftpb.ConfChange) *raftpb.ConfChange {
	if getMemberTracer() == nil {
		return nil
	}
	return proto.Clone(cc).(*raftpb.ConfChange)
}

func confChangeKind(cc *raftpb.ConfChange) string {
	switch cc.GetType() {
	case raftpb.ConfChangeAddLearnerNode:
		return "addLearner"
	case raftpb.ConfChangeRemoveNode:
		return "remove"
	case raftpb.ConfChangeAddNode:
		ctx := new(membership.ConfigChangeContext)
		if err := json.Unmarshal(cc.Context, ctx); err == nil && ctx.IsPromote {
			return "promote"
		}
		return "addVoter"
	}
	return ""
}

// traceConfChangeApplied runs (deferred) at the end of applyConfChange, with
// a copy of the conf change taken before validation could clear its NodeId.
func (s *EtcdServer) traceConfChangeApplied(cc *raftpb.ConfChange, shouldApplyV3 membership.ShouldApplyV3) {
	t := getMemberTracer()
	if t == nil || cc == nil || !shouldApplyV3 || cc.GetId() == 0 {
		return
	}
	kind := confChangeKind(cc)
	if kind == "" {
		return
	}
	idx, _ := s.consistIndex.ConsistentApplyingIndex()
	t.mu.Lock()
	defer t.mu.Unlock()
	p, ok := t.pos[idx]
	if !ok {
		p = t.next
		t.pos[idx] = p
		t.next++
	}
	ev := memberTraceEvent{Name: "Apply", NodeID: s.MemberID().String(), Kind: kind, ID: types.ID(cc.GetNodeId()).String(), Pos: p}
	s.memberView(&ev)
	t.emit(ev)
}

func (s *EtcdServer) traceMemberStart() {
	t := getMemberTracer()
	if t == nil {
		return
	}
	t.mu.Lock()
	defer t.mu.Unlock()
	ev := memberTraceEvent{Name: "Start", NodeID: s.MemberID().String()}
	ev.Pos = t.positionsUpTo(s.consistIndex.ConsistentIndex())
	s.memberView(&ev)
	t.emit(ev)
}

func (s *EtcdServer) traceMemberStop() {
	t := getMemberTracer()
	if t == nil {
		return
	}
	t.mu.Lock()
	defer t.mu.Unlock()
	t.emit(memberTraceEvent{Name: "Stop", NodeID: s.MemberID().String(), Voters: []string{}, Learners: []string{}, Removed: []string{}})
}
