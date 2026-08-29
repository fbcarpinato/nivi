const std = @import("std");
const Rope = @import("nivi").Rope;
const Buffer = @import("nivi").Buffer;
const Cursor = @import("nivi").Cursor;

const KiB = 1024;
const MiB = KiB * KiB;
const samples = 5;

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    var initial: std.ArrayList(u8) = .empty;
    defer initial.deinit(allocator);
    try fillText(allocator, &initial, 1 * MiB);

    var large: std.ArrayList(u8) = .empty;
    defer large.deinit(allocator);
    try fillText(allocator, &large, 10 * MiB);

    var many_lines: std.ArrayList(u8) = .empty;
    defer many_lines.deinit(allocator);
    try fillManySmallLines(allocator, &many_lines, 250_000);

    var huge_lines: std.ArrayList(u8) = .empty;
    defer huge_lines.deinit(allocator);
    try fillHugeLines(allocator, &huge_lines, 4 * MiB);

    var unicode_text: std.ArrayList(u8) = .empty;
    defer unicode_text.deinit(allocator);
    try fillUnicodeText(allocator, &unicode_text, 1 * MiB);

    const build = try benchBuild(allocator, initial.items);
    printStats("build_1mib", build.ns, 1, build.stats);

    const build_large = try benchBuild(allocator, large.items);
    printStats("build_10mib", build_large.ns, 1, build_large.stats);

    var rope = Rope.init(allocator);
    defer rope.deinit();
    try rope.setText(initial.items);

    const lookup_ns = benchLookup(rope, 200_000);
    printStats("byte_at_200k", lookup_ns, 200_000, rope.stats());

    const line_ns = benchLineLookup(rope, 100_000);
    printStats("line_column_100k", line_ns, 100_000, rope.stats());

    const viewport_ns = try benchViewports(allocator, rope, 10_000, 50);
    printStats("viewport_10k_x50", viewport_ns, 10_000, rope.stats());

    const many_line_lookup = try benchTextLineLookups(allocator, many_lines.items, 100_000);
    printStats("many_lines_lookup_100k", many_line_lookup.ns, 100_000, many_line_lookup.stats);

    const huge_byte_lookup = try benchTextByteLookups(allocator, huge_lines.items, 200_000);
    printStats("huge_lines_byte_at_200k", huge_byte_lookup.ns, 200_000, huge_byte_lookup.stats);

    const unicode_validate = try benchUtf8Validate(allocator, unicode_text.items);
    printStats("utf8_validate_1mib", unicode_validate.ns, 1, unicode_validate.stats);

    const unicode_count = try benchUtf8Count(allocator, unicode_text.items);
    printStats("utf8_count_1mib", unicode_count.ns, 1, unicode_count.stats);

    const grapheme_count = try benchGraphemeCount(allocator, unicode_text.items);
    printStats("grapheme_count_1mib", grapheme_count.ns, 1, grapheme_count.stats);

    const display_width = try benchDisplayWidth(allocator, unicode_text.items);
    printStats("display_width_1mib", display_width.ns, 1, display_width.stats);

    const visual_columns = try benchVisualColumns(allocator, unicode_text.items, 100_000);
    printStats("visual_column_100k", visual_columns.ns, 100_000, visual_columns.stats);

    const edits = try benchEdits(allocator, initial.items);
    printStats("insert_20k", edits.insert_ns, 20_000, edits.stats_after_insert);
    printStats("delete_10k", edits.delete_ns, 10_000, edits.stats_after_delete);
    printStats("compact_after_edits", edits.compact_ns, 1, edits.stats_after_compact);

    const random_edits = try benchRandomEdits(allocator, initial.items, 20_000);
    printStats("random_edit_20k", random_edits.ns, 20_000, random_edits.stats);

    const cursor_typing = try benchCursorTyping(allocator);
    printStats("cursor_type_100k", cursor_typing.ns, 100_000, cursor_typing.stats);

    const normal_typing = try benchNormalTyping(allocator);
    printStats("normal_type_100k", normal_typing.ns, 100_000, normal_typing.stats);

    const utf8_typing = try benchUtf8Typing(allocator);
    printStats("utf8_type_100k", utf8_typing.ns, 100_000, utf8_typing.stats);

    const buffer_typing = try benchBufferTyping(allocator);
    printStats("buffer_type_100k", buffer_typing.ns, 100_000, buffer_typing.stats);

    const buffer_backspace = try benchBufferBackspace(allocator);
    printStats("buffer_backspace_50k", buffer_backspace.ns, 50_000, buffer_backspace.stats);

    const undo_redo = try benchUndoRedo(allocator);
    printStats("undo_redo_1k", undo_redo.ns, 2000, undo_redo.stats);

    const flatten_ns = try benchFlatten(allocator, rope);
    printStats("flatten", flatten_ns, 1, rope.stats());
}

