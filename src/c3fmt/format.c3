// src/c3fmt/format.c3
// Muninn terminal formatting — C3.
// C3 is a C successor with modern ergonomics; used here for the low-level
// string formatting layer shared between the TUI and the alert renderer.
// Compiles to C, then linked into muninn-tui.

module muninn::fmt;

import std::io;
import std::math;
import std::collections::list;

// ─── ANSI colour codes ────────────────────────────────────────────────────────

const String RESET  = "\x1b[0m";
const String BOLD   = "\x1b[1m";
const String DIM    = "\x1b[2m";

fn String fg_rgb(uint r, uint g, uint b) @inline
{
    return string::format("\x1b[38;2;%d;%d;%dm", r, g, b);
}

fn String bg_rgb(uint r, uint g, uint b) @inline
{
    return string::format("\x1b[48;2;%d;%d;%dm", r, g, b);
}

// Palette
const String C_RAVEN   = "\x1b[38;2;140;100;200m";  // purple
const String C_OK      = "\x1b[38;2;80;200;120m";   // green
const String C_WARN    = "\x1b[38;2;255;200;50m";   // amber
const String C_CRIT    = "\x1b[38;2;255;70;70m";    // red
const String C_DIM     = "\x1b[38;2;120;120;140m";  // muted grey
const String C_BORDER  = "\x1b[38;2;70;70;90m";     // border

// ─── Gauge bar ────────────────────────────────────────────────────────────────

fn String gauge_bar(double pct, int width)
{
    int filled = (int)math::round(pct.clamp(0, 100) / 100.0 * width);
    char[] buf = mem::alloc_array(char, (usz)(width + 1));
    defer mem::free(buf);

    // UTF-8 block element "█" = 0xE2 0x96 0x88 (3 bytes)
    // "░" = 0xE2 0x96 0x91
    DString out;
    out.init();
    defer out.free();

    for (int i = 0; i < width; i++) {
        if (i < filled) out.append_chars("█");
        else            out.append_chars("░");
    }
    return out.copy_str();
}

// ─── Severity colour ──────────────────────────────────────────────────────────

fn String severity_color(double v, double warn, double crit) @inline
{
    if (v >= crit)  return C_CRIT;
    if (v >= warn)  return C_WARN;
    return C_OK;
}

// ─── Human-readable byte sizes ────────────────────────────────────────────────

fn String human_bytes(ulong bytes)
{
    if (bytes >= 1uL << 30) return string::format("%.1fGiB", (double)bytes / (1uL << 30));
    if (bytes >= 1uL << 20) return string::format("%.1fMiB", (double)bytes / (1uL << 20));
    if (bytes >= 1uL << 10) return string::format("%.1fKiB", (double)bytes / (1uL << 10));
    return string::format("%luB", bytes);
}

// ─── Cursor positioning ───────────────────────────────────────────────────────

fn String move_to(int row, int col) @inline
{
    return string::format("\x1b[%d;%dH", row, col);
}

fn void clear_screen() @inline
{
    io::print("\x1b[2J\x1b[H");
}

fn void hide_cursor() { io::print("\x1b[?25l"); }
fn void show_cursor() { io::print("\x1b[?25h"); }

// ─── Sparkline ────────────────────────────────────────────────────────────────

const String SPARK_CHARS = "▁▂▃▄▅▆▇█";
const int SPARK_CHAR_BYTES = 3;  // each char is 3 UTF-8 bytes

fn String sparkline(double[] history, int max_width)
{
    DString out;
    out.init();
    defer out.free();

    usz len = history.len.min((usz)max_width);
    for (usz i = 0; i < len; i++) {
        int idx = (int)(history[i].clamp(0, 100) / 100.0 * 7.0);
        idx = idx.clamp(0, 7);
        // Extract UTF-8 bytes for spark char
        int byte_off = idx * SPARK_CHAR_BYTES;
        char[3] sc = {
            SPARK_CHARS[byte_off],
            SPARK_CHARS[byte_off + 1],
            SPARK_CHARS[byte_off + 2]
        };
        out.append_chars((String)sc[:]);
    }
    return out.copy_str();
}

// ─── Header banner ────────────────────────────────────────────────────────────

fn String header_line(int width)
{
    String title = " ◈ MUNINN ";
    int pad      = (width - title.len) / 2;
    DString out;
    out.init();
    defer out.free();
    out.appendf("%s%s%s%s%s", C_BORDER, string::repeat("─", (usz)pad),
                C_RAVEN, BOLD, title);
    out.appendf("%s%s%s\n", RESET, C_BORDER,
                string::repeat("─", (usz)(width - pad - title.len)));
    out.append(RESET);
    return out.copy_str();
}
