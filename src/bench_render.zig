const std = @import("std");
const nivi = @import("nivi");

const samples = 5;
const KiB = 1024;
const MiB = KiB * KiB;

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(allocator);
    try fillText(allocator, &text, 4 * MiB);

    var unicode: std.ArrayList(u8) = .empty;
    defer unicode.deinit(allocator);
    try fillUnicodeText(allocator, &unicode, 1 * MiB);

    var buffer = try nivi.Buffer.initFromText(allocator, text.items);
    defer buffer.deinit();
    var unicode_buffer = try nivi.Buffer.initFromText(allocator, unicode.items);
    defer unicode_buffer.deinit();

    var huge_line: std.ArrayList(u8) = .empty;
    defer huge_line.deinit(allocator);
    try fillHugeLine(allocator, &huge_line, 4 * MiB);
    var huge_line_buffer = try nivi.Buffer.initFromText(allocator, huge_line.items);
    defer huge_line_buffer.deinit();

    printStat("viewport_render_80x24_ascii", try benchViewport(allocator, buffer, 80, 24, false), 1);
    printStat("viewport_render_240x80_ascii", try benchViewport(allocator, buffer, 240, 80, false), 1);
    printStat("viewport_render_relative_numbers", try benchViewport(allocator, buffer, 120, 40, true), 1);
    printStat("viewport_render_unicode", try benchViewport(allocator, unicode_buffer, 120, 40, true), 1);
    printStat("viewport_render_huge_line", try benchViewport(allocator, huge_line_buffer, 120, 40, true), 1);
    printStat("viewport_render_huge_line_hscroll", try benchViewportHScroll(allocator, huge_line_buffer, 120, 40, 4000), 1);

    printStat("frame_present_full_80x24", try benchFrameFull(allocator, 80, 24), 1);
    printStat("frame_present_diff_one_cell", try benchFrameDiffOneCell(allocator, 80, 24, 50_000), 50_000);
    printStat("frame_present_dirty_one_cell", try benchFrameDirtyOneCell(allocator, 80, 24, 50_000), 50_000);
    printStat("frame_present_diff_one_line", try benchFrameDiffOneLine(allocator, 120, 40, 20_000), 20_000);
    printStat("frame_present_dirty_one_line", try benchFrameDirtyOneLine(allocator, 120, 40, 20_000), 20_000);
    printStat("frame_present_diff_full_screen", try benchFrameDiffFull(allocator, 120, 40, 1000), 1000);

    printStat("input_decode_ascii_1m", benchInputDecode("x", 1_000_000), 1_000_000);
    printStat("input_decode_escape_1m", benchInputDecode("\x1b[A", 1_000_000), 1_000_000);
    printStat("input_decode_utf8_1m", benchInputDecode("🌊", 1_000_000), 1_000_000);

    printStat("save_flatten_1mib", try benchFlattenSave(allocator, text.items[0..MiB]), 1);
    printStat("load_build_1mib", try benchLoadBuild(allocator, text.items[0..MiB]), 1);
}

fn benchFrameDirtyOneCell(allocator: std.mem.Allocator, width: usize, height: usize, iterations: usize) !u64 {
    var frame = try nivi.render.FrameRenderer.init(allocator, width, height);
    defer frame.deinit();
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();

    const start = nowNanos();
    for (0..iterations) |i| {
        out.clearRetainingCapacity();
        frame.current.copyFrom(frame.previous);
        const x = (i % (width - 1)) + 1;
        const y = i % height;
        frame.current.putCell(x, y, .ascii('x', .{}));
        try frame.markDirty(.{ .x = x, .y = y, .width = 1, .height = 1 });
        try frame.present(&out.writer);
        try out.writer.flush();
    }
    std.mem.doNotOptimizeAway(out.written().len);
    return elapsed(start);
}