const BuildSample = struct {
    ns: u64,
    stats: Rope.Stats,
};

const EditSample = struct {
    insert_ns: u64,
    delete_ns: u64,
    compact_ns: u64,
    stats_after_insert: Rope.Stats,
    stats_after_delete: Rope.Stats,
    stats_after_compact: Rope.Stats,
};

const CursorSample = struct {
    ns: u64,
    stats: Rope.Stats,
};

const TimedStats = struct {
    ns: u64,
    stats: Rope.Stats,
};

fn fillText(allocator: std.mem.Allocator, out: *std.ArrayList(u8), target_len: usize) !void {
    const line = "0123456789 abcdefghijklmnopqrstuvwxyz ABCDEFGHIJKLMNOPQRSTUVWXYZ\n";
    while (out.items.len < target_len) {
        const remaining = target_len - out.items.len;
        try out.appendSlice(allocator, line[0..@min(remaining, line.len)]);
    }
}

fn fillManySmallLines(allocator: std.mem.Allocator, out: *std.ArrayList(u8), lines: usize) !void {
    for (0..lines) |index| {
        try out.print(allocator, "{d}\n", .{index});
    }
}

fn fillHugeLines(allocator: std.mem.Allocator, out: *std.ArrayList(u8), target_len: usize) !void {
    const chunk = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789";
    while (out.items.len < target_len) {
        const remaining = target_len - out.items.len;
        if (remaining == 1) {
            try out.append(allocator, '\n');
        } else {
            try out.appendSlice(allocator, chunk[0..@min(remaining - 1, chunk.len)]);
        }
    }
}

fn fillUnicodeText(allocator: std.mem.Allocator, out: *std.ArrayList(u8), target_len: usize) !void {
    const line = "ascii café 世界 🌊 editor 🚀\n";
    while (out.items.len < target_len) {
        const remaining = target_len - out.items.len;
        try out.appendSlice(allocator, line[0..@min(remaining, line.len)]);
    }
}

fn timeSetText(rope: *Rope, text: []const u8) !u64 {
    const start = nowNanos();
    try rope.setText(text);
    return elapsed(start);
}

fn benchBuild(allocator: std.mem.Allocator, text: []const u8) !BuildSample {
    var best: BuildSample = .{ .ns = std.math.maxInt(u64), .stats = undefined };
    for (0..samples) |_| {
        var rope = Rope.init(allocator);
        defer rope.deinit();

        const ns = try timeSetText(&rope, text);
        if (ns < best.ns) best = .{ .ns = ns, .stats = rope.stats() };
    }
    return best;
}

fn benchLookup(rope: Rope, iterations: usize) u64 {
    var best: u64 = std.math.maxInt(u64);
    for (0..samples) |_| best = @min(best, timeLookups(rope, iterations));
    return best;
}

fn benchLineLookup(rope: Rope, iterations: usize) u64 {
    var best: u64 = std.math.maxInt(u64);
    for (0..samples) |_| best = @min(best, timeLineLookups(rope, iterations));
    return best;
}

fn benchTextLineLookups(allocator: std.mem.Allocator, text: []const u8, iterations: usize) !TimedStats {
    var rope = Rope.init(allocator);
    defer rope.deinit();
    try rope.setText(text);
    return .{ .ns = benchLineLookup(rope, iterations), .stats = rope.stats() };
}

fn benchTextByteLookups(allocator: std.mem.Allocator, text: []const u8, iterations: usize) !TimedStats {
    var rope = Rope.init(allocator);
    defer rope.deinit();
    try rope.setText(text);
    return .{ .ns = benchLookup(rope, iterations), .stats = rope.stats() };
}

fn benchUtf8Validate(allocator: std.mem.Allocator, text: []const u8) !TimedStats {
    var rope = Rope.init(allocator);
    defer rope.deinit();
    try rope.setText(text);

    var best: u64 = std.math.maxInt(u64);
    for (0..samples) |_| {
        const start = nowNanos();
        std.mem.doNotOptimizeAway(rope.validateUtf8());
        best = @min(best, elapsed(start));
    }
    return .{ .ns = best, .stats = rope.stats() };
}

