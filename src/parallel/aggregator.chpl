// src/parallel/aggregator.chpl
// Muninn parallel aggregator — Chapel.
// Chapel's data-parallel constructs let us aggregate metrics across
// many nodes/cores using forall loops and distributed arrays.
// Here: parallel percentile computation over a large history buffer.

use Time;
use IO;
use JSON;
use Math;
use Sort;
use List;

// ─── Configuration ────────────────────────────────────────────────────────────

config const windowSize  : int = 3600;    // 1h at 1Hz
config const reportEvery : int = 60;      // emit summary every N snapshots
config const nWorkers    : int = here.maxTaskPar;

// ─── Snapshot record ──────────────────────────────────────────────────────────

record Snapshot {
  var timestamp_ms : int;
  var cpu_pct      : real;
  var mem_pct      : real;
  var load_one     : real;
}

// ─── Parallel percentile computation ─────────────────────────────────────────

// Sort-based percentile using Chapel's built-in sort
proc percentile(arr: [] real, p: real) : real {
  if arr.size == 0 then return 0.0;
  var sorted = arr;
  sort(sorted);
  var idx_f = p / 100.0 * (sorted.size - 1);
  var lo    = idx_f : int;
  var hi    = min(lo + 1, sorted.size - 1);
  var frac  = idx_f - lo;
  return sorted[lo] * (1.0 - frac) + sorted[hi] * frac;
}

// Parallel mean using forall reduction
proc parallelMean(arr: [] real) : real {
  var s: real = 0.0;
  forall v in arr with (+ reduce s) do s += v;
  return s / arr.size;
}

// Parallel variance (two-pass)
proc parallelVariance(arr: [] real) : real {
  var mu = parallelMean(arr);
  var s2: real = 0.0;
  forall v in arr with (+ reduce s2) do s2 += (v - mu) ** 2;
  return s2 / arr.size;
}

proc parallelStddev(arr: [] real) : real {
  return sqrt(parallelVariance(arr));
}

// ─── Rolling window ───────────────────────────────────────────────────────────

class RingBuffer {
  var capacity : int;
  var buf      : [0..#capacity] real;
  var head     : int = 0;
  var n        : int = 0;

  proc push(v: real) {
    buf[head % capacity] = v;
    head += 1;
    if n < capacity then n += 1;
  }

  proc slice() : [] real {
    var out: [0..#n] real;
    for i in 0..#n do
      out[i] = buf[(head - n + i + capacity) % capacity];
    return out;
  }
}

// ─── Report ───────────────────────────────────────────────────────────────────

proc emitReport(cpu: RingBuffer, mem: RingBuffer, load: RingBuffer) {
  var ca = cpu.slice();
  var ma = mem.slice();
  var la = load.slice();

  var cpu_mean   = parallelMean(ca);
  var cpu_std    = parallelStddev(ca);
  var cpu_p50    = percentile(ca, 50);
  var cpu_p90    = percentile(ca, 90);
  var cpu_p99    = percentile(ca, 99);
  var mem_mean   = parallelMean(ma);
  var load_mean  = parallelMean(la);

  writef(
    "{\"type\":\"parallel_report\",\"n\":%i," +
    "\"cpu_mean\":%.2r,\"cpu_std\":%.2r," +
    "\"cpu_p50\":%.2r,\"cpu_p90\":%.2r,\"cpu_p99\":%.2r," +
    "\"mem_mean\":%.2r,\"load_mean\":%.3r," +
    "\"workers\":%i}\n",
    ca.size, cpu_mean, cpu_std,
    cpu_p50, cpu_p90, cpu_p99,
    mem_mean, load_mean, nWorkers
  );
  stdout.flush();
}

// ─── Main ─────────────────────────────────────────────────────────────────────

proc main() {
  var cpu_ring  = new RingBuffer(windowSize);
  var mem_ring  = new RingBuffer(windowSize);
  var load_ring = new RingBuffer(windowSize);
  var count     = 0;

  stderr.writeln("muninn-parallel: " + nWorkers:string + " workers, window=" +
                 windowSize:string);

  for line in stdin.lines() {
    var trimmed = line.strip();
    if trimmed == "" then continue;

    // Minimal JSON field extraction (no full parser dep)
    proc extractFloat(src: string, key: string): real {
      var pattern = '"' + key + '":';
      var pos     = src.find(pattern);
      if pos < 0 then return 0.0;
      var start = pos + pattern.size;
      var end_  = start;
      while end_ < src.size && (src[end_]:string).matches(/[0-9.\-]/) do end_ += 1;
      return try! src[start..end_-1]:real;
    }

    var cpu  = extractFloat(trimmed, "cpu_pct");
    var load = extractFloat(trimmed, "one");    // nested field simplified

    var mem_total = extractFloat(trimmed, "total_kb");
    var mem_avail = extractFloat(trimmed, "available_kb");
    var mem_pct   = mem_total > 0.0 ? (mem_total - mem_avail) / mem_total * 100.0 : 0.0;

    cpu_ring.push(cpu);
    mem_ring.push(mem_pct);
    load_ring.push(load);
    count += 1;

    if count % reportEvery == 0 then
      emitReport(cpu_ring, mem_ring, load_ring);
  }

  // Final flush
  emitReport(cpu_ring, mem_ring, load_ring);
}
