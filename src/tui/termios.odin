// src/tui/termios.odin
// Raw terminal mode implementation for Muninn TUI.
// Uses Linux termios syscall directly — no libc dependency.
package muninn_tui

import "core:sys/linux"
import "core:fmt"

// termios structure (Linux x86-64)
Termios :: struct {
    c_iflag  : u32,
    c_oflag  : u32,
    c_cflag  : u32,
    c_lflag  : u32,
    c_line   : u8,
    c_cc     : [32]u8,
    c_ispeed : u32,
    c_ospeed : u32,
}

TCGETS  :: 0x5401
TCSETS  :: 0x5402

ICANON  :: 0x0002   // canonical mode
ECHO    :: 0x0008   // echo input
ISIG    :: 0x0001   // signals
IXON    :: 0x0400   // XON/XOFF

VMIN  :: 6
VTIME :: 5

@(private)
original_termios : Termios

// Enable raw mode: no echo, no canonical, no signals, non-blocking reads
enable_raw_mode :: proc() -> bool {
    orig : Termios
    if linux.syscall(linux.SYS_ioctl, uintptr(linux.STDIN_FILENO), uintptr(TCGETS), uintptr(&orig)) != 0 {
        fmt.eprintln("termios: TCGETS failed")
        return false
    }
    original_termios = orig

    raw         := orig
    raw.c_iflag &~= IXON
    raw.c_lflag &~= (ICANON | ECHO | ISIG)
    raw.c_cc[VMIN]  = 0   // return immediately
    raw.c_cc[VTIME] = 1   // 100ms timeout

    if linux.syscall(linux.SYS_ioctl, uintptr(linux.STDIN_FILENO), uintptr(TCSETS), uintptr(&raw)) != 0 {
        fmt.eprintln("termios: TCSETS failed")
        return false
    }
    return true
}

// Restore original terminal state
disable_raw_mode :: proc() {
    linux.syscall(linux.SYS_ioctl, uintptr(linux.STDIN_FILENO), uintptr(TCSETS), uintptr(&original_termios))
}

// Query terminal dimensions via TIOCGWINSZ
Winsize :: struct {
    ws_row    : u16,
    ws_col    : u16,
    ws_xpixel : u16,
    ws_ypixel : u16,
}
TIOCGWINSZ :: 0x5413

get_term_size :: proc() -> (cols, rows: int) {
    ws : Winsize
    ret := linux.syscall(linux.SYS_ioctl, uintptr(linux.STDOUT_FILENO), uintptr(TIOCGWINSZ), uintptr(&ws))
    if ret != 0 || ws.ws_col == 0 { return 220, 50 }
    return int(ws.ws_col), int(ws.ws_row)
}