fn benchUtf8Count(allocator: std.mem.Allocator, text: []const u8) !TimedStats {
    var rope = Rope.init(allocator);
    defer rope.deinit();
    try rope.setText(text);

    var best: u64 = std.math.maxInt(u64);
    for (0..samples) |_| {
        const start = nowNanos();
        std.mem.doNotOptimizeAway(try rope.countCodepointsUtf8(.{ .start = 0, .end = rope.byteLen() }));
        best = @min(best, elapsed(start));
    }
    return .{ .ns = best, .stats = rope.stats() };
}

fn benchGraphemeCount(allocator: std.mem.Allocator, text: []const u8) !TimedStats {
    var rope = Rope.init(allocator);
    defer rope.deinit();
    try rope.setText(text);

    var best: u64 = std.math.maxInt(u64);
    for (0..samples) |_| {
        const start = nowNanos();
        const count = try rope.countGraphemes(.{ .start = 0, .end = rope.byteLen() });
        std.mem.doNotOptimizeAway(count);
        best = @min(best, elapsed(start));
    }
    return .{ .ns = best, .stats = rope.stats() };
}

fn benchDisplayWidth(allocator: std.mem.Allocator, text: []const u8) !TimedStats {
    var rope = Rope.init(allocator);
    defer rope.deinit();
    try rope.setText(text);

    var best: u64 = std.math.maxInt(u64);
    for (0..samples) |_| {
        const start = nowNanos();
        std.mem.doNotOptimizeAway(try rope.displayWidth(.{ .start = 0, .end = rope.byteLen() }, 4));
        best = @min(best, elapsed(start));
    }
    return .{ .ns = best, .stats = rope.stats() };
}

fn benchVisualColumns(allocator: std.mem.Allocator, text: []const u8, iterations: usize) !TimedStats {
    var rope = Rope.init(allocator);
    defer rope.deinit();
    try rope.setText(text);

    var best: u64 = std.math.maxInt(u64);
    for (0..samples) |_| {
        const lines = @max(rope.lineCount(), 1);
        var checksum: usize = 0;
        const start = nowNanos();
        for (0..iterations) |index| {
            checksum +%= try rope.byteOffsetForLineVisualColumn((index * 37) % lines, index % 40, 4);
        }
        std.mem.doNotOptimizeAway(checksum);
        best = @min(best, elapsed(start));
    }
    return .{ .ns = best, .stats = rope.stats() };
}

fn benchEdits(allocator: std.mem.Allocator, text: []const u8) !EditSample {
    var best: EditSample = .{
        .insert_ns = std.math.maxInt(u64),
        .delete_ns = std.math.maxInt(u64),
        .compact_ns = std.math.maxInt(u64),
        .stats_after_insert = undefined,
        .stats_after_delete = undefined,
        .stats_after_compact = undefined,
    };

    for (0..samples) |_| {
        var rope = Rope.init(allocator);
        defer rope.deinit();
        try rope.setText(text);

        const insert_ns = try timeInserts(&rope, 20_000);
        const stats_after_insert = rope.stats();
        const delete_ns = try timeDeletes(&rope, 10_000);
        const stats_after_delete = rope.stats();
        const compact_ns = try timeCompact(&rope);
        const stats_after_compact = rope.stats();

        if (insert_ns + delete_ns < best.insert_ns + best.delete_ns) {
            best = .{
                .insert_ns = insert_ns,
                .delete_ns = delete_ns,
                .compact_ns = compact_ns,
                .stats_after_insert = stats_after_insert,
                .stats_after_delete = stats_after_delete,
                .stats_after_compact = stats_after_compact,
            };
        }
    }

    return best;
}

fn benchFlatten(allocator: std.mem.Allocator, rope: Rope) !u64 {
    var best: u64 = std.math.maxInt(u64);
    for (0..samples) |_| best = @min(best, try timeFlatten(allocator, rope));
    return best;
}

fn benchViewports(allocator: std.mem.Allocator, rope: Rope, iterations: usize, viewport_lines: usize) !u64 {
    var scratch = try allocator.alloc(u8, 16 * KiB);
    defer allocator.free(scratch);

    var best: u64 = std.math.maxInt(u64);
    for (0..samples) |_| {
        var checksum: usize = 0;
        const lines = @max(rope.lineCount(), 1);
        const start = nowNanos();
        for (0..iterations) |index| {
            const range = rope.byteRangeForLines((index * 17) % lines, viewport_lines);
            const len = @min(scratch.len, range.end - range.start);
            rope.copyRange(scratch[0..len], range.start);
            checksum +%= len;
            if (len != 0) checksum +%= scratch[0];
        }
        std.mem.doNotOptimizeAway(checksum);
        best = @min(best, elapsed(start));
    }
    return best;
}

