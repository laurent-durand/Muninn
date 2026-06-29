/// metrics.zig — Linux /proc and /sys harvesting.
/// Compiled as part of muninn-core (Zig).
const std = @import("std");

// ─── CPU ─────────────────────────────────────────────────────────────────────

pub const CpuTick = struct {
    user: u64, nice: u64, system: u64, idle: u64,
    iowait: u64, irq: u64, softirq: u64, steal: u64,

    pub fn total(self: CpuTick) u64 {
        return self.user + self.nice + self.system + self.idle +
               self.iowait + self.irq + self.softirq + self.steal;
    }
    pub fn busy(self: CpuTick) u64 { return self.total() - self.idle - self.iowait; }
};

pub const CpuSample = struct {
    aggregate: CpuTick,
    per_core:  []CpuTick,
};

pub fn readCpuSample(allocator: std.mem.Allocator) !CpuSample {
    const file = try std.fs.openFileAbsolute("/proc/stat", .{});
    defer file.close();

    var buf: [16384]u8 = undefined;
    const n   = try file.readAll(&buf);
    var lines = std.mem.splitScalar(u8, buf[0..n], '\n');

    var aggregate: CpuTick = undefined;
    var cores = std.ArrayList(CpuTick).init(allocator);

    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, "cpu")) break;
        const tick = parseCpuLine(line) orelse continue;
        if (line[3] == ' ') { aggregate = tick; } else { try cores.append(tick); }
    }

    return .{ .aggregate = aggregate, .per_core = try cores.toOwnedSlice() };
}

pub fn cpuPercent(prev: CpuTick, curr: CpuTick) f64 {
    const dtotal = @as(f64, @floatFromInt(curr.total() -| prev.total()));
    const dbusy  = @as(f64, @floatFromInt(curr.busy()  -| prev.busy()));
    if (dtotal == 0) return 0;
    return (dbusy / dtotal) * 100.0;
}

fn parseCpuLine(line: []const u8) ?CpuTick {
    var it = std.mem.tokenizeScalar(u8, line, ' ');
    _ = it.next(); // "cpu" or "cpuN"
    return .{
        .user    = parseInt(it.next()) orelse return null,
        .nice    = parseInt(it.next()) orelse 0,
        .system  = parseInt(it.next()) orelse 0,
        .idle    = parseInt(it.next()) orelse 0,
        .iowait  = parseInt(it.next()) orelse 0,
        .irq     = parseInt(it.next()) orelse 0,
        .softirq = parseInt(it.next()) orelse 0,
        .steal   = parseInt(it.next()) orelse 0,
    };
}

// ─── Memory ──────────────────────────────────────────────────────────────────

pub const MemInfo = struct {
    total_kb: u64, free_kb: u64, available_kb: u64,
    cached_kb: u64, buffers_kb: u64,
    swap_total_kb: u64, swap_free_kb: u64, slab_kb: u64,

    pub fn usedKb(self: MemInfo) u64 {
        return self.total_kb -| self.available_kb;
    }
    pub fn usedPct(self: MemInfo) f64 {
        if (self.total_kb == 0) return 0;
        return (@as(f64, @floatFromInt(self.usedKb())) /
                @as(f64, @floatFromInt(self.total_kb))) * 100.0;
    }
};

pub fn readMemInfo() !MemInfo {
    const file = try std.fs.openFileAbsolute("/proc/meminfo", .{});
    defer file.close();

    var buf: [4096]u8 = undefined;
    const n    = try file.readAll(&buf);
    var  lines = std.mem.splitScalar(u8, buf[0..n], '\n');

    var m = MemInfo{ .total_kb=0,.free_kb=0,.available_kb=0,.cached_kb=0,
                     .buffers_kb=0,.swap_total_kb=0,.swap_free_kb=0,.slab_kb=0 };
    while (lines.next()) |line| {
        if (matchKb(line, "MemTotal:"))     m.total_kb     = parseKbLine(line);
        if (matchKb(line, "MemFree:"))      m.free_kb      = parseKbLine(line);
        if (matchKb(line, "MemAvailable:")) m.available_kb  = parseKbLine(line);
        if (matchKb(line, "Cached:"))       m.cached_kb    = parseKbLine(line);
        if (matchKb(line, "Buffers:"))      m.buffers_kb   = parseKbLine(line);
        if (matchKb(line, "SwapTotal:"))    m.swap_total_kb = parseKbLine(line);
        if (matchKb(line, "SwapFree:"))     m.swap_free_kb  = parseKbLine(line);
        if (matchKb(line, "Slab:"))         m.slab_kb       = parseKbLine(line);
    }
    return m;
}

