const std = @import("std");
const nivi = @import("nivi");

const iterations = 200;
const budget_ns: u64 = 2 * std.time.ns_per_ms;

pub fn main(init: std.process.Init) !void {
    const allocator = std.heap.page_allocator;
    var source: std.ArrayList(u8) = .empty;
    defer source.deinit(allocator);
    try source.appendSlice(allocator, "const marker = 0;\n");
    for (0..20_000) |index| {
        var buf: [96]u8 = undefined;
        const line = try std.fmt.bufPrint(&buf, "const value_{d} = @as(u64, {d});\n", .{ index, index });
        try source.appendSlice(allocator, line);
    }

    var buffer = try nivi.Buffer.initFromText(allocator, source.items);
    defer buffer.deinit();
    var highlighter = try nivi.syntax.Highlighter.init(init.io, allocator, "bench.zig");
    defer highlighter.deinit();
    if (!highlighter.enabled()) {
        std.debug.print("syntax benchmark unavailable: Zig parser/query not loaded\n", .{});
        return;
    }

    const visible: nivi.syntax.ByteRange = .{ .start = 0, .end = @min(buffer.byteLen(), 4096) };
    var spans: std.ArrayListUnmanaged(nivi.syntax.HighlightSpan) = .empty;
    defer spans.deinit(allocator);
    try highlighter.collectFull(&spans, &buffer, visible);

    var samples: [iterations]u64 = undefined;
    var total: u128 = 0;
    var max_ns: u64 = 0;
    for (0..iterations) |index| {
        try buffer.replace(6, 1, if (index % 2 == 0) "n" else "m");
        const edit = buffer.last_edit.?;
        const started = monotonicNowNs();
        try highlighter.collectEdit(&spans, &buffer, .{
            .offset = edit.offset,
            .old_end = edit.old_end,
            .new_end = edit.new_end,
            .start_point = .{ .row = edit.start_point.row, .column = edit.start_point.column },
            .old_end_point = .{ .row = edit.old_end_point.row, .column = edit.old_end_point.column },
            .new_end_point = .{ .row = edit.new_end_point.row, .column = edit.new_end_point.column },
        }, visible);
        const elapsed: u64 = @intCast(@max(monotonicNowNs() - started, 0));
        samples[index] = elapsed;
        total += elapsed;
        max_ns = @max(max_ns, elapsed);
    }

    std.mem.sort(u64, &samples, {}, std.sort.asc(u64));
    std.debug.print(
        "syntax_incremental_20k_lines avg={d}us p50={d}us p99={d}us max={d}us ({d} edits)\n",
        .{
            @as(u64, @intCast(total / iterations)) / std.time.ns_per_us,
            samples[iterations / 2] / std.time.ns_per_us,
            samples[(iterations * 99) / 100] / std.time.ns_per_us,
            max_ns / std.time.ns_per_us,
            iterations,
        },
    );

    try buffer.replace(6, 1, "n");
    const edit = buffer.last_edit.?;
    const started = monotonicNowNs();
    const cancelled = cancelled: {
        highlighter.collectEditBudgeted(&spans, &buffer, .{
            .offset = edit.offset,
            .old_end = edit.old_end,
            .new_end = edit.new_end,
            .start_point = .{ .row = edit.start_point.row, .column = edit.start_point.column },
            .old_end_point = .{ .row = edit.old_end_point.row, .column = edit.old_end_point.column },
            .new_end_point = .{ .row = edit.new_end_point.row, .column = edit.new_end_point.column },
        }, visible, budget_ns) catch |err| switch (err) {
            error.ParseCancelled => break :cancelled true,
            else => return err,
        };
        break :cancelled false;
    };
    const budget_elapsed: u64 = @intCast(@max(monotonicNowNs() - started, 0));
    std.debug.print("syntax_budget_2ms elapsed={d}us cancelled={}\n", .{ budget_elapsed / std.time.ns_per_us, cancelled });
}

fn monotonicNowNs() i128 {
    var ts: std.c.timespec = undefined;
    if (std.c.clock_gettime(.MONOTONIC, &ts) != 0) return 0;
    return @as(i128, ts.sec) * std.time.ns_per_s + ts.nsec;
}
