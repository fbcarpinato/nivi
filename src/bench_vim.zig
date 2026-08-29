const std = @import("std");
const nivi = @import("nivi");

const samples = 5;

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    printStat("vim_dispatch_h_1m", try benchDispatch(allocator, 1_000_000), 1_000_000);
    printStat("vim_motion_w_100k", try benchWordMotion(allocator, 100_000), 100_000);
    printStat("vim_motion_b_100k", try benchBackwardWordMotion(allocator, 100_000), 100_000);
    printStat("vim_motion_e_100k", try benchEndWordMotion(allocator, 100_000), 100_000);
    printStat("vim_motion_G_100k", try benchLineJump(allocator, 100_000), 100_000);
    printStat("vim_motion_paragraph_100k", try benchParagraphMotion(allocator, 100_000), 100_000);
    printStat("vim_motion_half_page_100k", try benchHalfPageMotion(allocator, 100_000), 100_000);
    printStat("vim_delete_w_10k", try benchDeleteWord(allocator, 10_000), 10_000);
    printStat("vim_delete_line_10k", try benchDeleteLine(allocator, 10_000), 10_000);
    printStat("vim_delete_suffix_10k", try benchDeleteSuffix(allocator, 10_000), 10_000);
    printStat("vim_visual_delete_10k", try benchVisualDelete(allocator, 10_000), 10_000);
    printStat("vim_paste_10k", try benchPaste(allocator, 10_000), 10_000);
    printStat("vim_open_line_10k", try benchOpenLine(allocator, 10_000), 10_000);
    printStat("vim_replace_10k", try benchReplace(allocator, 10_000), 10_000);
    printStat("vim_toggle_10k", try benchToggle(allocator, 10_000), 10_000);
    printStat("vim_join_10k", try benchJoin(allocator, 10_000), 10_000);
}

fn benchDispatch(allocator: std.mem.Allocator, iterations: usize) !u64 {
    var best: u64 = std.math.maxInt(u64);
    for (0..samples) |_| {
        var buffer = try nivi.Buffer.initFromText(allocator, "abcdefghijklmnopqrstuvwxyz");
        defer buffer.deinit();
        var cursor = nivi.Cursor.init(buffer);
        var vim = nivi.vim.State.init(allocator);
        defer vim.deinit();

        const start = nowNanos();
        for (0..iterations) |i| {
            _ = try vim.handleNormal(&buffer, &cursor, .{ .char = if (i % 2 == 0) 'l' else 'h' });
        }
        std.mem.doNotOptimizeAway(cursor.offset);
        best = @min(best, elapsed(start));
    }
    return best;
}

fn benchWordMotion(allocator: std.mem.Allocator, iterations: usize) !u64 {
    var best: u64 = std.math.maxInt(u64);
    for (0..samples) |_| {
        var text: std.ArrayList(u8) = .empty;
        defer text.deinit(allocator);
        try fillWords(allocator, &text, iterations + 4);

        var buffer = try nivi.Buffer.initFromText(allocator, text.items);
        defer buffer.deinit();
        var cursor = nivi.Cursor.init(buffer);
        var vim = nivi.vim.State.init(allocator);
        defer vim.deinit();

        const start = nowNanos();
        for (0..iterations) |_| _ = try vim.handleNormal(&buffer, &cursor, .{ .char = 'w' });
        std.mem.doNotOptimizeAway(cursor.offset);
        best = @min(best, elapsed(start));
    }
    return best;
}

fn benchBackwardWordMotion(allocator: std.mem.Allocator, iterations: usize) !u64 {
    var best: u64 = std.math.maxInt(u64);
    for (0..samples) |_| {
        var text: std.ArrayList(u8) = .empty;
        defer text.deinit(allocator);
        try fillWords(allocator, &text, iterations + 4);

        var buffer = try nivi.Buffer.initFromText(allocator, text.items);
        defer buffer.deinit();
        var cursor = nivi.Cursor.at(buffer, buffer.byteLen());
        var vim = nivi.vim.State.init(allocator);
        defer vim.deinit();

        const start = nowNanos();
        for (0..iterations) |_| _ = try vim.handleNormal(&buffer, &cursor, .{ .char = 'b' });
        std.mem.doNotOptimizeAway(cursor.offset);
        best = @min(best, elapsed(start));
    }
    return best;
}

