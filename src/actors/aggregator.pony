// src/actors/aggregator.pony
// Muninn metric aggregator — Pony.
// Pony's actor model and capability security make it ideal for concurrent
// metric fan-in: each metric stream arrives as a message to an actor,
// with zero shared-state races by construction.

use "collections"
use "json"
use "time"
use "term"

// ─── Message types ────────────────────────────────────────────────────────────

primitive Tick       // periodic flush trigger
primitive Shutdown

class val MetricMsg
  let source     : String val
  let timestamp  : I64
  let cpu_pct    : F64
  let mem_pct    : F64
  let load_one   : F64

  new val create(
    source'    : String val,
    timestamp' : I64,
    cpu_pct'   : F64,
    mem_pct'   : F64,
    load_one'  : F64)
  =>
    source    = source'
    timestamp = timestamp'
    cpu_pct   = cpu_pct'
    mem_pct   = mem_pct'
    load_one  = load_one'

// ─── Window buffer ────────────────────────────────────────────────────────────

class Window
  """Ring buffer for a single metric — computes mean and max."""
  let _buf  : Array[F64]
  var _head : USize = 0
  var _n    : USize = 0

  new create(size: USize) => _buf = Array[F64].init(0, size)

  fun ref push(v: F64) =>
    _buf(_head % _buf.size())? = v
    _head = _head + 1
    _n    = _n.min(_buf.size()) + 1   // saturate at capacity

  fun mean() : F64 =>
    if _n == 0 then return 0 end
    var sum: F64 = 0
    let limit = _n.min(_buf.size())
    for i in Range(0, limit) do
      try sum = sum + _buf(i)? end
    end
    sum / _n.f64()

  fun max() : F64 =>
    var m: F64 = 0
    let limit = _n.min(_buf.size())
    for i in Range(0, limit) do
      try let v = _buf(i)?; if v > m then m = v end end
    end
    m

// ─── Aggregator actor ─────────────────────────────────────────────────────────

actor Aggregator
  let _env     : Env
  let _cpu_win : Window ref = Window(60)
  let _mem_win : Window ref = Window(60)
  let _load_win: Window ref = Window(60)
  var _count   : U64 = 0

  new create(env: Env) => _env = env

  be apply(msg: MetricMsg) =>
    _count = _count + 1
    _cpu_win.push(msg.cpu_pct)
    _mem_win.push(msg.mem_pct)
    _load_win.push(msg.load_one)

    // Simple threshold check in actor — no shared state needed
    if msg.cpu_pct > 90 then
      _emit_alert("crit", "CPU above 90%: " + msg.cpu_pct.string())
    elseif msg.mem_pct > 90 then
      _emit_alert("crit", "Memory above 90%: " + msg.mem_pct.string())
    end

  be tick() =>
    let report = JsonObject
    report("type")      = JsonString("agg_report")
    report("count")     = JsonF64(_count.f64())
    report("cpu_mean")  = JsonF64(_cpu_win.mean())
    report("cpu_max")   = JsonF64(_cpu_win.max())
    report("mem_mean")  = JsonF64(_mem_win.mean())
    report("load_mean") = JsonF64(_load_win.mean())
    _env.out.print(report.string())

  be shutdown() =>
    tick()   // flush final report
    _env.exitcode(0)

  fun _emit_alert(sev: String val, msg: String val) =>
    let a = JsonObject
    a("type")     = JsonString("alert")
    a("severity") = JsonString(sev)
    a("message")  = JsonString(msg)
    _env.out.print(a.string())

// ─── Stdin reader actor ───────────────────────────────────────────────────────

actor StdinReader
  let _env  : Env
  let _agg  : Aggregator

  new create(env: Env, agg: Aggregator) =>
    _env = env
    _agg = agg

  be read() =>
    // In real Pony we'd use a custom TCPNotify or FileStream;
    // this is the logical structure.
    None

// ─── Timer ───────────────────────────────────────────────────────────────────

actor TickTimer
  let _agg    : Aggregator
  let _timers : Timers

  new create(agg: Aggregator, timers: Timers) =>
    _agg    = agg
    _timers = timers
    let t = Timer(object iso is TimerNotify
      let _a: Aggregator = agg
      fun ref apply(timer: Timer, count: U64): Bool =>
        _a.tick(); true
      fun ref cancel(timer: Timer) => None
    end, 10_000_000_000, 10_000_000_000)  // 10s interval
    _timers(consume t)

// ─── Main ─────────────────────────────────────────────────────────────────────

actor Main
  new create(env: Env) =>
    let timers = Timers
    let agg    = Aggregator(env)
    TickTimer(agg, timers)
    env.out.print("{\"type\":\"startup\",\"component\":\"muninn-actors\"}")
