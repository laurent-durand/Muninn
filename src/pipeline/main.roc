## src/pipeline/main.roc
## Muninn data pipeline — Roc.
## Transforms raw metric snapshots through a type-safe functional pipeline:
## decode → validate → normalise → enrich → encode.
## No runtime exceptions; all errors handled via Result and Task.

app "muninn-pipeline"
    packages { pf: "https://github.com/roc-lang/basic-cli/releases/latest/download/basic-cli.tar.br" }
    imports  [pf.Stdin, pf.Stdout, pf.Stderr, pf.Task.{ Task, await }, pf.Arg]
    provides [main] to pf

# ─── Types ─────────────────────────────────────────────────────────────────────

Snapshot : {
    timestampMs : I64,
    cpuPct      : F64,
    memTotalKb  : U64,
    memAvailKb  : U64,
    swapTotalKb : U64,
    swapFreeKb  : U64,
    loadOne     : F64,
    loadFive    : F64,
}

Enriched : {
    snap        : Snapshot,
    memUsedPct  : F64,
    swapUsedPct : F64,
    pressure    : F64,    # composite: 0.6*cpu + 0.4*mem
    severity    : [Ok, Warn, Crit],
}

# ─── Validation ────────────────────────────────────────────────────────────────

validate : Snapshot -> Result Snapshot Str
validate = \snap ->
    if snap.cpuPct < 0 || snap.cpuPct > 100 then
        Err "cpu_pct out of range: \(Num.toStr snap.cpuPct)"
    else if snap.timestampMs <= 0 then
        Err "timestamp_ms must be positive"
    else
        Ok snap

# ─── Enrichment ────────────────────────────────────────────────────────────────

enrich : Snapshot -> Enriched
enrich = \snap ->
    memUsedPct =
        if snap.memTotalKb > 0 then
            Num.toF64 (snap.memTotalKb - snap.memAvailKb) / Num.toF64 snap.memTotalKb * 100
        else
            0

    swapUsedPct =
        if snap.swapTotalKb > 0 then
            Num.toF64 (snap.swapTotalKb - snap.swapFreeKb) / Num.toF64 snap.swapTotalKb * 100
        else
            0

    pressure = 0.6 * snap.cpuPct + 0.4 * memUsedPct

    severity =
        if pressure >= 90 then Crit
        else if pressure >= 70 then Warn
        else Ok

    { snap, memUsedPct, swapUsedPct, pressure, severity }

# ─── Serialisation ─────────────────────────────────────────────────────────────

severityStr : [Ok, Warn, Crit] -> Str
severityStr = \s ->
    when s is
        Ok   -> "ok"
        Warn -> "warn"
        Crit -> "crit"

encodeEnriched : Enriched -> Str
encodeEnriched = \e ->
    Str.concat
        "{\"ts\":"
        (Num.toStr e.snap.timestampMs)
    |> Str.concat ",\"cpu\":"
    |> Str.concat (Num.toStr e.snap.cpuPct)
    |> Str.concat ",\"mem_pct\":"
    |> Str.concat (Num.toStr e.memUsedPct)
    |> Str.concat ",\"swap_pct\":"
    |> Str.concat (Num.toStr e.swapUsedPct)
    |> Str.concat ",\"pressure\":"
    |> Str.concat (Num.toStr e.pressure)
    |> Str.concat ",\"load1\":"
    |> Str.concat (Num.toStr e.snap.loadOne)
    |> Str.concat ",\"severity\":\""
    |> Str.concat (severityStr e.severity)
    |> Str.concat "\"}"

# ─── Pipeline composition ──────────────────────────────────────────────────────

processLine : Str -> Result Str Str
processLine = \line ->
    line
    |> decodeSnapshot
    |> Result.try validate
    |> Result.map enrich
    |> Result.map encodeEnriched

# Decode from minimal JSON — in real Roc we'd use a JSON package
decodeSnapshot : Str -> Result Snapshot Str
decodeSnapshot = \_ ->
    # Placeholder — real implementation uses roc-lang/json
    Ok {
        timestampMs = 0,
        cpuPct      = 0,
        memTotalKb  = 0,
        memAvailKb  = 0,
        swapTotalKb = 0,
        swapFreeKb  = 0,
        loadOne     = 0,
        loadFive    = 0,
    }

# ─── Main ──────────────────────────────────────────────────────────────────────

main : Task {} []
main =
    Stdin.lines
    |> Task.forEach \line ->
        when processLine line is
            Ok output ->
                Stdout.line output
            Err msg ->
                Stderr.line "pipeline error: \(msg)"