fn benchEndWordMotion(allocator: std.mem.Allocator, iterations: usize) !u64 {
    var best: u64 = std.math.maxInt(u64);
    for (0..samples) |_| {
        var text: std.ArrayList(u8) = .empty;
        defer text.deinit(allocator);
        try fillWords(allocator, &text, iterations + 4);

        var buffer = try nivi.Buffer.initFromText(allocator, text.items);
        defer buffer.deinit();
        var cursor = nivi.Cursor.init(buffer);
        var vim = nivi.vim.State.init(allocator);
        defer vim.deinit();

        const start = nowNanos();
        for (0..iterations) |_| _ = try vim.handleNormal(&buffer, &cursor, .{ .char = 'e' });
        std.mem.doNotOptimizeAway(cursor.offset);
        best = @min(best, elapsed(start));
    }
    return best;
}

fn benchLineJump(allocator: std.mem.Allocator, iterations: usize) !u64 {
    var best: u64 = std.math.maxInt(u64);
    for (0..samples) |_| {
        var text: std.ArrayList(u8) = .empty;
        defer text.deinit(allocator);
        try fillLines(allocator, &text, 4096);

        var buffer = try nivi.Buffer.initFromText(allocator, text.items);
        defer buffer.deinit();
        var cursor = nivi.Cursor.init(buffer);
        var vim = nivi.vim.State.init(allocator);
        defer vim.deinit();

        const start = nowNanos();
        for (0..iterations) |i| {
            _ = try vim.handleNormal(&buffer, &cursor, .{ .char = if (i % 2 == 0) 'G' else 'g' });
            if (i % 2 != 0) _ = try vim.handleNormal(&buffer, &cursor, .{ .char = 'g' });
        }
        std.mem.doNotOptimizeAway(cursor.offset);
        best = @min(best, elapsed(start));
    }
    return best;
}

fn benchParagraphMotion(allocator: std.mem.Allocator, iterations: usize) !u64 {
    var best: u64 = std.math.maxInt(u64);
    for (0..samples) |_| {
        var text: std.ArrayList(u8) = .empty;
        defer text.deinit(allocator);
        try fillParagraphs(allocator, &text, iterations + 4);

        var buffer = try nivi.Buffer.initFromText(allocator, text.items);
        defer buffer.deinit();
        var cursor = nivi.Cursor.init(buffer);
        var vim = nivi.vim.State.init(allocator);
        defer vim.deinit();

        const start = nowNanos();
        for (0..iterations) |_| _ = try vim.handleNormal(&buffer, &cursor, .{ .char = '}' });
        std.mem.doNotOptimizeAway(cursor.offset);
        best = @min(best, elapsed(start));
    }
    return best;
}

fn benchHalfPageMotion(allocator: std.mem.Allocator, iterations: usize) !u64 {
    var best: u64 = std.math.maxInt(u64);
    for (0..samples) |_| {
        var text: std.ArrayList(u8) = .empty;
        defer text.deinit(allocator);
        try fillLines(allocator, &text, 4096);

        var buffer = try nivi.Buffer.initFromText(allocator, text.items);
        defer buffer.deinit();
        var cursor = nivi.Cursor.init(buffer);
        var vim = nivi.vim.State.init(allocator);
        defer vim.deinit();

        const start = nowNanos();
        for (0..iterations) |i| _ = try vim.handleNormal(&buffer, &cursor, .{ .ctrl = if (i % 2 == 0) 'd' else 'u' });
        std.mem.doNotOptimizeAway(cursor.offset);
        best = @min(best, elapsed(start));
    }
    return best;
}

fn benchDeleteWord(allocator: std.mem.Allocator, iterations: usize) !u64 {
    var best: u64 = std.math.maxInt(u64);
    for (0..samples) |_| {
        var text: std.ArrayList(u8) = .empty;
        defer text.deinit(allocator);
        try fillWords(allocator, &text, iterations + 4);

        var buffer = try nivi.Buffer.initFromText(allocator, text.items);
        defer buffer.deinit();
        var cursor = nivi.Cursor.init(buffer);
        var vim = nivi.vim.State.init(allocator);
        defer vim.deinit();

        const start = nowNanos();
        for (0..iterations) |_| {
            _ = try vim.handleNormal(&buffer, &cursor, .{ .char = 'd' });
            _ = try vim.handleNormal(&buffer, &cursor, .{ .char = 'w' });
        }
        std.mem.doNotOptimizeAway(buffer.byteLen());
        best = @min(best, elapsed(start));
    }
    return best;
}

