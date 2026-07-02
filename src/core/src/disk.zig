/// src/core/src/disk.zig
/// Reads /proc/diskstats — Linux block device I/O counters.
const std = @import("std");

pub const DiskStat = struct {
    name:             []u8,
    reads_completed:  u64,
    writes_completed: u64,
    read_sectors:     u64,
    write_sectors:    u64,
    read_ms:          u64,
    write_ms:         u64,
    io_ms:            u64,

    /// Read throughput in bytes/sec (delta-based, call periodically)
    pub fn readBps(prev: DiskStat, curr: DiskStat, dt: f64) f64 {
        if (dt == 0) return 0;
        const delta = curr.read_sectors -| prev.read_sectors;
        return @as(f64, @floatFromInt(delta)) * 512.0 / dt;
    }

    pub fn writeBps(prev: DiskStat, curr: DiskStat, dt: f64) f64 {
        if (dt == 0) return 0;
        const delta = curr.write_sectors -| prev.write_sectors;
        return @as(f64, @floatFromInt(delta)) * 512.0 / dt;
    }

    /// Average read latency in ms per operation
    pub fn readLatencyMs(prev: DiskStat, curr: DiskStat) f64 {
        const dops = curr.reads_completed -| prev.reads_completed;
        const dms  = curr.read_ms         -| prev.read_ms;
        if (dops == 0) return 0;
        return @as(f64, @floatFromInt(dms)) / @as(f64, @floatFromInt(dops));
    }
};

/// Parse /proc/diskstats into a slice of DiskStat.
/// Caller owns the returned slice and each .name field.
pub fn readDiskStats(allocator: std.mem.Allocator) ![]DiskStat {
    const file = try std.fs.openFileAbsolute("/proc/diskstats", .{});
    defer file.close();

    var buf: [65536]u8 = undefined;
    const n     = try file.readAll(&buf);
    var   lines = std.mem.splitScalar(u8, buf[0..n], '\n');

    var list = std.ArrayList(DiskStat).init(allocator);

    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t");
        if (trimmed.len == 0) continue;

        var it = std.mem.tokenizeScalar(u8, trimmed, ' ');
        _ = it.next(); // major
        _ = it.next(); // minor
        const name_raw = it.next() orelse continue;

        // Skip partitions (e.g. sda1) — keep whole devices (sda, nvme0n1)
        const name_str = name_raw;
        var is_part = false;
        for (name_str) |c| {
            if (c >= '0' and c <= '9') { is_part = true; break; }
        }
        // Allow nvme0n1 but skip nvme0n1p1
        if (is_part and !std.mem.startsWith(u8, name_str, "nvme")) continue;

        const f = struct {
            fn p(tok: ?[]const u8) u64 {
                return std.fmt.parseInt(u64, tok orelse return 0, 10) catch 0;
            }
        };

        try list.append(.{
            .name              = try allocator.dupe(u8, name_str),
            .reads_completed   = f.p(it.next()),
            .read_sectors      = blk: { _ = it.next(); break :blk f.p(it.next()); },
            .read_ms           = f.p(it.next()),
            .writes_completed  = f.p(it.next()),
            .write_sectors     = blk: { _ = it.next(); break :blk f.p(it.next()); },
            .write_ms          = f.p(it.next()),
            .io_ms             = blk: { _ = it.next(); _ = it.next(); break :blk f.p(it.next()); },
        });
    }

    return list.toOwnedSlice();
}