fn benchRandomEdits(allocator: std.mem.Allocator, text: []const u8, iterations: usize) !TimedStats {
    var best: TimedStats = .{ .ns = std.math.maxInt(u64), .stats = undefined };
    for (0..samples) |_| {
        var rope = Rope.init(allocator);
        defer rope.deinit();
        try rope.setText(text);

        var rng = std.Random.DefaultPrng.init(0x12345678);
        const random = rng.random();
        const snippets = [_][]const u8{ "a", "bb", "ccc", "\n", "editor" };

        const start = nowNanos();
        for (0..iterations) |_| {
            if (random.boolean()) {
                const offset = random.uintLessThan(usize, rope.byteLen() + 1);
                try rope.insert(offset, snippets[random.uintLessThan(usize, snippets.len)]);
            } else if (rope.byteLen() != 0) {
                const offset = random.uintLessThan(usize, rope.byteLen());
                try rope.delete(offset, @min(random.uintLessThan(usize, 8) + 1, rope.byteLen() - offset));
            }
        }
        const ns = elapsed(start);
        if (ns < best.ns) best = .{ .ns = ns, .stats = rope.stats() };
    }
    return best;
}

fn benchCursorTyping(allocator: std.mem.Allocator) !CursorSample {
    var best: CursorSample = .{ .ns = std.math.maxInt(u64), .stats = undefined };
    for (0..samples) |_| {
        var rope = Rope.init(allocator);
        defer rope.deinit();
        try rope.setText("");

        var cursor: Rope.Cursor = .{};
        rope.seekCursor(&cursor, 0);

        const start = nowNanos();
        for (0..100_000) |index| {
            try rope.insertAtCursor(&cursor, if (index % 64 == 63) "\n" else "x");
        }
        const ns = elapsed(start);
        if (ns < best.ns) best = .{ .ns = ns, .stats = rope.stats() };
    }
    return best;
}

fn benchNormalTyping(allocator: std.mem.Allocator) !CursorSample {
    var best: CursorSample = .{ .ns = std.math.maxInt(u64), .stats = undefined };
    for (0..samples) |_| {
        var rope = Rope.init(allocator);
        defer rope.deinit();
        try rope.setText("");

        const start = nowNanos();
        for (0..100_000) |index| {
            try rope.insert(rope.byteLen(), if (index % 64 == 63) "\n" else "x");
        }
        const ns = elapsed(start);
        if (ns < best.ns) best = .{ .ns = ns, .stats = rope.stats() };
    }
    return best;
}

fn benchUtf8Typing(allocator: std.mem.Allocator) !CursorSample {
    var best: CursorSample = .{ .ns = std.math.maxInt(u64), .stats = undefined };
    for (0..samples) |_| {
        var rope = Rope.init(allocator);
        defer rope.deinit();
        try rope.setText("");

        const start = nowNanos();
        for (0..100_000) |index| {
            _ = try rope.insertUtf8(rope.byteLen(), if (index % 64 == 63) "🌊" else "x", .assert_boundary);
        }
        const ns = elapsed(start);
        if (ns < best.ns) best = .{ .ns = ns, .stats = rope.stats() };
    }
    return best;
}

fn benchBufferTyping(allocator: std.mem.Allocator) !CursorSample {
    var best: CursorSample = .{ .ns = std.math.maxInt(u64), .stats = undefined };
    for (0..samples) |_| {
        var buffer = try Buffer.init(allocator);
        defer buffer.deinit();

        var cursor = Cursor.init(buffer);
        buffer.beginUndoGroup(cursor.offset); // realistic: one insert-mode session
        const start = nowNanos();
        for (0..100_000) |index| {
            try cursor.insertText(&buffer, if (index % 64 == 63) "\n" else "x");
        }
        const ns = elapsed(start);
        buffer.endUndoGroup(cursor.offset);
        if (ns < best.ns) best = .{ .ns = ns, .stats = buffer.rope.stats() };
    }
    return best;
}

