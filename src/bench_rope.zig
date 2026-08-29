const std = @import("std");
const Rope = @import("nivi").Rope;

const KiB = 1024;
const MiB = KiB * KiB;
const samples = 5;

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    var initial: std.ArrayList(u8) = .empty;
    defer initial.deinit(allocator);
    try fillText(allocator, &initial, 1 * MiB);

    const build = try benchBuild(allocator, initial.items);
    printStats("build_1mib", build.ns, 1, build.stats);

    var rope = Rope.init(allocator);
    defer rope.deinit();
    try rope.setText(initial.items);

    const lookup_ns = benchLookup(rope, 200_000);
    printStats("byte_at_200k", lookup_ns, 200_000, rope.stats());

    const line_ns = benchLineLookup(rope, 100_000);
    printStats("line_column_100k", line_ns, 100_000, rope.stats());

    const edits = try benchEdits(allocator, initial.items);
    printStats("insert_20k", edits.insert_ns, 20_000, edits.stats_after_insert);
    printStats("delete_10k", edits.delete_ns, 10_000, edits.stats_after_delete);
    printStats("compact_after_edits", edits.compact_ns, 1, edits.stats_after_compact);

    const cursor_typing = try benchCursorTyping(allocator);
    printStats("cursor_type_100k", cursor_typing.ns, 100_000, cursor_typing.stats);

    const normal_typing = try benchNormalTyping(allocator);
    printStats("normal_type_100k", normal_typing.ns, 100_000, normal_typing.stats);

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

fn fillText(allocator: std.mem.Allocator, out: *std.ArrayList(u8), target_len: usize) !void {
    const line = "0123456789 abcdefghijklmnopqrstuvwxyz ABCDEFGHIJKLMNOPQRSTUVWXYZ\n";
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
