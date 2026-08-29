const std = @import("std");

/// A single reversible edit: at `offset`, `old_text` was replaced by `new_text`.
/// Pure inserts have empty `old_text`; pure deletes have empty `new_text`.
pub const Edit = struct {
    offset: usize,
    old_text: std.ArrayListUnmanaged(u8) = .empty,
    new_text: std.ArrayListUnmanaged(u8) = .empty,
    old_text_reversed: bool = false,

    pub fn deinit(self: *Edit, allocator: std.mem.Allocator) void {
        self.old_text.deinit(allocator);
        self.new_text.deinit(allocator);
    }

    pub fn isPureInsert(self: Edit) bool {
        return self.old_text.items.len == 0;
    }

    pub fn isPureDelete(self: Edit) bool {
        return self.new_text.items.len == 0 and self.old_text.items.len != 0;
    }
};

/// A node is a *state* of the buffer. The root is the state captured when the
/// file was opened; every other node stores the transition (`edits`) that turns
/// its parent's state into this one, plus caret positions and metadata for a
/// future state-navigation UI.
pub const Node = struct {
    seq: u64,
    depth: usize,
    parent: ?*Node,
    children: std.ArrayListUnmanaged(*Node) = .empty,
    /// Index into `children` chosen by a plain redo (the most recent branch).
    last_visited: usize = 0,
    /// Transition parent -> this. Empty for the root.
    edits: std.ArrayListUnmanaged(Edit) = .empty,
    cursor_before: usize = 0,
    cursor_after: usize = 0,
    timestamp: i64 = 0,

    fn deinit(self: *Node, allocator: std.mem.Allocator) void {
        for (self.edits.items) |*edit| edit.deinit(allocator);
        self.edits.deinit(allocator);
        self.children.deinit(allocator);
    }
};

const OpenTransaction = struct {
    edits: std.ArrayListUnmanaged(Edit) = .empty,
    cursor_before: usize = 0,
    cursor_after: usize = 0,
};

