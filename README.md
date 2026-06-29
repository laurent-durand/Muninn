# ◈ Muninn

> *One of Odin's ravens. Every day he flies across the nine worlds and returns to whisper what he has seen. His name means **Memory**.*

A polyglot TUI system monitor for Linux. Each component is written in the language best suited to its role. No compromises on performance.

[![License: GPL v3](https://img.shields.io/badge/License-GPLv3-blue.svg)](LICENSE)
[![Languages](https://img.shields.io/badge/languages-29-purple)](src/)

---

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                          muninn-tui  (Odin)                     │
│                      Terminal UI · ANSI · widgets               │
└───────────────────────────┬─────────────────────────────────────┘
                            │ WebSocket / JSON
┌───────────────────────────▼─────────────────────────────────────┐
│                      muninn-api  (Go)                           │
│          Central broker · HTTP REST · WebSocket · NATS pub      │
└──┬──────────┬──────────┬──────────┬──────────┬──────────────────┘
   │          │          │          │          │
   ▼          ▼          ▼          ▼          ▼
muninn-   muninn-    muninn-    muninn-    muninn-
core      net        rules      stats      logs
(Zig)     (Rust)     (OCaml)    (D)        (Crystal)
/proc     /proc/net  alert DSL  histograms log tail
metrics   bandwidth  inference  percentiles aggregation
```

```
Additional components (connected via NATS or pipe):

  muninn-syscall  (Hare)       — raw /proc process tree
  muninn-fanout   (Gleam)      — BEAM concurrent fan-out
  muninn-watchdog (Ada)        — process supervisor
  muninn-config   (Nim)        — TOML config + alert thresholds
  muninn-proctree (V)          — process tree walker
  muninn-parallel (Chapel)     — parallel percentile aggregation
  muninn-pipeline (Koka)       — effect-based middleware
  muninn-analysis (Julia)      — Holt-Winters, PCA anomaly, CUSUM
  muninn-actors   (Pony)       — actor-model metric fan-in

Scripting / DSL layer (loaded at runtime):
  src/script/   (Janet)        — hot-reloadable dashboard layout
  src/dsl/      (Fennel)       — Lisp rule DSL → Lua
  src/embed/    (Wren)         — embedded widget scripting
  src/plugins/  (Lua)          — sandboxed plugin host
  src/proto_io/ (Io)           — prototype-based plugin API
  src/micro/    (Forth)        — μ-scripting for constrained targets

Array / math layer:
  src/array/    (BQN)          — array-based rolling stats
  src/array/    (Uiua)         — stack-array metric transforms

WASM sandbox (untrusted plugins):
  src/wasm/     (MoonBit)      — compact WASM plugin
  src/grain_wasm/ (Grain)      — functional WASM plugin

Integration:
  src/legacy/   (Tcl)          — SNMP bridge + legacy Tk dashboard
  src/infer/    (Prolog)       — logical alert inference
  src/stack/    (Factor)       — concatenative metric processing
  src/parse/    (AWK)          — zero-dep log parsing
  src/shell/    (Elvish)       — shell integration + completions
```

---

## Language roster

| # | Language | Component | Role |
|---|----------|-----------|------|
| 1 | **Zig** | `muninn-core` | `/proc` metrics harvesting — zero-alloc hot path |
| 2 | **Odin** | `muninn-tui` | ANSI TUI renderer |
| 3 | **Rust** | `muninn-net` | Network interface bandwidth via `/proc/net/dev` |
| 4 | **Go** | `muninn-api` | Central broker, HTTP REST, WebSocket, NATS |
| 5 | **Nim** | `muninn-config` | TOML config parser + alerting thresholds |
| 6 | **OCaml** | `muninn-rules` | Algebraic alert rule DSL with temporal logic |
| 7 | **D** | `muninn-stats` | EWMA, Welford variance, histograms, percentiles |
| 8 | **Crystal** | `muninn-logs` | Concurrent log tail + syslog aggregation |
| 9 | **Hare** | `muninn-syscall` | Raw procfs bindings, process tree |
| 10 | **Gleam** | `muninn-fanout` | BEAM actor-based concurrent fan-out |
| 11 | **Ada** | `muninn-watchdog` | Tasking-based process supervisor |
| 12 | **V** | `muninn-proctree` | Process tree walker |
| 13 | **Chapel** | `muninn-parallel` | Parallel percentile computation with `forall` |
| 14 | **Julia** | `muninn-analysis` | Holt-Winters forecast, PCA anomaly, CUSUM |
| 15 | **Pony** | `muninn-actors` | Actor-model concurrent metric aggregation |
| 16 | **Koka** | `muninn-pipeline` | Effect-based middleware pipeline |
| 17 | **Janet** | scripting | Hot-reloadable dashboard layout scripting |
| 18 | **Fennel** | DSL | Lisp rule DSL that compiles to Lua |
| 19 | **Lua** | plugins | Sandboxed plugin host |
| 20 | **Wren** | embed | Lightweight embeddable widget scripting |
| 21 | **Io** | proto_io | Prototype-based plugin API |
| 22 | **Forth** | micro | Near-zero-footprint scripting for constrained targets |
| 23 | **MoonBit** | wasm | Compact WASM plugin sandbox |
| 24 | **Grain** | grain_wasm | Functional WASM plugin |
| 25 | **Roc** | pipeline | Pure functional transformation pipeline |
| 26 | **BQN** | array | Array-based rolling statistics |
| 27 | **Uiua** | array | Stack-array metric transforms |
| 28 | **Prolog** | infer | Logical alert inference (SWI-Prolog) |
| 29 | **Factor** | stack | Concatenative metric processing |
| 30 | **AWK** | parse | Zero-dependency log parsing |
| 31 | **Tcl** | legacy | SNMP bridge + legacy Tk dashboard |
| 32 | **C3** | c3fmt | Terminal string formatting library |
| 33 | **Elvish** | shell | Shell integration + tab completions |

---

## What it monitors

- **CPU** — per-core utilisation, user/system/iowait split, steal time
- **Memory** — used/cached/buffers, swap, slab
- **Network** — per-interface rx/tx bps, pps, errors, drops
- **Disk** — utilisation, IOPS, latency, inode usage
- **Processes** — top-N by RSS/CPU, process tree, thread count
- **Load average** — 1m / 5m / 15m
- **Logs** — error rate, OOM events, I/O errors, kernel panics

---

## Building

### Requirements

| Tool | Version | Used by |
|------|---------|---------|
| Zig | ≥ 0.13 | core |
| Odin | latest nightly | tui |
| Rust + Cargo | ≥ 1.80 | net |
| Go | ≥ 1.22 | api |
| Nim | ≥ 2.0 | config |
| OCaml + opam + dune | ≥ 5.1 | rules |
| D + dub | ≥ 2.107 | stats |
| Crystal | ≥ 1.13 | logs |
| Hare | latest | syscall |
| Gleam | ≥ 1.3 | fanout |
| GNAT (Ada) | ≥ 13 | watchdog |
| V | ≥ 0.4 | proctree |
| Chapel | ≥ 2.1 | parallel |
| Julia | ≥ 1.10 | analysis (opt-in) |
| Pony | ≥ 0.58 | actors |

### Quick build

```bash
# Build all compiled components
make build

# Or component by component
make core net api config rules
```

### Docker (recommended)

```bash
docker compose up --build
```

The Julia analysis service is opt-in (heavy JIT startup):

```bash
docker compose --profile analysis up
```

---

## Running

### Dev mode (binaries piped together)

```bash
make run-dev
# Equivalent to:
# out/muninn-core | tee >(out/muninn-api) >(out/muninn-rules) >(out/muninn-stats) | out/muninn-tui
```

### Production

```bash
docker compose up -d
# TUI connects to broker at http://localhost:7777
out/muninn-tui
```

---

## Configuration

Copy and edit `muninn.toml`:

```toml
interval_ms    = 1000
nats_url       = "nats://127.0.0.1:4222"
listen_addr    = ":7777"
history_hours  = 24

[[rule]]
metric   = "cpu_pct"
warn     = 70.0
crit     = 90.0
duration = 10       # seconds before firing

[[rule]]
metric   = "mem_used_pct"
warn     = 80.0
crit     = 95.0
duration = 5

[plugins]
dirs = ["/etc/muninn/plugins"]
```

---

## Shell integration (Elvish)

```elvish
# Add to ~/.config/elvish/rc.elv
use /path/to/muninn/src/shell/muninn

muninn status          # one-line status bar
muninn tail            # live stream
muninn ps-top 20       # top 20 processes
muninn alerts          # recent alert history
```

---

## Writing a plugin (Lua)

```lua
-- /etc/muninn/plugins/my_plugin.lua
return {
  name    = "my-plugin",
  version = "1.0.0",

  on_snapshot = function(snap)
    if snap.cpu_pct > 95 then
      emit_alert("crit", "CPU maxed out: " .. snap.cpu_pct .. "%")
    end
  end,
}
```

---

## Inter-process communication

```
muninn-core  ──stdout JSON──►  muninn-api  ──NATS muninn.metrics──►  all subscribers
muninn-net   ──stdout JSON──►  muninn-api
muninn-rules ◄──NATS subscribe── muninn-api ──NATS muninn.alerts──►  muninn-tui
```

All JSON lines conform to the schema in `proto/muninn.proto`.

---

## Naming

**Muninn** (Old Norse: *Huginn ok Muninn*) is one of the two ravens of Odin. Each day he circles Midgard and returns to Odin's shoulder to whisper everything he has observed. His name means *Memory* or *Mind*. A system monitor that gathers information from every corner of the machine and remembers it — fitting.

---

## License

GNU General Public License v3.0 — see [LICENSE](LICENSE).
