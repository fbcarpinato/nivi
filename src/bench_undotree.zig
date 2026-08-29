const std = @import("std");
const nivi = @import("nivi");
const Buffer = nivi.Buffer;
const Cursor = nivi.Cursor;
const UndoTree = nivi.UndoTree;

const samples = 5;

pub fn main() !void {
    // Grouped insert-mode typing recorded into the tree (one node).
    printStat("grouped_type_100k", try benchGroupedTyping(100_000), 100_000);
    // Backspaces coalesced into one reversed-store edit within a group.
    printStat("grouped_backspace_50k", try benchGroupedBackspace(50_000), 50_000);
    // Many standalone edits -> many committed nodes (node creation cost).
    printStat("commit_10k_nodes", try benchCommitNodes(10_000), 10_000);
    // Undo the whole linear chain, then redo it.
    printStat("undo_redo_10k", try benchUndoRedo(10_000), 20_000);
    // Look up random states by sequence id.
    printStat("find_by_seq_100k", try benchFindBySeq(10_000, 100_000), 100_000);
    // Jump between two nearby branch tips repeatedly (LCA traversal + lookup).
    printStat("branch_jump_20k", try benchBranchJump(128, 20_000), 20_000);
}

fn benchGroupedTyping(count: usize) !u64 {
    var best: u64 = std.math.maxInt(u64);
    for (0..samples) |_| {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        var buffer = try Buffer.init(arena.allocator());
        var cursor = Cursor.init(buffer);

        buffer.beginUndoGroup(cursor.offset);
        const start = nowNanos();
        for (0..count) |i| {
            try cursor.insertText(&buffer, if (i % 64 == 63) "\n" else "x");
        }
        const ns = elapsed(start);
        buffer.endUndoGroup(cursor.offset);
        best = @min(best, ns);
    }
    return best;
}

fn benchGroupedBackspace(count: usize) !u64 {
    var best: u64 = std.math.maxInt(u64);
    for (0..samples) |_| {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        var buffer = try Buffer.init(arena.allocator());
        var cursor = Cursor.init(buffer);

        buffer.beginUndoGroup(cursor.offset);
        for (0..count * 2) |i| {
            try cursor.insertText(&buffer, if (i % 64 == 63) "\n" else "x");
        }
        buffer.endUndoGroup(cursor.offset);

        buffer.beginUndoGroup(cursor.offset);
        const start = nowNanos();
        for (0..count) |_| try cursor.deleteBackward(&buffer);
        const ns = elapsed(start);
        buffer.endUndoGroup(cursor.offset);
        best = @min(best, ns);
    }
    return best;
}

fn benchCommitNodes(count: usize) !u64 {
    var best: u64 = std.math.maxInt(u64);
    for (0..samples) |_| {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        var buffer = try Buffer.init(arena.allocator());

        const start = nowNanos();
        for (0..count) |i| {
            // Append then a gap edit so each records as its own committed node.
            try buffer.insert(buffer.byteLen(), if (i % 8 == 7) "y\n" else "y");
        }
        best = @min(best, elapsed(start));
    }
    return best;
}

fn benchUndoRedo(count: usize) !u64 {
    var best: u64 = std.math.maxInt(u64);
    for (0..samples) |_| {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        var buffer = try Buffer.init(arena.allocator());
        for (0..count) |i| {
            try buffer.insert(buffer.byteLen(), if (i % 8 == 7) "y\n" else "y");
        }

        const start = nowNanos();
        var n: usize = 0;
        while (n < count) : (n += 1) _ = try buffer.undo();
        n = 0;
        while (n < count) : (n += 1) _ = try buffer.redo();
        best = @min(best, elapsed(start));
    }
    return best;
}

fn benchFindBySeq(nodes: usize, lookups: usize) !u64 {
    var best: u64 = std.math.maxInt(u64);
    for (0..samples) |_| {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        var buffer = try Buffer.init(arena.allocator());
        for (0..nodes) |i| {
            try buffer.insert(buffer.byteLen(), if (i % 8 == 7) "y\n" else "y");
        }

        var checksum: usize = 0;
        const start = nowNanos();
        for (0..lookups) |i| {
            const seq: u64 = @intCast((i * 2654435761) % nodes);
            if (buffer.undo_tree.findBySeq(seq)) |node| checksum +%= node.depth;
        }
        std.mem.doNotOptimizeAway(checksum);
        best = @min(best, elapsed(start));
    }
    return best;
}

fn benchBranchJump(nodes: usize, jumps: usize) !u64 {
    var best: u64 = std.math.maxInt(u64);
    for (0..samples) |_| {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        var buffer = try Buffer.init(arena.allocator());

        // Build branch A.
        for (0..nodes) |_| try buffer.insert(buffer.byteLen(), "a");
        const tip_a = buffer.undo_tree.current.seq;

        // Go back to root and build branch B.
        _ = try buffer.jumpToState(0);
        for (0..nodes) |_| try buffer.insert(buffer.byteLen(), "b");
        const tip_b = buffer.undo_tree.current.seq;

        const start = nowNanos();
        for (0..jumps) |i| {
            _ = try buffer.jumpToState(if (i % 2 == 0) tip_a else tip_b);
        }
        best = @min(best, elapsed(start));
    }
    return best;
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
    const ns_per_op = if (ops == 0) 0 else ns / ops;
    std.debug.print("{s}: total_ns={d} ops={d} ns_per_op={d}\n", .{ name, ns, ops, ns_per_op });
}