fn benchFrameDirtyOneLine(allocator: std.mem.Allocator, width: usize, height: usize, iterations: usize) !u64 {
    var frame = try nivi.render.FrameRenderer.init(allocator, width, height);
    defer frame.deinit();
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();

    const start = nowNanos();
    for (0..iterations) |i| {
        out.clearRetainingCapacity();
        frame.current.copyFrom(frame.previous);
        const y = i % height;
        frame.current.writeAscii(0, y, width, "changed line with some text", .{});
        try frame.markDirty(.{ .x = 0, .y = y, .width = width, .height = 1 });
        try frame.present(&out.writer);
        try out.writer.flush();
    }
    std.mem.doNotOptimizeAway(out.written().len);
    return elapsed(start);
}

fn benchViewport(allocator: std.mem.Allocator, buffer: nivi.Buffer, width: usize, height: usize, relative: bool) !u64 {
    var best: u64 = std.math.maxInt(u64);
    for (0..samples) |_| {
        var surface = try nivi.render.Surface.init(allocator, width, height);
        defer surface.deinit();
        var scratch: std.ArrayListUnmanaged(u8) = .empty;
        defer scratch.deinit(allocator);

        const start = nowNanos();
        try nivi.render.renderBufferViewportScratch(allocator, &scratch, &surface, surface.rect(), buffer, .{
            .first_line = if (buffer.lineCount() > 100) 100 else 0,
            .cursor_line = if (buffer.lineCount() > 112) 112 else 0,
            .relative_line_numbers = relative,
        });
        std.mem.doNotOptimizeAway(surface.cells[width + 1]);
        best = @min(best, elapsed(start));
    }
    return best;
}

fn benchViewportHScroll(allocator: std.mem.Allocator, buffer: nivi.Buffer, width: usize, height: usize, first_column: usize) !u64 {
    var best: u64 = std.math.maxInt(u64);
    for (0..samples) |_| {
        var surface = try nivi.render.Surface.init(allocator, width, height);
        defer surface.deinit();
        var scratch: std.ArrayListUnmanaged(u8) = .empty;
        defer scratch.deinit(allocator);

        const start = nowNanos();
        try nivi.render.renderBufferViewportScratch(allocator, &scratch, &surface, surface.rect(), buffer, .{
            .first_column = first_column,
            .relative_line_numbers = true,
        });
        std.mem.doNotOptimizeAway(surface.cells[width + 1]);
        best = @min(best, elapsed(start));
    }
    return best;
}

fn benchFrameFull(allocator: std.mem.Allocator, width: usize, height: usize) !u64 {
    var best: u64 = std.math.maxInt(u64);
    for (0..samples) |_| {
        var frame = try nivi.render.FrameRenderer.init(allocator, width, height);
        defer frame.deinit();
        frame.current.writeAscii(0, 0, width, "hello", .{});
        var out: std.Io.Writer.Allocating = .init(allocator);
        defer out.deinit();

        const start = nowNanos();
        try frame.present(&out.writer);
        try out.writer.flush();
        best = @min(best, elapsed(start));
        std.mem.doNotOptimizeAway(out.written().len);
    }
    return best;
}

fn benchFrameDiffOneCell(allocator: std.mem.Allocator, width: usize, height: usize, iterations: usize) !u64 {
    var frame = try nivi.render.FrameRenderer.init(allocator, width, height);
    defer frame.deinit();
    frame.previous.clear(.{});
    frame.current.clear(.{});
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();

    const start = nowNanos();
    for (0..iterations) |i| {
        out.clearRetainingCapacity();
        frame.current.copyFrom(frame.previous);
        frame.current.putCell((i % (width - 1)) + 1, i % height, .ascii('x', .{}));
        try nivi.render.AnsiRenderer.renderDiff(&out.writer, frame.previous, frame.current);
        try out.writer.flush();
        frame.previous.copyFrom(frame.current);
    }
    std.mem.doNotOptimizeAway(out.written().len);
    return elapsed(start);
}

