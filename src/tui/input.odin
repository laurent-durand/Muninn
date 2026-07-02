// src/tui/input.odin
// Keyboard input handling for Muninn TUI.
package muninn_tui

import "core:sys/linux"
import "core:fmt"

Key :: enum {
    None,
    Quit,        // q
    Up,          // ↑ or k
    Down,        // ↓ or j
    Left,        // ← or h
    Right,       // → or l
    Help,        // ?
    Refresh,     // r
    Tab,         // TAB — cycle panels
    Kill,        // K — send SIGKILL to selected process
    PageUp,      // PgUp
    PageDown,    // PgDn
    Escape,      // ESC
}

read_key :: proc() -> Key {
    buf : [8]u8
    n   := linux.syscall(linux.SYS_read, uintptr(linux.STDIN_FILENO), uintptr(&buf[0]), 8)
    if n <= 0 do return .None

    switch {
    case buf[0] == 'q' || buf[0] == 'Q':
        return .Quit
    case buf[0] == 'k':
        return .Up
    case buf[0] == 'j':
        return .Down
    case buf[0] == 'h':
        return .Left
    case buf[0] == 'l':
        return .Right
    case buf[0] == '?':
        return .Help
    case buf[0] == 'r' || buf[0] == 'R':
        return .Refresh
    case buf[0] == 'K':
        return .Kill
    case buf[0] == '\t':
        return .Tab
    case buf[0] == 0x1b && n >= 3 && buf[1] == '[':
        // Escape sequences: arrow keys, PgUp/PgDn
        switch buf[2] {
        case 'A': return .Up
        case 'B': return .Down
        case 'C': return .Right
        case 'D': return .Left
        case '5': return .PageUp
        case '6': return .PageDown
        }
    case buf[0] == 0x1b:
        return .Escape
    }
    return .None
}

// Help overlay text
HELP_TEXT :: `
  ╔══════════════════════════════╗
  ║      MUNINN — keybindings   ║
  ╠══════════════════════════════╣
  ║  q / Q      quit            ║
  ║  ↑ / k      scroll up       ║
  ║  ↓ / j      scroll down     ║
  ║  TAB        cycle panel     ║
  ║  r          force refresh   ║
  ║  K          kill process    ║
  ║  ?          toggle help     ║
  ║  ESC        dismiss         ║
  ╚══════════════════════════════╝
`

draw_help :: proc(b: ^strings.Builder) {
    import "core:strings"
    strings.write_string(b, move(5, 10))
    strings.write_string(b, C_RAVEN)
    strings.write_string(b, HELP_TEXT)
    strings.write_string(b, RESET)
}
