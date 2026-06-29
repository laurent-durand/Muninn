// src/api/main.go
// muninn-api — central broker.
//
// Reads newline-delimited JSON from muninn-core (Zig) on stdin,
// republishes to:
//   • NATS subject "muninn.metrics"   (internal subscribers)
//   • WebSocket endpoint /ws/metrics  (TUI and web clients)
//   • In-memory ring buffer           (REST /api/history)
//
// Alert snapshots from muninn-rules (OCaml) arrive on NATS "muninn.alerts"
// and are forwarded to WebSocket clients.

package main

import (
	"bufio"
	"context"
	"encoding/json"
	"flag"
	"log/slog"
	"net/http"
	"os"
	"sync"
	"time"

	"github.com/gorilla/websocket"
	"github.com/nats-io/nats.go"
)

// ─── Config ──────────────────────────────────────────────────────────────────

type Config struct {
	ListenAddr  string
	NatsURL     string
	HistorySize int
	IntervalMs  int
}

func defaultConfig() Config {
	return Config{
		ListenAddr:  ":7777",
		NatsURL:     nats.DefaultURL,
		HistorySize: 3600, // 1 h at 1 Hz
		IntervalMs:  1000,
	}
}

// ─── Snapshot (mirrors Zig output) ───────────────────────────────────────────

type Snapshot struct {
	TimestampMs int64       `json:"timestamp_ms"`
	CpuPct      float64     `json:"cpu_pct"`
	Mem         MemInfo     `json:"mem"`
	Load        LoadAvg     `json:"load"`
	Net         []NetStat   `json:"net"`
}

type MemInfo  struct {
	TotalKb     uint64 `json:"total_kb"`
	AvailableKb uint64 `json:"available_kb"`
	CachedKb    uint64 `json:"cached_kb"`
	SwapTotalKb uint64 `json:"swap_total_kb"`
	SwapFreeKb  uint64 `json:"swap_free_kb"`
}
type LoadAvg  struct{ One, Five, Fifteen float64 }
type NetStat  struct {
	Iface     string `json:"iface"`
	RxBytes   uint64 `json:"rx_bytes"`
	TxBytes   uint64 `json:"tx_bytes"`
	RxPackets uint64 `json:"rx_packets"`
	TxPackets uint64 `json:"tx_packets"`
}

// ─── Ring buffer ─────────────────────────────────────────────────────────────

type Ring struct {
	mu   sync.RWMutex
	buf  []json.RawMessage
	head int
	size int
}

func newRing(n int) *Ring { return &Ring{buf: make([]json.RawMessage, n), size: n} }

func (r *Ring) Push(raw json.RawMessage) {
	r.mu.Lock()
	r.buf[r.head%r.size] = raw
	r.head++
	r.mu.Unlock()
}

func (r *Ring) Slice(n int) []json.RawMessage {
	r.mu.RLock()
	defer r.mu.RUnlock()
	if n > r.head { n = r.head }
	out := make([]json.RawMessage, n)
	for i := 0; i < n; i++ {
		out[i] = r.buf[(r.head-n+i)%r.size]
	}
	return out
}

// ─── Hub (WebSocket fan-out) ──────────────────────────────────────────────────

type Hub struct {
	mu      sync.Mutex
	clients map[*websocket.Conn]struct{}
}

func newHub() *Hub { return &Hub{clients: make(map[*websocket.Conn]struct{})} }

func (h *Hub) Add(c *websocket.Conn) {
	h.mu.Lock(); h.clients[c] = struct{}{}; h.mu.Unlock()
}
func (h *Hub) Remove(c *websocket.Conn) {
	h.mu.Lock(); delete(h.clients, c); h.mu.Unlock()
}
func (h *Hub) Broadcast(msg []byte) {
	h.mu.Lock()
	defer h.mu.Unlock()
	for c := range h.clients {
		if err := c.WriteMessage(websocket.TextMessage, msg); err != nil {
			c.Close()
			delete(h.clients, c)
		}
	}
}

// ─── Main ────────────────────────────────────────────────────────────────────

func main() {
	cfg := defaultConfig()
	flag.StringVar(&cfg.ListenAddr, "listen", cfg.ListenAddr, "HTTP listen address")
	flag.StringVar(&cfg.NatsURL, "nats", cfg.NatsURL, "NATS server URL")
	flag.Parse()

	log := slog.New(slog.NewTextHandler(os.Stderr, nil))
	log.Info("muninn-api starting", "listen", cfg.ListenAddr, "nats", cfg.NatsURL)

	nc, err := nats.Connect(cfg.NatsURL)
	if err != nil {
		log.Warn("NATS unavailable, running without it", "err", err)
	}

	ring := newRing(cfg.HistorySize)
	hub  := newHub()
	up   := websocket.Upgrader{CheckOrigin: func(*http.Request) bool { return true }}

	// ── Ingest from stdin (muninn-core pipe) ──────────────────────────────
	go func() {
		scanner := bufio.NewScanner(os.Stdin)
		scanner.Buffer(make([]byte, 1<<20), 1<<20)
		for scanner.Scan() {
			raw := json.RawMessage(scanner.Bytes())
			ring.Push(raw)
			hub.Broadcast(raw)
			if nc != nil {
				_ = nc.Publish("muninn.metrics", raw)
			}
		}
		log.Error("stdin closed", "err", scanner.Err())
		os.Exit(1)
	}()

	// ── HTTP routes ────────────────────────────────────────────────────────
	mux := http.NewServeMux()

	mux.HandleFunc("/healthz", func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte("ok"))
	})

	mux.HandleFunc("/api/snapshot", func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		snaps := ring.Slice(1)
		if len(snaps) == 0 {
			http.Error(w, `{"error":"no data yet"}`, http.StatusServiceUnavailable)
			return
		}
		_, _ = w.Write(snaps[0])
	})

	mux.HandleFunc("/api/history", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		n := 60
		snaps := ring.Slice(n)
		enc   := json.NewEncoder(w)
		_ = enc.Encode(snaps)
	})

	mux.HandleFunc("/ws/metrics", func(w http.ResponseWriter, r *http.Request) {
		conn, err := up.Upgrade(w, r, nil)
		if err != nil {
			log.Warn("WS upgrade failed", "err", err)
			return
		}
		hub.Add(conn)
		defer hub.Remove(conn)
		// block until the client disconnects
		for {
			if _, _, err := conn.ReadMessage(); err != nil {
				break
			}
		}
	})

	srv := &http.Server{
		Addr:         cfg.ListenAddr,
		Handler:      mux,
		ReadTimeout:  5 * time.Second,
		WriteTimeout: 10 * time.Second,
	}

	log.Info("HTTP server ready", "addr", cfg.ListenAddr)
	ctx := context.Background()
	_ = ctx
	if err := srv.ListenAndServe(); err != nil {
		log.Error("server error", "err", err)
		os.Exit(1)
	}
}