fn benchDeleteLine(allocator: std.mem.Allocator, iterations: usize) !u64 {
    var best: u64 = std.math.maxInt(u64);
    for (0..samples) |_| {
        var text: std.ArrayList(u8) = .empty;
        defer text.deinit(allocator);
        try fillLines(allocator, &text, iterations + 4);

        var buffer = try nivi.Buffer.initFromText(allocator, text.items);
        defer buffer.deinit();
        var cursor = nivi.Cursor.init(buffer);
        var vim = nivi.vim.State.init(allocator);
        defer vim.deinit();

        const start = nowNanos();
        for (0..iterations) |_| {
            _ = try vim.handleNormal(&buffer, &cursor, .{ .char = 'd' });
            _ = try vim.handleNormal(&buffer, &cursor, .{ .char = 'd' });
        }
        std.mem.doNotOptimizeAway(buffer.byteLen());
        best = @min(best, elapsed(start));
    }
    return best;
}

fn benchDeleteSuffix(allocator: std.mem.Allocator, iterations: usize) !u64 {
    var best: u64 = std.math.maxInt(u64);
    for (0..samples) |_| {
        var text: std.ArrayList(u8) = .empty;
        defer text.deinit(allocator);
        try fillLines(allocator, &text, iterations + 4);

        var buffer = try nivi.Buffer.initFromText(allocator, text.items);
        defer buffer.deinit();
        var cursor = nivi.Cursor.init(buffer);
        var vim = nivi.vim.State.init(allocator);
        defer vim.deinit();

        const start = nowNanos();
        for (0..iterations) |_| {
            _ = try vim.handleNormal(&buffer, &cursor, .{ .char = 'D' });
            _ = try vim.handleNormal(&buffer, &cursor, .{ .char = 'j' });
        }
        std.mem.doNotOptimizeAway(buffer.byteLen());
        best = @min(best, elapsed(start));
    }
    return best;
}

fn benchVisualDelete(allocator: std.mem.Allocator, iterations: usize) !u64 {
    var best: u64 = std.math.maxInt(u64);
    for (0..samples) |_| {
        var text: std.ArrayList(u8) = .empty;
        defer text.deinit(allocator);
        try fillWords(allocator, &text, iterations + 4);

        var buffer = try nivi.Buffer.initFromText(allocator, text.items);
        defer buffer.deinit();
        var cursor = nivi.Cursor.init(buffer);
        var selection = nivi.Selection.fromCursor(cursor);
        var vim = nivi.vim.State.init(allocator);
        defer vim.deinit();

        const start = nowNanos();
        for (0..iterations) |_| {
            selection = nivi.Selection.fromCursor(cursor);
            _ = try vim.handleVisual(&buffer, &cursor, &selection, false, .{ .char = 'w' });
            _ = try vim.handleVisual(&buffer, &cursor, &selection, false, .{ .char = 'd' });
        }
        std.mem.doNotOptimizeAway(buffer.byteLen());
        best = @min(best, elapsed(start));
    }
    return best;
}

fn benchPaste(allocator: std.mem.Allocator, iterations: usize) !u64 {
    var best: u64 = std.math.maxInt(u64);
    for (0..samples) |_| {
        var buffer = try nivi.Buffer.initFromText(allocator, "word ");
        defer buffer.deinit();
        var cursor = nivi.Cursor.init(buffer);
        var vim = nivi.vim.State.init(allocator);
        defer vim.deinit();

        _ = try vim.handleNormal(&buffer, &cursor, .{ .char = 'y' });
        _ = try vim.handleNormal(&buffer, &cursor, .{ .char = 'w' });

        const start = nowNanos();
        for (0..iterations) |_| _ = try vim.handleNormal(&buffer, &cursor, .{ .char = 'p' });
        std.mem.doNotOptimizeAway(buffer.byteLen());
        best = @min(best, elapsed(start));
    }
    return best;
}

fn benchOpenLine(allocator: std.mem.Allocator, iterations: usize) !u64 {
    var best: u64 = std.math.maxInt(u64);
    for (0..samples) |_| {
        var buffer = try nivi.Buffer.initFromText(allocator, "line");
        defer buffer.deinit();
        var cursor = nivi.Cursor.init(buffer);
        var vim = nivi.vim.State.init(allocator);
        defer vim.deinit();

        const start = nowNanos();
        for (0..iterations) |_| _ = try vim.handleNormal(&buffer, &cursor, .{ .char = 'o' });
        std.mem.doNotOptimizeAway(buffer.byteLen());
        best = @min(best, elapsed(start));
    }
    return best;
}