// ─── Network ─────────────────────────────────────────────────────────────────

pub const NetStat = struct {
    iface:      []const u8,
    rx_bytes:   u64, tx_bytes:   u64,
    rx_packets: u64, tx_packets: u64,
    rx_errors:  u64, tx_errors:  u64,
    rx_dropped: u64, tx_dropped: u64,
};

pub fn readNetStats(allocator: std.mem.Allocator) ![]NetStat {
    const file = try std.fs.openFileAbsolute("/proc/net/dev", .{});
    defer file.close();

    var buf: [8192]u8 = undefined;
    const n    = try file.readAll(&buf);
    var  lines = std.mem.splitScalar(u8, buf[0..n], '\n');
    _ = lines.next(); // header 1
    _ = lines.next(); // header 2

    var stats = std.ArrayList(NetStat).init(allocator);
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " ");
        if (trimmed.len == 0) continue;
        const colon = std.mem.indexOfScalar(u8, trimmed, ':') orelse continue;
        const name  = std.mem.trim(u8, trimmed[0..colon], " ");
        var   it    = std.mem.tokenizeScalar(u8, trimmed[colon+1..], ' ');
        try stats.append(.{
            .iface      = try allocator.dupe(u8, name),
            .rx_bytes   = parseInt(it.next()) orelse 0,
            .rx_packets = parseInt(it.next()) orelse 0,
            .rx_errors  = parseInt(it.next()) orelse 0,
            .rx_dropped = parseInt(it.next()) orelse 0,
            .tx_bytes   = blk: { _ = it.next(); _ = it.next(); _ = it.next(); _ = it.next(); break :blk parseInt(it.next()) orelse 0; },
            .tx_packets = parseInt(it.next()) orelse 0,
            .tx_errors  = parseInt(it.next()) orelse 0,
            .tx_dropped = parseInt(it.next()) orelse 0,
        });
    }
    return stats.toOwnedSlice();
}

// ─── Load average ────────────────────────────────────────────────────────────

pub const LoadAvg = struct { one: f64, five: f64, fifteen: f64 };

pub fn readLoadAvg() !LoadAvg {
    const file = try std.fs.openFileAbsolute("/proc/loadavg", .{});
    defer file.close();
    var buf: [128]u8 = undefined;
    const n  = try file.readAll(&buf);
    var  it  = std.mem.tokenizeScalar(u8, buf[0..n], ' ');
    return .{
        .one     = parseFloat(it.next()) orelse 0,
        .five    = parseFloat(it.next()) orelse 0,
        .fifteen = parseFloat(it.next()) orelse 0,
    };
}

// ─── Helpers ─────────────────────────────────────────────────────────────────

fn parseInt(s: ?[]const u8) ?u64 {
    return std.fmt.parseInt(u64, s orelse return null, 10) catch null;
}
fn parseFloat(s: ?[]const u8) ?f64 {
    return std.fmt.parseFloat(f64, s orelse return null) catch null;
}
fn matchKb(line: []const u8, key: []const u8) bool {
    return std.mem.startsWith(u8, line, key);
}
fn parseKbLine(line: []const u8) u64 {
    var it = std.mem.tokenizeScalar(u8, line, ' ');
    _ = it.next();
    return parseInt(it.next()) orelse 0;
}
