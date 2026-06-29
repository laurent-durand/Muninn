# src/shell/muninn.elv
# Muninn shell integration — Elvish.
# Provides:
#   muninn status          — one-line system status bar
#   muninn tail            — live metric stream in the terminal
#   muninn alert-history   — pretty-print recent alerts
#   muninn ps-top [n]      — top N processes by RSS
# Also installs Elvish completions for the muninn CLI.

use str
use math
use path
use re

# ─── Config ───────────────────────────────────────────────────────────────────

var api-url = (or $E:MUNINN_API_URL "http://127.0.0.1:7777")
var hb-dir  = "/run/muninn"

# ─── Colour helpers ───────────────────────────────────────────────────────────

fn colour {|r g b text|
  print "\e[38;2;"$r";"$g";"$b"m"$text"\e[0m"
}

fn severity-colour {|v warn crit|
  if (> $v $crit) {
    colour 255 70 70
  } elif (> $v $warn) {
    colour 255 200 50
  } else {
    colour 80 200 120
  }
}

fn gauge-bar {|pct width|
  var filled = (math:floor (* (/ $pct 100) $width))
  var bar = ""
  for _ [(range $filled)] { set bar = $bar"█" }
  for _ [(range (- $width $filled))] { set bar = $bar"░" }
  put $bar
}

# ─── API helpers ──────────────────────────────────────────────────────────────

fn api-get {|path|
  curl -sf $api-url$path 2>/dev/null
}

fn snapshot {
  api-get /api/snapshot | from-json
}

fn alert-list {
  api-get /api/alerts | from-json
}

# ─── Commands ─────────────────────────────────────────────────────────────────

fn status {
  var snap = (snapshot)
  var cpu  = $snap[cpu_pct]
  var mem  = (
    var m = $snap[mem]
    if (> $m[total_kb] 0) {
      put (* (/ (- $m[total_kb] $m[available_kb]) $m[total_kb]) 100)
    } else { put 0 }
  )
  var load = $snap[load][one]

  var cpu-bar = (gauge-bar $cpu 20)
  var mem-bar = (gauge-bar $mem 20)

  print " ◈ "
  colour 140 100 200 "MUNINN"
  print "  CPU "
  severity-colour $cpu 70 90 "["$cpu-bar"]"
  printf " %5.1f%%  " $cpu
  print "MEM "
  severity-colour $mem 80 95 "["$mem-bar"]"
  printf " %5.1f%%  " $mem
  printf "LOAD %.2f\n" $load
}

fn tail {
  var ws-url = (str:replace "http" "ws" $api-url)"/ws/metrics"
  echo "Streaming from "$ws-url" (Ctrl-C to stop)"
  websocat -t $ws-url 2>/dev/null | each {|line|
    var snap = ($line | from-json)
    printf "\r"
    status
  }
}

fn alert-history {
  var alerts = (alert-list)
  if (eq $alerts $nil) {
    colour 80 200 120 "✓ No recent alerts\n"
    return
  }
  for a $alerts {
    var col = (if (eq $a[severity] crit) { colour 255 70 70 } else { colour 255 200 50 })
    printf "%s [%s] %s\n" ($a[severity] | colour 255 200 50) $a[fired_at] $a[message]
  }
}

fn ps-top {|&n=10|
  api-get /api/snapshot | from-json | field procs |
    sort-by {|p| - $p[rss_kb]} |
    take $n |
    each {|p|
      printf "%6d  %-20s  %6.1f%%  %6dMiB  %s\n" \
        $p[pid] $p[name] $p[cpu_pct] (/ $p[rss_kb] 1024) $p[state]
    }
}

# ─── Prompt integration ───────────────────────────────────────────────────────

# Add a miniature CPU indicator to the right prompt
fn prompt-widget {
  var snap = (snapshot 2>/dev/null)
  if (eq $snap $nil) { put "" | return }
  var cpu = $snap[cpu_pct]
  severity-colour $cpu 70 90 (printf " ⟨%.0f%%⟩" $cpu)
}

# ─── Completions ──────────────────────────────────────────────────────────────

set edit:completion:arg-completer[muninn] = {|@args|
  var cmds = [status tail alert-history ps-top]
  if (== (count $args) 2) {
    each {|c| put $c} $cmds
  }
}

# ─── Dispatcher ───────────────────────────────────────────────────────────────

fn main {|@args|
  var cmd = (or (and (> (count $args) 0) $args[0]) status)
  var rest = $args[1..]
  if (eq $cmd status)        { status }
  elif (eq $cmd tail)        { tail }
  elif (eq $cmd alerts)      { alert-history }
  elif (eq $cmd ps-top)      { ps-top (and (> (count $rest) 0) &n=$rest[0]) }
  else                       { echo "Unknown command: "$cmd }
}

main $@argv