fn benchReplace(allocator: std.mem.Allocator, iterations: usize) !u64 {
    var best: u64 = std.math.maxInt(u64);
    for (0..samples) |_| {
        var text: std.ArrayList(u8) = .empty;
        defer text.deinit(allocator);
        try text.appendNTimes(allocator, 'x', iterations + 4);

        var buffer = try nivi.Buffer.initFromText(allocator, text.items);
        defer buffer.deinit();
        var cursor = nivi.Cursor.init(buffer);
        var vim = nivi.vim.State.init(allocator);
        defer vim.deinit();

        const start = nowNanos();
        for (0..iterations) |_| {
            _ = try vim.handleNormal(&buffer, &cursor, .{ .char = 'r' });
            _ = try vim.handleNormal(&buffer, &cursor, .{ .char = 'y' });
            _ = try vim.handleNormal(&buffer, &cursor, .{ .char = 'l' });
        }
        std.mem.doNotOptimizeAway(buffer.byteLen());
        best = @min(best, elapsed(start));
    }
    return best;
}

fn benchToggle(allocator: std.mem.Allocator, iterations: usize) !u64 {
    var best: u64 = std.math.maxInt(u64);
    for (0..samples) |_| {
        var text: std.ArrayList(u8) = .empty;
        defer text.deinit(allocator);
        try text.appendNTimes(allocator, 'x', iterations + 4);

        var buffer = try nivi.Buffer.initFromText(allocator, text.items);
        defer buffer.deinit();
        var cursor = nivi.Cursor.init(buffer);
        var vim = nivi.vim.State.init(allocator);
        defer vim.deinit();

        const start = nowNanos();
        for (0..iterations) |_| _ = try vim.handleNormal(&buffer, &cursor, .{ .char = '~' });
        std.mem.doNotOptimizeAway(buffer.byteLen());
        best = @min(best, elapsed(start));
    }
    return best;
}

fn benchJoin(allocator: std.mem.Allocator, iterations: usize) !u64 {
    var best: u64 = std.math.maxInt(u64);
    for (0..samples) |_| {
        var text: std.ArrayList(u8) = .empty;
        defer text.deinit(allocator);
        try fillLines(allocator, &text, iterations + 4);

        var buffer = try nivi.Buffer.initFromText(allocator, text.items);
        defer buffer.deinit();
        var cursor = nivi.Cursor.init(buffer);
        var vim = nivi.vim.State.init(allocator);
        defer vim.deinit();

        const start = nowNanos();
        for (0..iterations) |_| _ = try vim.handleNormal(&buffer, &cursor, .{ .char = 'J' });
        std.mem.doNotOptimizeAway(buffer.byteLen());
        best = @min(best, elapsed(start));
    }
    return best;
}

fn fillWords(allocator: std.mem.Allocator, text: *std.ArrayList(u8), count: usize) !void {
    try text.ensureTotalCapacity(allocator, count * 6);
    var buf: [32]u8 = undefined;
    for (0..count) |i| {
        const word = std.fmt.bufPrint(&buf, "w{d} ", .{i % 1000}) catch unreachable;
        try text.appendSlice(allocator, word);
    }
}

fn fillLines(allocator: std.mem.Allocator, text: *std.ArrayList(u8), count: usize) !void {
    try text.ensureTotalCapacity(allocator, count * 16);
    var buf: [32]u8 = undefined;
    for (0..count) |i| {
        const line = std.fmt.bufPrint(&buf, "line {d}\n", .{i}) catch unreachable;
        try text.appendSlice(allocator, line);
    }
}

fn fillParagraphs(allocator: std.mem.Allocator, text: *std.ArrayList(u8), count: usize) !void {
    try text.ensureTotalCapacity(allocator, count * 14);
    for (0..count) |i| {
        if (i % 3 == 2) {
            try text.appendSlice(allocator, "\n");
        } else {
            try text.appendSlice(allocator, "word word\n");
        }
    }
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
    const per_op = if (ops == 0) 0 else ns / ops;
    std.debug.print("{s}: total_ns={d} ops={d} ns_per_op={d}\n", .{ name, ns, ops, per_op });
}
