// src/api/history.go
// In-memory time-series store for the /api/history endpoint.
// Keeps 1h of per-metric float64 values at 1Hz resolution.

package main

import (
	"encoding/json"
	"net/http"
	"strconv"
	"sync"
	"time"
)

// ─── Series ───────────────────────────────────────────────────────────────────

type Point struct {
	Ts    int64   `json:"ts"`
	Value float64 `json:"v"`
}

type Series struct {
	mu   sync.RWMutex
	buf  []Point
	head int
	n    int
	cap_ int
}

func newSeries(capacity int) *Series {
	return &Series{buf: make([]Point, capacity), cap_: capacity}
}

func (s *Series) Push(ts int64, v float64) {
	s.mu.Lock()
	s.buf[s.head%s.cap_] = Point{Ts: ts, Value: v}
	s.head++
	if s.n < s.cap_ {
		s.n++
	}
	s.mu.Unlock()
}

func (s *Series) Last(n int) []Point {
	s.mu.RLock()
	defer s.mu.RUnlock()
	if n > s.n {
		n = s.n
	}
	out := make([]Point, n)
	for i := range out {
		out[i] = s.buf[(s.head-n+i+s.cap_)%s.cap_]
	}
	return out
}

// ─── Store ────────────────────────────────────────────────────────────────────

type Store struct {
	mu      sync.RWMutex
	series  map[string]*Series
	cap_    int
}

func newStore(cap int) *Store {
	return &Store{series: make(map[string]*Series), cap_: cap}
}

func (st *Store) Record(name string, ts int64, v float64) {
	st.mu.Lock()
	s, ok := st.series[name]
	if !ok {
		s = newSeries(st.cap_)
		st.series[name] = s
	}
	st.mu.Unlock()
	s.Push(ts, v)
}

func (st *Store) IngestSnapshot(raw []byte) {
	var snap Snapshot
	if err := json.Unmarshal(raw, &snap); err != nil {
		return
	}
	ts := snap.TimestampMs

	st.Record("cpu_pct", ts, snap.CpuPct)

	if snap.Mem.TotalKb > 0 {
		memPct := float64(snap.Mem.TotalKb-snap.Mem.AvailableKb) / float64(snap.Mem.TotalKb) * 100
		st.Record("mem_pct", ts, memPct)
	}

	st.Record("load_one",  ts, snap.Load.One)
	st.Record("load_five", ts, snap.Load.Five)
}

// ─── HTTP handler ─────────────────────────────────────────────────────────────

// GET /api/history?metric=cpu_pct&n=300
func (st *Store) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	metric := r.URL.Query().Get("metric")
	if metric == "" {
		metric = "cpu_pct"
	}
	n := 60
	if ns := r.URL.Query().Get("n"); ns != "" {
		if v, err := strconv.Atoi(ns); err == nil && v > 0 {
			n = v
		}
	}

	st.mu.RLock()
	s, ok := st.series[metric]
	st.mu.RUnlock()

	w.Header().Set("Content-Type", "application/json")
	if !ok {
		w.Write([]byte("[]"))
		return
	}
	json.NewEncoder(w).Encode(s.Last(n))
}

// ─── Available metrics ────────────────────────────────────────────────────────

func (st *Store) ServeMetricsList(w http.ResponseWriter, _ *http.Request) {
	st.mu.RLock()
	names := make([]string, 0, len(st.series))
	for k := range st.series {
		names = append(names, k)
	}
	st.mu.RUnlock()
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(names)
}

// ─── Background retention sweep ───────────────────────────────────────────────

// Store is ring-buffer based so no explicit sweep needed.
// This exists to log store health periodically.
func (st *Store) LogHealth(interval time.Duration) {
	t := time.NewTicker(interval)
	defer t.Stop()
	for range t.C {
		st.mu.RLock()
		n := len(st.series)
		st.mu.RUnlock()
		_ = n // replace with slog in production
	}
}