/// Persistent undo/redo tree. Unlike a linear history, a new edit made after an
/// undo starts a *new branch* rather than discarding the redo side, so every
/// visited state remains reachable.
///
/// The tree owns edit storage and structure. It does not touch the text buffer;
/// the owner (`Buffer`) reads `current`/`Node.edits` and applies them to the
/// rope. Coalescing and grouping mirror an editor's insert-mode sessions.
pub const UndoTree = struct {
    allocator: std.mem.Allocator,
    root: *Node,
    current: *Node,
    next_seq: u64 = 1,
    open: ?OpenTransaction = null,
    group_depth: usize = 0,
    clock: *const fn () i64 = zeroClock,
    /// O(1) lookup by sequence id (for state navigation).
    index: std.AutoHashMapUnmanaged(u64, *Node) = .empty,
    /// Flat list of every node, for iterative (stack-safe) teardown.
    all_nodes: std.ArrayListUnmanaged(*Node) = .empty,

    fn zeroClock() i64 {
        return 0;
    }

    pub fn init(allocator: std.mem.Allocator) !UndoTree {
        const root = try allocator.create(Node);
        root.* = .{ .seq = 0, .depth = 0, .parent = null };
        var tree: UndoTree = .{ .allocator = allocator, .root = root, .current = root };
        try tree.all_nodes.append(allocator, root);
        try tree.index.put(allocator, 0, root);
        return tree;
    }

    pub fn deinit(self: *UndoTree) void {
        self.discardOpen();
        for (self.all_nodes.items) |node| {
            node.deinit(self.allocator);
            self.allocator.destroy(node);
        }
        self.all_nodes.deinit(self.allocator);
        self.index.deinit(self.allocator);
        self.* = undefined;
    }

    /// Reset to a fresh single-node tree (e.g. on `setText` / file reload).
    pub fn reset(self: *UndoTree) !void {
        self.discardOpen();
        for (self.all_nodes.items) |node| {
            if (node == self.root) continue;
            node.deinit(self.allocator);
            self.allocator.destroy(node);
        }
        self.all_nodes.clearRetainingCapacity();
        self.index.clearRetainingCapacity();
        try self.all_nodes.append(self.allocator, self.root);
        try self.index.put(self.allocator, 0, self.root);

        for (self.root.edits.items) |*edit| edit.deinit(self.allocator);
        self.root.edits.clearRetainingCapacity();
        self.root.children.clearRetainingCapacity();
        self.root.last_visited = 0;
        self.current = self.root;
        self.next_seq = 1;
    }

    pub fn canUndo(self: UndoTree) bool {
        if (self.current.parent != null) return true;
        return self.open != null and self.open.?.edits.items.len != 0;
    }

    pub fn canRedo(self: UndoTree) bool {
        return self.current.children.items.len != 0;
    }

    /// The child a plain redo would move to (newest visited branch), or null.
    pub fn redoChild(self: UndoTree) ?*Node {
        const children = self.current.children.items;
        if (children.len == 0) return null;
        return children[self.current.last_visited];
    }

    pub fn findBySeq(self: UndoTree, seq: u64) ?*Node {
        return self.index.get(seq);
    }

    /// Lowest common ancestor of two nodes (both belong to this tree).
    pub fn lca(a: *Node, b: *Node) *Node {
        var x = a;
        var y = b;
        while (x.depth > y.depth) x = x.parent.?;
        while (y.depth > x.depth) y = y.parent.?;
        while (x != y) {
            x = x.parent.?;
            y = y.parent.?;
        }
        return x;
    }

    pub fn beginGroup(self: *UndoTree, cursor_offset: usize) void {
        if (self.group_depth == 0) {
            self.commitOpen();
            self.open = .{ .cursor_before = cursor_offset, .cursor_after = cursor_offset };
        }
        self.group_depth += 1;
    }

    pub fn endGroup(self: *UndoTree, cursor_offset: usize) void {
        if (self.group_depth == 0) return;
        self.group_depth -= 1;
        if (self.group_depth == 0) {
            if (self.open) |*open| open.cursor_after = cursor_offset;
            self.commitOpen();
        }
    }

    fn ensureOpen(self: *UndoTree, offset: usize) *OpenTransaction {
        if (self.open == null) self.open = .{ .cursor_before = offset, .cursor_after = offset };
        return &self.open.?;
    }

    pub fn recordInsertion(self: *UndoTree, offset: usize, text: []const u8) !void {
        const auto = self.group_depth == 0;
        const txn = self.ensureOpen(offset);

        if (txn.edits.items.len != 0) {
            const last = &txn.edits.items[txn.edits.items.len - 1];
            if (last.isPureInsert() and last.offset + last.new_text.items.len == offset) {
                try last.new_text.appendSlice(self.allocator, text);
                txn.cursor_after = offset + text.len;
                if (auto) self.commitOpen();
                return;
            }
        }

        var edit: Edit = .{ .offset = offset };
        try edit.new_text.appendSlice(self.allocator, text);
        try txn.edits.append(self.allocator, edit);
        txn.cursor_after = offset + text.len;
        if (auto) self.commitOpen();
    }

    pub fn recordDeletion(self: *UndoTree, offset: usize, deleted: []const u8) !void {
        const auto = self.group_depth == 0;
        const txn = self.ensureOpen(offset);

        // Coalesce repeated forward-deletes (Del key) at the same point, and
        // backspaces immediately before the last deleted range. Backspaces store
        // bytes in reverse deletion order to avoid O(n) prepends per keypress.
        if (txn.edits.items.len != 0) {
            const last = &txn.edits.items[txn.edits.items.len - 1];
            if (last.isPureDelete() and !last.old_text_reversed and last.offset == offset) {
                try last.old_text.appendSlice(self.allocator, deleted);
                txn.cursor_after = offset;
                if (auto) self.commitOpen();
                return;
            }
            if (last.isPureDelete() and deleted.len == 1 and (last.old_text_reversed or last.old_text.items.len == 1) and offset + deleted.len == last.offset) {
                try last.old_text.appendSlice(self.allocator, deleted);
                last.offset = offset;
                last.old_text_reversed = true;
                txn.cursor_after = offset;
                if (auto) self.commitOpen();
                return;
            }
        }

        var edit: Edit = .{ .offset = offset };
        try edit.old_text.appendSlice(self.allocator, deleted);
        try txn.edits.append(self.allocator, edit);
        txn.cursor_after = offset;
        if (auto) self.commitOpen();
    }

    /// Turn the open transaction into a new child node of `current`.
    pub fn commitOpen(self: *UndoTree) void {
        var open = self.open orelse return;
        self.open = null;
        if (open.edits.items.len == 0) {
            open.edits.deinit(self.allocator);
            return;
        }

        // Reserve everything up front so the node either fully lands or is dropped.
        self.index.ensureUnusedCapacity(self.allocator, 1) catch return self.discardTransaction(&open);
        self.all_nodes.ensureUnusedCapacity(self.allocator, 1) catch return self.discardTransaction(&open);
        self.current.children.ensureUnusedCapacity(self.allocator, 1) catch return self.discardTransaction(&open);
        const node = self.allocator.create(Node) catch return self.discardTransaction(&open);

        node.* = .{
            .seq = self.next_seq,
            .depth = self.current.depth + 1,
            .parent = self.current,
            .edits = open.edits,
            .cursor_before = open.cursor_before,
            .cursor_after = open.cursor_after,
            .timestamp = self.clock(),
        };
        self.current.children.appendAssumeCapacity(node);
        self.current.last_visited = self.current.children.items.len - 1;
        self.all_nodes.appendAssumeCapacity(node);
        self.index.putAssumeCapacity(node.seq, node);
        self.current = node;
        self.next_seq += 1;
        open.edits = .empty; // ownership moved into `node`
    }

    fn discardOpen(self: *UndoTree) void {
        if (self.open) |*open| self.discardTransaction(open);
        self.open = null;
    }

    fn discardTransaction(self: *UndoTree, txn: *OpenTransaction) void {
        for (txn.edits.items) |*edit| edit.deinit(self.allocator);
        txn.edits.deinit(self.allocator);
    }
};