fn benchFrameDiffOneLine(allocator: std.mem.Allocator, width: usize, height: usize, iterations: usize) !u64 {
    var frame = try nivi.render.FrameRenderer.init(allocator, width, height);
    defer frame.deinit();
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();

    const start = nowNanos();
    for (0..iterations) |i| {
        out.clearRetainingCapacity();
        frame.current.copyFrom(frame.previous);
        frame.current.writeAscii(0, i % height, width, "changed line with some text", .{});
        try nivi.render.AnsiRenderer.renderDiff(&out.writer, frame.previous, frame.current);
        try out.writer.flush();
        frame.previous.copyFrom(frame.current);
    }
    std.mem.doNotOptimizeAway(out.written().len);
    return elapsed(start);
}

fn benchFrameDiffFull(allocator: std.mem.Allocator, width: usize, height: usize, iterations: usize) !u64 {
    var frame = try nivi.render.FrameRenderer.init(allocator, width, height);
    defer frame.deinit();
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();

    const start = nowNanos();
    for (0..iterations) |i| {
        out.clearRetainingCapacity();
        frame.current.clear(if (i % 2 == 0) .{} else .{ .fg = .accent });
        try nivi.render.AnsiRenderer.renderDiff(&out.writer, frame.previous, frame.current);
        try out.writer.flush();
        frame.previous.copyFrom(frame.current);
    }
    std.mem.doNotOptimizeAway(out.written().len);
    return elapsed(start);
}

fn benchInputDecode(bytes: []const u8, iterations: usize) u64 {
    var best: u64 = std.math.maxInt(u64);
    for (0..samples) |_| {
        var checksum: usize = 0;
        const start = nowNanos();
        for (0..iterations) |_| {
            const decoded = nivi.input.decode(bytes).?;
            checksum +%= decoded.used;
        }
        std.mem.doNotOptimizeAway(checksum);
        best = @min(best, elapsed(start));
    }
    return best;
}

fn benchFlattenSave(allocator: std.mem.Allocator, text: []const u8) !u64 {
    var best: u64 = std.math.maxInt(u64);
    for (0..samples) |_| {
        var buffer = try nivi.Buffer.initFromText(allocator, text);
        defer buffer.deinit();
        const start = nowNanos();
        const flattened = try buffer.toOwnedSlice(allocator);
        defer allocator.free(flattened);
        std.mem.doNotOptimizeAway(flattened.ptr);
        best = @min(best, elapsed(start));
    }
    return best;
}

fn benchLoadBuild(allocator: std.mem.Allocator, text: []const u8) !u64 {
    var best: u64 = std.math.maxInt(u64);
    for (0..samples) |_| {
        var buffer = nivi.Buffer.init(allocator) catch unreachable;
        defer buffer.deinit();
        const start = nowNanos();
        try buffer.setText(text);
        best = @min(best, elapsed(start));
    }
    return best;
}

fn fillText(allocator: std.mem.Allocator, out: *std.ArrayList(u8), target_len: usize) !void {
    const line = "0123456789 abcdefghijklmnopqrstuvwxyz ABCDEFGHIJKLMNOPQRSTUVWXYZ\n";
    while (out.items.len < target_len) try out.appendSlice(allocator, line[0..@min(target_len - out.items.len, line.len)]);
}

fn fillUnicodeText(allocator: std.mem.Allocator, out: *std.ArrayList(u8), target_len: usize) !void {
    const line = "ascii café 世界 🌊 editor 🚀\n";
    while (out.items.len < target_len) try out.appendSlice(allocator, line[0..@min(target_len - out.items.len, line.len)]);
}

fn fillHugeLine(allocator: std.mem.Allocator, out: *std.ArrayList(u8), target_len: usize) !void {
    const chunk = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789";
    while (out.items.len < target_len) try out.appendSlice(allocator, chunk[0..@min(target_len - out.items.len, chunk.len)]);
}

fn elapsed(start: u64) u64 {
    return nowNanos() - start;
}

fn nowNanos() u64 {
    var ts: std.os.linux.timespec = undefined;
    const rc = std.os.linux.clock_gettime(.MONOTONIC, &ts);
    std.debug.assert(rc == 0);
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

fn printStat(name: []const u8, ns: u64, ops: usize) void {
    std.debug.print("{s}: total_ns={d} ops={d} ns_per_op={d}\n", .{ name, ns, ops, if (ops == 0) 0 else ns / ops });
}