fn benchBufferBackspace(allocator: std.mem.Allocator) !CursorSample {
    var best: CursorSample = .{ .ns = std.math.maxInt(u64), .stats = undefined };
    for (0..samples) |_| {
        var buffer = try Buffer.init(allocator);
        defer buffer.deinit();

        var cursor = Cursor.init(buffer);
        buffer.beginUndoGroup(cursor.offset);
        for (0..100_000) |index| {
            try cursor.insertText(&buffer, if (index % 64 == 63) "\n" else "x");
        }
        buffer.endUndoGroup(cursor.offset);

        buffer.beginUndoGroup(cursor.offset);
        const start = nowNanos();
        for (0..50_000) |_| {
            try cursor.deleteBackward(&buffer);
        }
        const ns = elapsed(start);
        buffer.endUndoGroup(cursor.offset);
        if (ns < best.ns) best = .{ .ns = ns, .stats = buffer.rope.stats() };
    }
    return best;
}

fn benchUndoRedo(allocator: std.mem.Allocator) !CursorSample {
    var best: CursorSample = .{ .ns = std.math.maxInt(u64), .stats = undefined };
    for (0..samples) |_| {
        var buffer = try Buffer.init(allocator);
        defer buffer.deinit();

        // 1000 separate undoable edits.
        for (0..1000) |index| {
            try buffer.insert(buffer.byteLen(), if (index % 8 == 7) "word\n" else "word ");
        }

        const start = nowNanos();
        var iter: usize = 0;
        while (iter < 1000) : (iter += 1) _ = try buffer.undo();
        iter = 0;
        while (iter < 1000) : (iter += 1) _ = try buffer.redo();
        const ns = elapsed(start);
        if (ns < best.ns) best = .{ .ns = ns, .stats = buffer.rope.stats() };
    }
    return best;
}

fn timeLookups(rope: Rope, iterations: usize) u64 {
    const len = rope.byteLen();
    var checksum: usize = 0;
    const start = nowNanos();
    for (0..iterations) |index| {
        checksum +%= rope.byteAt((index * 4099) % len);
    }
    std.mem.doNotOptimizeAway(checksum);
    return elapsed(start);
}

fn timeLineLookups(rope: Rope, iterations: usize) u64 {
    const lines = @max(rope.lineCount(), 1);
    var checksum: usize = 0;
    const start = nowNanos();
    for (0..iterations) |index| {
        checksum +%= rope.byteOffsetForLineColumn((index * 31) % lines, index % 80);
    }
    std.mem.doNotOptimizeAway(checksum);
    return elapsed(start);
}

fn timeInserts(rope: *Rope, iterations: usize) !u64 {
    const snippets = [_][]const u8{ "x", "fast", "\n", "rope", "0123456789" };
    const start = nowNanos();
    for (0..iterations) |index| {
        const offset = (index * 7919) % (rope.byteLen() + 1);
        try rope.insert(offset, snippets[index % snippets.len]);
    }
    return elapsed(start);
}

fn timeDeletes(rope: *Rope, iterations: usize) !u64 {
    const start = nowNanos();
    for (0..iterations) |index| {
        const len = rope.byteLen();
        if (len == 0) break;
        const offset = (index * 3571) % len;
        try rope.delete(offset, @min(3, len - offset));
    }
    return elapsed(start);
}

fn timeFlatten(allocator: std.mem.Allocator, rope: Rope) !u64 {
    const start = nowNanos();
    const out = try rope.toOwnedSlice(allocator);
    std.mem.doNotOptimizeAway(out.ptr);
    allocator.free(out);
    return elapsed(start);
}

fn timeCompact(rope: *Rope) !u64 {
    const start = nowNanos();
    try rope.compact();
    return elapsed(start);
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

fn printStats(name: []const u8, ns: u64, ops: usize, stats: Rope.Stats) void {
    const ns_per_op = if (ops == 0) 0 else ns / ops;
    std.debug.print(
        "{s}: total_ns={d} ops={d} ns_per_op={d} bytes={d} lines={d} height={d} nodes={d} branches={d} leaves={d} node_slabs={d} leaf_slabs={d} allocated_nodes={d} allocated_leaf_data={d} node_size={d} leaf_data_size={d} slab_bytes={d}\n",
        .{
            name,
            ns,
            ops,
            ns_per_op,
            stats.byte_len,
            stats.line_count,
            stats.height,
            stats.node_count,
            stats.branch_count,
            stats.leaf_count,
            stats.slab_count,
            stats.leaf_slab_count,
            stats.allocated_nodes,
            stats.allocated_leaf_data,
            stats.node_size,
            stats.leaf_data_size,
            stats.slab_bytes,
        },
    );
}
