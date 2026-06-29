// src/tui/main.odin
// Muninn TUI — terminal UI built with Odin.
// Renders CPU, memory, network and process panels using raw ANSI escape codes
// and a minimal widget abstraction in render.odin.
package muninn_tui

import "core:fmt"
import "core:os"
import "core:encoding/json"
import "core:strings"
import "core:time"
import "core:sys/linux"

RAVEN :: `
  ___  ___
 /   \/   \
 \  Muninn /
  \_______/   Memory of Odin
`

// Snapshot mirrors the JSON emitted by muninn-core (Zig).
Snapshot :: struct {
    timestamp_ms : i64,
    cpu_pct      : f64,
    mem          : MemInfo,
    load         : LoadAvg,
    net          : []NetStat,
}

MemInfo :: struct {
    total_kb     : u64,
    used_kb      : u64,  // derived field injected after parse
    available_kb : u64,
    cached_kb    : u64,
    swap_total_kb: u64,
    swap_free_kb : u64,
}

LoadAvg :: struct { one, five, fifteen: f64 }

NetStat :: struct {
    iface      : string,
    rx_bytes   : u64,
    tx_bytes   : u64,
    rx_packets : u64,
    tx_packets : u64,
}

State :: struct {
    snap      : Snapshot,
    prev_snap : Snapshot,
    history   : [60]f64,   // 60-second CPU rolling buffer
    hist_head : int,
    width     : int,
    height    : int,
}

main :: proc() {
    term_raw_mode(true)
    defer term_raw_mode(false)

    hide_cursor()
    defer show_cursor()
    defer clear_screen()

    state: State
    state.width, state.height = term_size()

    stdin := os.stdin

    // Spawn reader goroutine equivalent: we read muninn-core on stdin
    for {
        line, ok := read_line(stdin)
        if !ok do break

        snap, err := parse_snapshot(line)
        if err != nil do continue

        state.prev_snap = state.snap
        state.snap      = snap
        state.history[state.hist_head % 60] = snap.cpu_pct
        state.hist_head += 1

        render(&state)
    }
}

parse_snapshot :: proc(line: string) -> (Snapshot, json.Error) {
    snap: Snapshot
    err := json.unmarshal_string(line, &snap)
    if err == nil {
        snap.mem.used_kb = snap.mem.total_kb - snap.mem.available_kb
    }
    return snap, err
}

read_line :: proc(f: os.Handle) -> (string, bool) {
    buf: [65536]byte
    n, err := os.read(f, buf[:])
    if err != os.ERROR_NONE || n == 0 do return "", false
    s := string(buf[:n])
    // trim trailing newline
    return strings.trim_right(s, "\n\r"), true
}
