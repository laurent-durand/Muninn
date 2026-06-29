// src/embed/muninn.wren
// Muninn embedded scripting — Wren.
// Wren is a small, fast, class-based scripting language designed to be
// embedded in C applications. The Muninn TUI embeds the Wren VM to let
// users define custom widgets and metric transforms without recompiling.

// ─── Metric class ─────────────────────────────────────────────────────────────

class Metric {
  construct new(name, value) {
    _name  = name
    _value = value
  }

  name  { _name  }
  value { _value }

  // Format value as percentage bar
  bar(width) {
    var filled = (_value.clamp(0, 100) / 100 * width).floor
    var bar    = ""
    for (i in 0...filled)  bar = bar + "█"
    for (i in filled...width) bar = bar + "░"
    return bar
  }

  toString { "Metric(%(_name): %(_value))" }
}

// ─── Snapshot class ───────────────────────────────────────────────────────────

class Snapshot {
  construct new(map) {
    _ts      = map["timestamp_ms"] || 0
    _cpu     = map["cpu_pct"]      || 0.0
    _mem     = map["mem"]          || {}
    _load    = map["load"]         || {}
    _net     = map["net"]          || []
  }

  timestampMs { _ts  }
  cpuPct      { _cpu }

  memUsedPct {
    var total = _mem["total_kb"] || 0
    var avail = _mem["available_kb"] || 0
    if (total == 0) return 0.0
    return (total - avail) / total * 100
  }

  swapPct {
    var total = _mem["swap_total_kb"] || 0
    var free  = _mem["swap_free_kb"]  || 0
    if (total == 0) return 0.0
    return (total - free) / total * 100
  }

  loadOne    { _load["one"]     || 0.0 }
  loadFive   { _load["five"]    || 0.0 }
  loadFifteen{ _load["fifteen"] || 0.0 }

  metrics {
    return [
      Metric.new("cpu",  _cpu),
      Metric.new("mem",  memUsedPct),
      Metric.new("swap", swapPct),
      Metric.new("load", loadOne),
    ]
  }
}

// ─── Widget base class ────────────────────────────────────────────────────────

class Widget {
  construct new(name) { _name = name }
  name { _name }

  // Override in subclasses
  render(snap) { "[Widget: %(_name)]" }
}

// ─── Built-in widgets ─────────────────────────────────────────────────────────

class GaugeWidget is Widget {
  construct new(name, metric_fn, warn, crit) {
    super(name)
    _metric_fn = metric_fn
    _warn = warn
    _crit = crit
  }

  severity(value) {
    if (value >= _crit) return "\e[31m"  // red
    if (value >= _warn) return "\e[33m"  // yellow
    return "\e[32m"                       // green
  }

  render(snap) {
    var value = _metric_fn.call(snap)
    var bar   = Metric.new(name, value).bar(40)
    var col   = severity(value)
    return "%( col )%(name) [%(bar)] %(value.toStringFixed(1))%\e[0m"
  }
}

class SparklineWidget is Widget {
  construct new(name) {
    super(name)
    _history = []
  }

  push(value) {
    _history.add(value)
    if (_history.count > 60) _history.removeAt(0)
  }

  render(snap) {
    var sparks = "▁▂▃▄▅▆▇█"
    var out    = name + "  "
    for (v in _history) {
      var i = ((v / 100) * 7).clamp(0, 7).floor
      out = out + sparks[i..i]
    }
    return out
  }
}

class AlertWidget is Widget {
  construct new() {
    super("alerts")
    _alerts = []
  }

  add(alert) {
    _alerts.add(alert)
    if (_alerts.count > 10) _alerts.removeAt(0)
  }

  render(snap) {
    if (_alerts.isEmpty) return "  \e[32m✓ no active alerts\e[0m"
    var out = ""
    for (a in _alerts) {
      var col = a["severity"] == "crit" ? "\e[31m" : "\e[33m"
      out = out + "  %(col)● %(a["message"])\e[0m\n"
    }
    return out
  }
}

// ─── Dashboard ────────────────────────────────────────────────────────────────

class Dashboard {
  construct new() {
    _widgets = [
      GaugeWidget.new("CPU",  Fn.new { |s| s.cpuPct      }, 70, 90),
      GaugeWidget.new("MEM",  Fn.new { |s| s.memUsedPct  }, 80, 95),
      GaugeWidget.new("SWAP", Fn.new { |s| s.swapPct     }, 50, 80),
      GaugeWidget.new("LOAD", Fn.new { |s| s.loadOne     }, 8,  16),
    ]
    _spark  = SparklineWidget.new("CPU60s")
    _alerts = AlertWidget.new()
  }

  update(snap) {
    _spark.push(snap.cpuPct)
  }

  render(snap) {
    System.print("\e[2J\e[H")
    System.print("\e[35m\e[1m ◈ MUNINN  \e[0m\e[2m Wren scripted dashboard\e[0m\n")
    for (w in _widgets)    System.print(w.render(snap))
    System.print(_spark.render(snap))
    System.print(_alerts.render(snap))
  }
}

// ─── Entry point (called from C host via wren_call) ───────────────────────────

var dashboard = Dashboard.new()

class MuninnPlugin {
  static onSnapshot(snapMap) {
    var snap = Snapshot.new(snapMap)
    dashboard.update(snap)
    dashboard.render(snap)
  }

  static onAlert(alertMap) {
    // Forwarded to alert widget — C host calls this
  }
}
