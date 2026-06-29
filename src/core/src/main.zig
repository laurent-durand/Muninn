/// main.zig — muninn-core entry point.
/// Polls the kernel every INTERVAL_MS, serialises a JSON snapshot to stdout.
/// The Go broker (src/api) reads this pipe and fans out to subscribers.
const std      = @import("std");
const metrics  = @import("metrics.zig");
const builtin  = @import("builtin");

const INTERVAL_MS: u64 = 1_000;

const Snapshot = struct {
    timestamp_ms: i64,
    cpu_pct:      f64,
    mem:          metrics.MemInfo,
    load:         metrics.LoadAvg,
    net:          []metrics.NetStat,
};

pub fn main() !void {
    if (builtin.os.tag != .linux) @compileError("muninn-core requires Linux");

    var gpa       = std.heap.GeneralPurposeAllocator(.{}){};
    defer _       = gpa.deinit();
    const alloc   = gpa.allocator();
    const stdout  = std.io.getStdOut().writer();

    std.log.info("muninn-core v0.1.0 — sampling every {}ms", .{INTERVAL_MS});

    var prev_sample = try metrics.readCpuSample(alloc);
    defer alloc.free(prev_sample.per_core);

    while (true) {
        std.time.sleep(INTERVAL_MS * std.time.ns_per_ms);

        const curr_sample = try metrics.readCpuSample(alloc);
        const cpu_pct     = metrics.cpuPercent(prev_sample.aggregate, curr_sample.aggregate);
        alloc.free(prev_sample.per_core);
        prev_sample = curr_sample;

        const mem  = try metrics.readMemInfo();
        const load = try metrics.readLoadAvg();
        const net  = try metrics.readNetStats(alloc);
        defer {
            for (net) |s| alloc.free(s.iface);
            alloc.free(net);
        }

        const snap = Snapshot{
            .timestamp_ms = std.time.milliTimestamp(),
            .cpu_pct      = cpu_pct,
            .mem          = mem,
            .load         = load,
            .net          = net,
        };

        try std.json.stringify(snap, .{}, stdout);
        try stdout.writeByte('\n');
    }
}
