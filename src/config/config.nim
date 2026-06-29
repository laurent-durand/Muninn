# src/config/config.nim
# Muninn configuration layer.
# Parses muninn.toml, validates ranges, exposes typed Config object.
# Also houses the alerting threshold engine — evaluates incoming snapshots
# and emits Alert records via stdout (JSON lines) when thresholds are crossed.

import std/[os, strutils, strformat, tables, times, json, options]

# ─── Types ────────────────────────────────────────────────────────────────────

type
  Severity* = enum
    Info = "info"
    Warn = "warn"
    Crit = "crit"
    Dead = "dead"

  ThresholdRule* = object
    metric*:   string     ## e.g. "cpu_pct", "mem_used_pct"
    warn*:     float      ## yellow threshold
    crit*:     float      ## red threshold
    duration*: int        ## must stay above for N seconds before firing

  AlertState* = object
    rule*:     ThresholdRule
    since*:    float           ## epoch time when threshold first exceeded
    fired*:    bool

  Config* = object
    interval_ms*:    int
    nats_url*:       string
    listen_addr*:    string
    log_level*:      string
    rules*:          seq[ThresholdRule]
    plugin_dirs*:    seq[string]
    history_hours*:  int

  Alert* = object
    id*:        string
    rule_name*: string
    severity*:  string
    message*:   string
    fired_at*:  int64
    value*:     float

# ─── Defaults ─────────────────────────────────────────────────────────────────

proc defaultConfig*(): Config =
  Config(
    interval_ms:   1_000,
    nats_url:      "nats://127.0.0.1:4222",
    listen_addr:   ":7777",
    log_level:     "info",
    history_hours: 24,
    rules: @[
      ThresholdRule(metric: "cpu_pct",      warn: 70.0, crit: 90.0, duration: 10),
      ThresholdRule(metric: "mem_used_pct", warn: 80.0, crit: 95.0, duration: 5),
      ThresholdRule(metric: "swap_pct",     warn: 50.0, crit: 80.0, duration: 10),
    ],
  )

# ─── TOML-like parser (hand-rolled, no dep) ───────────────────────────────────

proc parseLine(cfg: var Config, line: string) =
  let s = line.strip()
  if s.len == 0 or s.startsWith('#'): return
  let eq = s.find('=')
  if eq < 0: return
  let key = s[0..<eq].strip()
  let val = s[eq+1..^1].strip().strip(chars = {'"', '\''})
  case key
  of "interval_ms":   cfg.interval_ms   = val.parseInt()
  of "nats_url":      cfg.nats_url      = val
  of "listen_addr":   cfg.listen_addr   = val
  of "log_level":     cfg.log_level     = val
  of "history_hours": cfg.history_hours = val.parseInt()
  else: discard

proc loadConfig*(path: string): Config =
  result = defaultConfig()
  if not fileExists(path): return
  for line in lines(path):
    parseLine(result, line)

# ─── Alert engine ─────────────────────────────────────────────────────────────

type AlertEngine* = object
  states*: Table[string, AlertState]

proc newAlertEngine*(cfg: Config): AlertEngine =
  for r in cfg.rules:
    result.states[r.metric] = AlertState(rule: r, since: 0.0, fired: false)

proc evaluate*(engine: var AlertEngine, metric: string, value: float): Option[Alert] =
  if metric notin engine.states: return none(Alert)

  var st    = engine.states[metric]
  let rule  = st.rule
  let now   = epochTime()
  let sev   = if value >= rule.crit: Crit
              elif value >= rule.warn: Warn
              else: Info

  if sev in {Warn, Crit}:
    if st.since == 0.0: st.since = now
    let elapsed = now - st.since
    if elapsed >= float(rule.duration) and not st.fired:
      st.fired = true
      engine.states[metric] = st
      return some Alert(
        id:        &"{metric}_{now.int64}",
        rule_name: metric,
        severity:  $sev,
        message:   &"{metric} = {value:.1f}% (threshold {rule.crit}%)",
        fired_at:  now.int64,
        value:     value,
      )
  else:
    st.since = 0.0
    st.fired = false
    engine.states[metric] = st

  return none(Alert)

proc emitAlert*(a: Alert) =
  echo $(%* a)

# ─── CLI entrypoint ───────────────────────────────────────────────────────────

when isMainModule:
  let cfgPath = if paramCount() > 0: paramStr(1) else: "/etc/muninn/muninn.toml"
  let cfg     = loadConfig(cfgPath)
  var engine  = newAlertEngine(cfg)

  echo $(%* cfg)   # dump resolved config as JSON to stdout

  for line in stdin.lines:
    var snap: JsonNode
    try: snap = parseJson(line)
    except: continue

    let cpuPct = snap{"cpu_pct"}.getFloat(0.0)
    let memPct = block:
      let m = snap{"mem"}
      if m != nil and m{"total_kb"}.getInt(0) > 0:
        float(m{"total_kb"}.getInt - m{"available_kb"}.getInt) /
        float(m{"total_kb"}.getInt) * 100.0
      else: 0.0

    for (metric, value) in [("cpu_pct", cpuPct), ("mem_used_pct", memPct)]:
      let alert = engine.evaluate(metric, value)
      if alert.isSome: emitAlert(alert.get)
