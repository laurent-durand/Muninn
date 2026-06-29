// src/fx/middleware.kk
// Muninn middleware — Koka.
// Uses algebraic effects to build a composable metric processing pipeline.
// Effects model: read a snapshot → transform → filter → emit.
// Each stage is an effect handler; the pipeline is assembled by composition.

module middleware

import std/core
import std/text/json

// ─── Effect declarations ──────────────────────────────────────────────────────

// Source effect: yields raw JSON strings
effect source
  fun next-line() : maybe<string>

// Sink effect: consumes processed payloads
effect sink
  fun emit(payload : string) : ()

// Log effect for structured logging
effect logger
  fun log-info(msg : string)  : ()
  fun log-warn(msg : string)  : ()
  fun log-error(msg : string) : ()

// Metric extraction helper
effect metrics
  fun get-float(snap : json, key : string) : maybe<float64>

// ─── Snapshot type ────────────────────────────────────────────────────────────

struct snapshot
  timestamp-ms : int
  cpu-pct      : float64
  mem-total-kb : int
  mem-avail-kb : int
  load-one     : float64

fun mem-used-pct(s : snapshot) : float64
  val total = s.mem-total-kb.float64
  if total <= 0.0 then 0.0
  else (total - s.mem-avail-kb.float64) / total * 100.0

// ─── Metric handlers ──────────────────────────────────────────────────────────

// Parse a JSON line into a Snapshot
fun parse-snapshot(line : string) : maybe<snapshot>
  match line.parse-json
    Nothing -> Nothing
    Just(j) ->
      with handler
        fun get-float(snap, key)
          match snap.field(key)
            Just(JFloat(f)) -> Just(f)
            Just(JInt(i))   -> Just(i.float64)
            _               -> Nothing
      Just(Snapshot(
        timestamp-ms = j.field("timestamp_ms").default(JInt(0)).as-int.default(0),
        cpu-pct      = get-float(j, "cpu_pct").default(0.0),
        mem-total-kb = j.field("mem").then(fn(m) m.field("total_kb")).flatmap(as-int).default(0),
        mem-avail-kb = j.field("mem").then(fn(m) m.field("available_kb")).flatmap(as-int).default(0),
        load-one     = j.field("load").then(fn(l) l.field("one")).flatmap(as-float).default(0.0),
      ))

// ─── Pipeline stages ──────────────────────────────────────────────────────────

// Stage 1: validate — drop malformed snapshots
fun stage-validate(snap : snapshot) : maybe<snapshot>
  if snap.timestamp-ms <= 0 then
    log-warn("dropping snapshot with zero timestamp")
    Nothing
  elif snap.cpu-pct < 0.0 || snap.cpu-pct > 100.0 then
    log-warn("cpu_pct out of range: " ++ snap.cpu-pct.show)
    Nothing
  else
    Just(snap)

// Stage 2: enrich — add derived fields
struct enriched
  snap     : snapshot
  mem-pct  : float64
  pressure : float64   // composite pressure score

fun stage-enrich(snap : snapshot) : enriched
  val mem = snap.mem-used-pct
  val pressure = 0.6 * snap.cpu-pct + 0.4 * mem
  Enriched(snap = snap, mem-pct = mem, pressure = pressure)

// Stage 3: threshold filter — forward only anomalous snapshots (or all)
fun stage-threshold(e : enriched, all : bool) : bool
  all || e.snap.cpu-pct > 70.0 || e.mem-pct > 80.0 || e.pressure > 75.0

// Stage 4: serialise back to JSON
fun stage-serialise(e : enriched) : string
  "{\"ts\":" ++ e.snap.timestamp-ms.show ++
  ",\"cpu\":" ++ e.snap.cpu-pct.show-fixed(2) ++
  ",\"mem_pct\":" ++ e.mem-pct.show-fixed(2) ++
  ",\"pressure\":" ++ e.pressure.show-fixed(2) ++
  ",\"load1\":" ++ e.snap.load-one.show-fixed(3) ++ "}"

// ─── Pipeline assembly ────────────────────────────────────────────────────────

fun run-pipeline(emit-all : bool) : <source,sink,logger,console,exn> ()
  loop
    match next-line()
      Nothing -> return ()
      Just(line) ->
        match parse-snapshot(line)
          Nothing ->
            log-warn("parse failure: " ++ line.first(80))
          Just(snap) ->
            match stage-validate(snap)
              Nothing -> ()
              Just(valid) ->
                val enriched = stage-enrich(valid)
                if stage-threshold(enriched, emit-all) then
                  emit(stage-serialise(enriched))

// ─── Effect handlers (IO) ─────────────────────────────────────────────────────

fun with-stdin-source(action : () -> <source|e> a) : <console|e> a
  with handler
    fun next-line()
      val line = readline()
      if line == "" then Nothing else Just(line)
  action()

fun with-stdout-sink(action : () -> <sink|e> a) : <console|e> a
  with handler
    fun emit(payload)
      println(payload)
  action()

fun with-stderr-logger(action : () -> <logger|e> a) : <console|e> a
  with handler
    fun log-info(msg)  print("[INFO] "  ++ msg ++ "\n")
    fun log-warn(msg)  print("[WARN] "  ++ msg ++ "\n")
    fun log-error(msg) print("[ERROR] " ++ msg ++ "\n")
  action()

// ─── Entry point ──────────────────────────────────────────────────────────────

fun main()
  with with-stderr-logger
  with with-stdin-source
  with with-stdout-sink
  log-info("muninn-fx middleware starting")
  run-pipeline(emit-all = False)
  log-info("muninn-fx done")