test "records and branches without discarding redo" {
    var tree = try UndoTree.init(std.testing.allocator);
    defer tree.deinit();

    try tree.recordInsertion(0, "a");
    const node_a = tree.current;
    try tree.recordInsertion(1, "b");
    try std.testing.expect(tree.canUndo());

    // Move back to the "a" state, then branch.
    tree.current = node_a;
    try std.testing.expect(tree.canRedo());
    try tree.recordInsertion(1, "c");

    // node_a now has two children: the original "b" branch and the new "c".
    try std.testing.expectEqual(@as(usize, 2), node_a.children.items.len);
    // node_a's default redo follows the most recently created branch ("c"),
    // which is the node we are now on.
    try std.testing.expectEqual(tree.current, node_a.children.items[node_a.last_visited]);
}

test "grouped edits coalesce into one node" {
    var tree = try UndoTree.init(std.testing.allocator);
    defer tree.deinit();

    tree.beginGroup(0);
    for ("hello") |ch| try tree.recordInsertion(tree.open.?.cursor_after, &.{ch});
    tree.endGroup(5);

    try std.testing.expectEqual(@as(usize, 1), tree.root.children.items.len);
    const node = tree.root.children.items[0];
    try std.testing.expectEqual(@as(usize, 1), node.edits.items.len);
    try std.testing.expectEqualStrings("hello", node.edits.items[0].new_text.items);
    try std.testing.expectEqual(@as(usize, 0), node.cursor_before);
    try std.testing.expectEqual(@as(usize, 5), node.cursor_after);
}

test "findBySeq locates nodes" {
    var tree = try UndoTree.init(std.testing.allocator);
    defer tree.deinit();

    try tree.recordInsertion(0, "x");
    const seq = tree.current.seq;
    try std.testing.expectEqual(tree.current, tree.findBySeq(seq).?);
    try std.testing.expectEqual(tree.root, tree.findBySeq(0).?);
    try std.testing.expectEqual(@as(?*Node, null), tree.findBySeq(9999));
}
