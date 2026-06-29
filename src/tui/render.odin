// src/tui/render.odin
// Widget rendering layer for Muninn TUI.
// All output goes through a double buffer to eliminate flicker.
package muninn_tui

import "core:fmt"
import "core:strings"
import "core:sys/linux"
import "core:math"

// ─── ANSI helpers ────────────────────────────────────────────────────────────

ESC     :: "\x1b["
RESET   :: "\x1b[0m"
BOLD    :: "\x1b[1m"
DIM     :: "\x1b[2m"

fg :: proc(r, g, b: u8) -> string {
    return fmt.tprintf("\x1b[38;2;%d;%d;%dm", r, g, b)
}
bg :: proc(r, g, b: u8) -> string {
    return fmt.tprintf("\x1b[48;2;%d;%d;%dm", r, g, b)
}

// Muninn colour palette
C_RAVEN  :: fg(140, 100, 200)  // purple
C_WARN   :: fg(255, 200,  50)  // amber
C_CRIT   :: fg(255,  70,  70)  // red
C_OK     :: fg( 80, 200, 120)  // green
C_DIM    :: fg(120, 120, 140)  // muted
C_BORDER :: fg( 70,  70,  90)  // border grey

move :: proc(row, col: int) -> string { return fmt.tprintf("\x1b[%d;%dH", row, col) }
clear_screen :: proc() { fmt.print("\x1b[2J\x1b[H") }
hide_cursor  :: proc() { fmt.print("\x1b[?25l") }
show_cursor  :: proc() { fmt.print("\x1b[?25h") }

// ─── Layout constants ────────────────────────────────────────────────────────

HEADER_ROWS :: 3
CPU_ROWS    :: 8
MEM_ROWS    :: 6
NET_ROWS    :: 6

// ─── Render ──────────────────────────────────────────────────────────────────

render :: proc(s: ^State) {
    b: strings.Builder
    strings.builder_init(&b)
    defer strings.builder_destroy(&b)

    draw_header(&b, s)
    draw_cpu_panel(&b, s)
    draw_mem_panel(&b, s)
    draw_net_panel(&b, s)
    draw_sparkline(&b, s)
    draw_footer(&b, s)

    // single write to avoid partial frames
    fmt.print(strings.to_string(b))
}

draw_header :: proc(b: ^strings.Builder, s: ^State) {
    strings.write_string(b, move(1, 1))
    strings.write_string(b, C_RAVEN)
    strings.write_string(b, BOLD)
    strings.write_string(b, " ◈ MUNINN ")
    strings.write_string(b, RESET)
    strings.write_string(b, C_DIM)
    strings.write_string(b, fmt.tprintf(" — %d×%d", s.width, s.height))
    strings.write_string(b, RESET)
}

draw_cpu_panel :: proc(b: ^strings.Builder, s: ^State) {
    row := HEADER_ROWS + 1
    strings.write_string(b, move(row, 1))
    bar := gauge_bar(s.snap.cpu_pct, 40)
    col := severity_color(s.snap.cpu_pct, 70, 90)
    strings.write_string(b, fmt.tprintf("%sCPU  %s[%s]%s %.1f%%%s",
        BOLD, col, bar, RESET, s.snap.cpu_pct, RESET))

    strings.write_string(b, move(row+1, 1))
    strings.write_string(b, fmt.tprintf("%s  load  %.2f  %.2f  %.2f%s",
        C_DIM, s.snap.load.one, s.snap.load.five, s.snap.load.fifteen, RESET))
}

draw_mem_panel :: proc(b: ^strings.Builder, s: ^State) {
    row := HEADER_ROWS + CPU_ROWS
    m   := s.snap.mem
    pct: f64
    if m.total_kb > 0 {
        pct = f64(m.used_kb) / f64(m.total_kb) * 100
    }
    bar := gauge_bar(pct, 40)
    col := severity_color(pct, 80, 95)
    strings.write_string(b, move(row, 1))
    strings.write_string(b, fmt.tprintf("%sMEM  %s[%s]%s %.1f%%  %d/%d MiB%s",
        BOLD, col, bar, RESET,
        pct, m.used_kb/1024, m.total_kb/1024, RESET))

    strings.write_string(b, move(row+1, 1))
    if m.swap_total_kb > 0 {
        swap_pct := f64(m.swap_total_kb - m.swap_free_kb) / f64(m.swap_total_kb) * 100
        strings.write_string(b, fmt.tprintf("%s  swap %.1f%%  cached %d MiB%s",
            C_DIM, swap_pct, m.cached_kb/1024, RESET))
    }
}

draw_net_panel :: proc(b: ^strings.Builder, s: ^State) {
    row := HEADER_ROWS + CPU_ROWS + MEM_ROWS
    strings.write_string(b, move(row, 1))
    strings.write_string(b, BOLD)
    strings.write_string(b, "NET")
    strings.write_string(b, RESET)
    for iface, i in s.snap.net {
        if i > 3 do break
        strings.write_string(b, move(row+1+i, 3))
        strings.write_string(b, fmt.tprintf("%s%-12s%s rx %-12s tx %s",
            C_DIM, iface.iface, RESET,
            human_bytes(iface.rx_bytes),
            human_bytes(iface.tx_bytes)))
    }
}

draw_sparkline :: proc(b: ^strings.Builder, s: ^State) {
    SPARKS :: "▁▂▃▄▅▆▇█"
    row    := HEADER_ROWS + CPU_ROWS + MEM_ROWS + NET_ROWS + 1
    strings.write_string(b, move(row, 1))
    strings.write_string(b, C_DIM)
    strings.write_string(b, "60s  ")
    for i in 0..<60 {
        idx := (s.hist_head + i) % 60
        v   := s.history[idx]
        si  := int(math.floor(v / 100.0 * 7.0))
        if si > 7 do si = 7
        strings.write_rune(b, rune(SPARKS[si*3:si*3+3]))
    }
    strings.write_string(b, RESET)
}

draw_footer :: proc(b: ^strings.Builder, s: ^State) {
    row := s.height
    strings.write_string(b, move(row, 1))
    strings.write_string(b, C_DIM)
    strings.write_string(b, " q quit   ↑↓ scroll   ? help")
    strings.write_string(b, RESET)
}

// ─── Utility ─────────────────────────────────────────────────────────────────

gauge_bar :: proc(pct: f64, width: int) -> string {
    filled := int(pct / 100.0 * f64(width))
    if filled > width do filled = width
    b: strings.Builder
    for _ in 0..<filled { strings.write_string(&b, "█") }
    for _ in filled..<width { strings.write_string(&b, "░") }
    return strings.to_string(b)
}

severity_color :: proc(v, warn, crit: f64) -> string {
    if v >= crit  do return C_CRIT
    if v >= warn  do return C_WARN
    return C_OK
}

human_bytes :: proc(b: u64) -> string {
    switch {
    case b >= 1<<30: return fmt.tprintf("%.1fGiB", f64(b)/f64(1<<30))
    case b >= 1<<20: return fmt.tprintf("%.1fMiB", f64(b)/f64(1<<20))
    case b >= 1<<10: return fmt.tprintf("%.1fKiB", f64(b)/f64(1<<10))
    case:            return fmt.tprintf("%dB", b)
    }
}

term_size :: proc() -> (width, height: int) { return 220, 50 } // fallback; real impl uses ioctl TIOCGWINSZ

term_raw_mode :: proc(enable: bool) {
    // platform-specific termios manipulation would go here
    _ = enable
}
