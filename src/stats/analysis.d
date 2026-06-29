// src/stats/analysis.d
// Muninn statistical layer.
// Consumes a rolling window of metric snapshots (JSON lines on stdin),
// computes histograms, percentiles, moving averages and anomaly scores,
// then emits a StatsReport JSON to stdout every REPORT_INTERVAL seconds.

module muninn.stats;

import std.stdio;
import std.json;
import std.algorithm : sort, sum;
import std.math      : sqrt, abs, isNaN;
import std.array     : array;
import std.conv      : to;
import std.datetime  : Clock;
import core.time     : seconds;

// ─── Histogram ───────────────────────────────────────────────────────────────

struct Histogram {
    double[] bounds;   // bucket upper bounds
    ulong[]  counts;

    this(double[] bounds) {
        this.bounds = bounds;
        this.counts = new ulong[](bounds.length + 1);
    }

    void record(double v) {
        foreach (i, b; bounds) {
            if (v <= b) { counts[i]++; return; }
        }
        counts[$ - 1]++;
    }

    void reset() { counts[] = 0; }

    // Returns (p50, p90, p99)
    auto percentiles() const {
        ulong total = counts[].sum;
        if (total == 0) return tuple(0.0, 0.0, 0.0);

        double p(double pct) {
            ulong target = cast(ulong)(pct / 100.0 * total);
            ulong acc    = 0;
            foreach (i, c; counts) {
                acc += c;
                if (acc >= target)
                    return i < bounds.length ? bounds[i] : bounds[$ - 1] * 1.1;
            }
            return bounds[$ - 1];
        }
        return tuple(p(50), p(90), p(99));
    }
}

// ─── EWMA (Exponentially Weighted Moving Average) ────────────────────────────

struct EWMA {
    double alpha;   // 0 < alpha < 1; smaller = slower decay
    double value;
    bool   init;

    this(double alpha) { this.alpha = alpha; this.value = 0.0; this.init = false; }

    void update(double v) {
        if (!init) { value = v; init = true; }
        else       value = alpha * v + (1.0 - alpha) * value;
    }
    double get() const { return value; }
}

// ─── Welford online variance ──────────────────────────────────────────────────

struct WelfordVar {
    ulong  n;
    double mean;
    double m2;

    void update(double x) {
        n++;
        double delta  = x - mean;
        mean         += delta / n;
        double delta2 = x - mean;
        m2           += delta * delta2;
    }
    double variance() const { return n < 2 ? 0.0 : m2 / (n - 1); }
    double stddev()   const { return sqrt(variance()); }
    double zscore(double x) const {
        double sd = stddev();
        return sd == 0 ? 0.0 : (x - mean) / sd;
    }
}

// ─── Per-metric tracker ───────────────────────────────────────────────────────

struct MetricTracker {
    string   name;
    EWMA     fast;     // α = 0.3 (~3s half-life at 1Hz)
    EWMA     slow;     // α = 0.05 (~20s half-life)
    WelfordVar var_;
    Histogram  hist;
    double   last;

    this(string name) {
        this.name = name;
        this.fast = EWMA(0.3);
        this.slow = EWMA(0.05);
        this.var_ = WelfordVar();
        // CPU/mem percentage buckets
        this.hist = Histogram([10.0,20,30,40,50,60,70,80,90,95,99,100]);
        this.last = double.nan;
    }

    void record(double v) {
        last = v;
        fast.update(v);
        slow.update(v);
        var_.update(v);
        hist.record(v);
    }

    // Positive z-score → unusually high; negative → unusually low
    double anomalyScore() const {
        return isNaN(last) ? 0.0 : var_.zscore(last);
    }
}

// ─── Main ─────────────────────────────────────────────────────────────────────

enum REPORT_INTERVAL = 10;   // emit stats every N seconds

void main() {
    auto trackers = [
        "cpu_pct"     : MetricTracker("cpu_pct"),
        "mem_pct"     : MetricTracker("mem_pct"),
        "load_one"    : MetricTracker("load_one"),
        "swap_pct"    : MetricTracker("swap_pct"),
    ];

    auto lastReport = Clock.currTime();

    foreach (line; stdin.byLine()) {
        JSONValue snap;
        try  { snap = parseJSON(line.idup); }
        catch(Exception) { continue; }

        // Extract scalars
        void feed(string key, lazy double v) {
            try {
                double d = v;
                if (key in trackers) trackers[key].record(d);
            } catch(Exception) {}
        }

        feed("cpu_pct",  snap["cpu_pct"].floating);
        feed("load_one", snap["load"]["one"].floating);

        if (auto mem = "mem" in snap) {
            ulong total = cast(ulong)(*mem)["total_kb"].integer;
            ulong avail = cast(ulong)(*mem)["available_kb"].integer;
            if (total > 0)
                feed("mem_pct", 100.0 * (total - avail) / total);
            ulong stot = cast(ulong)(*mem)["swap_total_kb"].integer;
            ulong sfree= cast(ulong)(*mem)["swap_free_kb"].integer;
            if (stot > 0)
                feed("swap_pct", 100.0 * (stot - sfree) / stot);
        }

        // Periodic report
        auto now = Clock.currTime();
        if ((now - lastReport).total!"seconds" >= REPORT_INTERVAL) {
            lastReport = now;
            emitReport(trackers);
        }
    }
}

void emitReport(MetricTracker[string] trackers) {
    auto obj = JSONValue(["type": JSONValue("stats_report"),
                          "ts":   JSONValue(Clock.currStdTime())]);
    JSONValue metrics;
    foreach (name, ref t; trackers) {
        auto pct = t.hist.percentiles();
        metrics[name] = JSONValue([
            "fast_ewma"    : JSONValue(t.fast.get()),
            "slow_ewma"    : JSONValue(t.slow.get()),
            "stddev"       : JSONValue(t.var_.stddev()),
            "mean"         : JSONValue(t.var_.mean),
            "anomaly_z"    : JSONValue(t.anomalyScore()),
            "p50"          : JSONValue(pct[0]),
            "p90"          : JSONValue(pct[1]),
            "p99"          : JSONValue(pct[2]),
            "samples"      : JSONValue(t.var_.n),
        ]);
    }
    obj["metrics"] = metrics;
    writeln(obj.toString());
    stdout.flush();
}
