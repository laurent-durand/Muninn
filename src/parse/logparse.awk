#!/usr/bin/awk -f
# src/parse/logparse.awk
# Muninn log parser — AWK (gawk).
# Parses syslog / journald export format and emits JSON lines.
# Fast, zero-dependency log triaging before Crystal aggregator picks it up.
#
# Usage:
#   journalctl -f -o short-iso | awk -f logparse.awk
#   tail -f /var/log/syslog    | awk -f logparse.awk

BEGIN {
    FS = " "

    # Severity keyword map
    split("EMERG ALERT CRIT ERR ERROR WARN WARNING NOTICE INFO DEBUG", sev_words)
    for (i in sev_words) sev_map[sev_words[i]] = 1

    # Counters
    total   = 0
    errors  = 0
    warns   = 0
    oom     = 0
    io_err  = 0

    # Report interval (lines)
    REPORT_EVERY = 1000
}

# ─── Helpers ──────────────────────────────────────────────────────────────────

function json_escape(s,    r) {
    r = s
    gsub(/\\/, "\\\\", r)
    gsub(/"/, "\\\"", r)
    gsub(/\n/, "\\n", r)
    gsub(/\r/, "\\r", r)
    gsub(/\t/, "\\t", r)
    return r
}

function emit(ts, host, prog, sev, msg) {
    printf "{\"ts\":\"%s\",\"host\":\"%s\",\"prog\":\"%s\",\"sev\":\"%s\",\"msg\":\"%s\"}\n",
        json_escape(ts), json_escape(host), json_escape(prog),
        json_escape(sev), json_escape(msg)
}

function detect_severity(msg,    upper, w, i) {
    upper = toupper(msg)
    for (i in sev_map) {
        if (index(upper, i) > 0) return i
    }
    return "INFO"
}

# ─── Syslog RFC3164 ──────────────────────────────────────────────────────────
# Format: "Jan  5 12:34:56 host prog[pid]: message"

/^[A-Z][a-z]{2}[ ]+[0-9]/ {
    total++
    ts   = $1 " " $2 " " $3
    host = $4
    prog = $5; sub(/\[.*$/, "", prog); sub(/:$/, "", prog)

    # Reconstruct message (everything after "prog[pid]: ")
    msg  = ""
    for (i = 6; i <= NF; i++) msg = msg (i > 6 ? " " : "") $i

    sev = detect_severity(msg)

    if (sev ~ /^(ERR|ERROR|CRIT|ALERT|EMERG)$/) {
        errors++
        emit(ts, host, prog, sev, msg)
    } else if (sev ~ /^(WARN|WARNING)$/) {
        warns++
    }

    if (msg ~ /Out of memory|oom_kill|Killed process/) {
        oom++
        emit(ts, host, prog, "OOM", msg)
    }

    if (msg ~ /I\/O error|Buffer I\/O|EXT[234]-fs error/) {
        io_err++
        emit(ts, host, prog, "DISK", msg)
    }

    if (total % REPORT_EVERY == 0) report()
    next
}

# ─── journalctl short-iso ─────────────────────────────────────────────────────
# Format: "2024-01-05T12:34:56+0000 host prog[pid]: message"

/^[0-9]{4}-[0-9]{2}-[0-9]{2}T/ {
    total++
    ts   = $1
    host = $2
    prog = $3; sub(/\[.*$/, "", prog); sub(/:$/, "", prog)

    msg = ""
    for (i = 4; i <= NF; i++) msg = msg (i > 4 ? " " : "") $i

    sev = detect_severity(msg)

    if (sev ~ /^(ERR|ERROR|CRIT|ALERT|EMERG)$/) {
        errors++
        emit(ts, host, prog, sev, msg)
    }
    if (msg ~ /Out of memory|oom_kill/) { oom++; emit(ts, host, prog, "OOM", msg) }
    if (total % REPORT_EVERY == 0) report()
    next
}

# ─── Summary ──────────────────────────────────────────────────────────────────

function report() {
    printf "{\"type\":\"log_summary\",\"total\":%d,\"errors\":%d,\"warns\":%d,\"oom\":%d,\"io_err\":%d}\n",
        total, errors, warns, oom, io_err
}

END { report() }
