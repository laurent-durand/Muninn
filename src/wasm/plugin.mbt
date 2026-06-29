// src/wasm/plugin.mbt
// Muninn WASM plugin sandbox — MoonBit.
// MoonBit compiles to compact WebAssembly; plugins run in an isolated WASM
// sandbox with no filesystem or network access. The host (Go broker) calls
// the exported transform() and check() functions via wazero.

// ─── Exported ABI ─────────────────────────────────────────────────────────────
// All values cross the WASM boundary as i64/f64 packed structs.
// Strings are written into a shared memory region before calling.

struct CpuSnapshot {
  cpu_pct  : Double
  mem_pct  : Double
  load_one : Double
  ts_ms    : Int64
}

struct AlertOut {
  severity : Int    // 0=ok 1=warn 2=crit
  message  : String
  value    : Double
}

// ─── Transform pipeline ───────────────────────────────────────────────────────

// Normalise cpu_pct to 0.0–1.0 and apply a smoothing factor
fn normalise(snap : CpuSnapshot) -> Double {
  snap.cpu_pct / 100.0
}

// Composite pressure: weighted CPU + memory
fn pressure_score(snap : CpuSnapshot) -> Double {
  let w_cpu = 0.6
  let w_mem = 0.4
  w_cpu * snap.cpu_pct + w_mem * snap.mem_pct
}

// Classify pressure into a severity level
fn classify(score : Double) -> Int {
  if score >= 90.0 { 2 }
  else if score >= 70.0 { 1 }
  else { 0 }
}

// ─── Exported functions ────────────────────────────────────────────────────────

pub fn transform(cpu: Double, mem: Double, load: Double, ts: Int64) -> Double {
  let snap = { cpu_pct: cpu, mem_pct: mem, load_one: load, ts_ms: ts }
  pressure_score(snap)
}

pub fn check_threshold(cpu: Double, mem: Double, load: Double) -> Int {
  let snap = { cpu_pct: cpu, mem_pct: mem, load_one: load, ts_ms: 0L }
  classify(pressure_score(snap))
}

// Batch transform: process N snapshots stored in linear arrays
// Returns sum of pressure scores (host aggregates)
pub fn batch_transform(
  cpus  : Array[Double],
  mems  : Array[Double],
  loads : Array[Double]
) -> Double {
  let n = cpus.length()
  var total = 0.0
  for i = 0; i < n; i = i + 1 {
    let snap : CpuSnapshot = {
      cpu_pct:  cpus[i],
      mem_pct:  mems[i],
      load_one: loads[i],
      ts_ms:    0L
    }
    total = total + pressure_score(snap)
  }
  total / n.to_double()
}

// ─── Alert rule (runs fully inside WASM, no host calls needed) ────────────────

struct RuleState {
  above_since : Int64   // ms timestamp when threshold first exceeded, 0 = below
  last_fire   : Int64
}

let mut state : RuleState = { above_since: 0L, last_fire: 0L }

pub fn eval_alert(
  cpu_pct  : Double,
  mem_pct  : Double,
  ts_ms    : Int64,
  warn     : Double,
  crit     : Double,
  duration : Int64    // ms
) -> Int {
  // Returns 0=no fire, 1=warn, 2=crit
  let score = 0.6 * cpu_pct + 0.4 * mem_pct
  if score >= warn {
    if state.above_since == 0L {
      state = { ..state, above_since: ts_ms }
    }
    let elapsed = ts_ms - state.above_since
    if elapsed >= duration {
      let sev = if score >= crit { 2 } else { 1 }
      state = { ..state, last_fire: ts_ms }
      return sev
    }
  } else {
    state = { above_since: 0L, last_fire: state.last_fire }
  }
  0
}
