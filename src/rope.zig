const std = @import("std");

pub const Rope = struct {
    pub const leaf_capacity = 160;
    pub const max_cursor_depth = 64;
    const newline_word_count = (leaf_capacity + 63) / 64;
    const slab_node_count = 4096;

    pub const Stats = struct {
        byte_len: usize,
        line_count: usize,
        height: usize,
        node_count: usize,
        branch_count: usize,
        leaf_count: usize,
        slab_count: usize,
        leaf_slab_count: usize,
        allocated_nodes: usize,
        allocated_leaf_data: usize,
        node_size: usize,
        leaf_data_size: usize,
        slab_bytes: usize,
    };

    const Node = union(enum) {
        branch: Branch,
        leaf: Leaf,
    };

    const Branch = struct {
        left: *Node,
        right: *Node,
        weight: usize,
        line_count: usize,
        byte_len: usize,
        total_line_count: usize,
        height: u8,
    };

    const Leaf = struct {
        data: *LeafData,
        len: u16,
        line_count: u16,
    };

    const LeafData = struct {
        text: [leaf_capacity]u8,
        newline_bits: [newline_word_count]u64,
    };

    const Split = struct {
        left: ?*Node,
        right: ?*Node,
    };

    pub const Cursor = struct {
        offset: usize = 0,
        leaf_start: usize = 0,
        leaf: ?*Node = null,
        path: [max_cursor_depth]PathEntry = undefined,
        path_len: usize = 0,
    };

    const PathEntry = struct {
        node: *Node,
        went_left: bool,
    };

    allocator: std.mem.Allocator,
    slabs: std.ArrayListUnmanaged([]Node) = .empty,
    leaf_slabs: std.ArrayListUnmanaged([]LeafData) = .empty,
    active_slab: []Node = &.{},
    active_leaf_slab: []LeafData = &.{},
    active_index: usize = 0,
    active_leaf_index: usize = 0,
    root: ?*Node = null,

    pub fn init(allocator: std.mem.Allocator) Rope {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Rope) void {
        self.releaseSlabs();
        self.slabs.deinit(self.allocator);
        self.leaf_slabs.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn setText(self: *Rope, text: []const u8) !void {
        self.releaseSlabs();
        self.root = try self.buildBalanced(text);
    }

    pub fn byteLen(self: Rope) usize {
        return nodeByteLen(self.root);
    }

    pub fn lineCount(self: Rope) usize {
        return nodeLineCount(self.root);
    }

    pub fn stats(self: Rope) Stats {
        const counts = countNodes(self.root);
        return .{
            .byte_len = self.byteLen(),
            .line_count = self.lineCount(),
            .height = nodeHeightOpt(self.root),
            .node_count = counts.nodes,
            .branch_count = counts.branches,
            .leaf_count = counts.leaves,
            .slab_count = self.slabs.items.len,
            .leaf_slab_count = self.leaf_slabs.items.len,
            .allocated_nodes = if (self.slabs.items.len == 0) 0 else (self.slabs.items.len - 1) * slab_node_count + self.active_index,
            .allocated_leaf_data = if (self.leaf_slabs.items.len == 0) 0 else (self.leaf_slabs.items.len - 1) * slab_node_count + self.active_leaf_index,
            .node_size = @sizeOf(Node),
            .leaf_data_size = @sizeOf(LeafData),
            .slab_bytes = self.slabs.items.len * slab_node_count * @sizeOf(Node) + self.leaf_slabs.items.len * slab_node_count * @sizeOf(LeafData),
        };
    }

    pub fn insert(self: *Rope, offset: usize, text: []const u8) !void {
        std.debug.assert(offset <= self.byteLen());
        if (text.len == 0) return;
        if (text.len <= leaf_capacity and tryInsertInPlace(self.root, offset, text, countNewlines(text))) return;

        if (offset == 0) {
            self.root = try self.prependOpt(try self.buildBalanced(text), self.root);
            return;
        }

        if (offset == self.byteLen()) {
            self.root = try self.appendOpt(self.root, try self.buildBalanced(text));
            return;
        }

        const split_root = try self.split(self.root, offset);
        const middle = try self.buildBalanced(text);
        self.root = try self.concatOpt(try self.concatOpt(split_root.left, middle), split_root.right);
    }

    pub fn seekCursor(self: Rope, cursor: *Cursor, offset: usize) void {
        std.debug.assert(offset <= self.byteLen());
        cursor.* = .{ .offset = offset };

        var current = self.root orelse return;
        var remaining = offset;
        var leaf_start: usize = 0;

        while (true) switch (current.*) {
            .leaf => {
                cursor.leaf = current;
                cursor.leaf_start = leaf_start;
                return;
            },
            .branch => |branch| {
                if (remaining < branch.weight or (remaining == branch.weight and nodeByteLen(branch.left) != 0)) {
                    cursor.path[cursor.path_len] = .{ .node = current, .went_left = true };
                    cursor.path_len += 1;
                    current = branch.left;
                } else {
                    cursor.path[cursor.path_len] = .{ .node = current, .went_left = false };
                    cursor.path_len += 1;
                    remaining -= branch.weight;
                    leaf_start += branch.weight;
                    current = branch.right;
                }
            },
        };
    }

    pub fn insertAtCursor(self: *Rope, cursor: *Cursor, text: []const u8) !void {
        if (text.len == 0) return;

        const line_delta = countNewlines(text);
        if (text.len <= leaf_capacity) {
            if (cursor.leaf) |leaf_node| switch (leaf_node.*) {
                .leaf => |*leaf| {
                    const leaf_offset = cursor.offset - cursor.leaf_start;
                    if (leaf_offset <= leaf.len and @as(usize, leaf.len) + text.len <= leaf_capacity) {
                        insertIntoLeaf(leaf, leaf_offset, text, line_delta);
                        updateCursorPathAfterInsert(cursor, text.len, line_delta);
                        cursor.offset += text.len;
                        return;
                    }
                },
                .branch => {},
            };
        }

        const insert_offset = cursor.offset;
        if (insert_offset == self.byteLen()) {
            self.root = try self.appendOpt(self.root, try self.buildBalanced(text));
            self.seekCursor(cursor, insert_offset + text.len);
            return;
        }

        try self.insert(insert_offset, text);
        self.seekCursor(cursor, insert_offset + text.len);
    }

    pub fn delete(self: *Rope, offset: usize, len: usize) !void {
        std.debug.assert(offset <= self.byteLen());
        std.debug.assert(len <= self.byteLen() - offset);
        if (len == 0) return;
        if (tryDeleteInPlace(self.root, offset, len) != null) {
            if (self.byteLen() == 0) self.root = null;
            return;
        }

        const prefix = try self.split(self.root, offset);
        const suffix = try self.split(prefix.right, len);
        self.root = try self.concatOpt(prefix.left, suffix.right);
    }

    pub fn byteAt(self: Rope, offset: usize) u8 {
        std.debug.assert(offset < self.byteLen());
        return nodeByteAt(self.root.?, offset);
    }

    pub fn byteOffsetForLineColumn(self: Rope, line: usize, column: usize) usize {
        const start = self.byteOffsetForLine(line);
        const end = self.byteOffsetForLine(line + 1);
        const line_end = if (end > start and self.byteAt(end - 1) == '\n') end - 1 else end;
        return start + @min(column, line_end - start);
    }

    pub fn byteOffsetForLine(self: Rope, line: usize) usize {
        if (line == 0) return 0;
        return nthNewlineEnd(self.root, line) orelse self.byteLen();
    }

    pub fn toOwnedSlice(self: Rope, allocator: std.mem.Allocator) ![]u8 {
        const out = try allocator.alloc(u8, self.byteLen());
        var index: usize = 0;
        copyNode(self.root, out, &index);
        return out;
    }

    pub fn compact(self: *Rope) !void {
        const text = try self.toOwnedSlice(self.allocator);
        defer self.allocator.free(text);

        self.releaseSlabs();
        self.root = try self.buildBalanced(text);
    }

    fn allocNode(self: *Rope) !*Node {
        if (self.active_index == self.active_slab.len) {
            self.active_slab = try self.allocator.alloc(Node, slab_node_count);
            try self.slabs.append(self.allocator, self.active_slab);
            self.active_index = 0;
        }

        const node = &self.active_slab[self.active_index];
        self.active_index += 1;
        return node;
    }

    fn allocLeafData(self: *Rope) !*LeafData {
        if (self.active_leaf_index == self.active_leaf_slab.len) {
            self.active_leaf_slab = try self.allocator.alloc(LeafData, slab_node_count);
            try self.leaf_slabs.append(self.allocator, self.active_leaf_slab);
            self.active_leaf_index = 0;
        }

        const data = &self.active_leaf_slab[self.active_leaf_index];
        self.active_leaf_index += 1;
        return data;
    }

    fn releaseSlabs(self: *Rope) void {
        for (self.slabs.items) |slab| self.allocator.free(slab);
        for (self.leaf_slabs.items) |slab| self.allocator.free(slab);
        self.slabs.clearRetainingCapacity();
        self.leaf_slabs.clearRetainingCapacity();
        self.active_slab = &.{};
        self.active_leaf_slab = &.{};
        self.active_index = 0;
        self.active_leaf_index = 0;
        self.root = null;
    }

    fn buildBalanced(self: *Rope, text: []const u8) !?*Node {
        if (text.len == 0) return null;
        if (text.len <= leaf_capacity) return try self.createLeaf(text);

        const leaves = (text.len + leaf_capacity - 1) / leaf_capacity;
        const left_leaves = leaves / 2;
        const split_at = left_leaves * leaf_capacity;
        return try self.createBranch((try self.buildBalanced(text[0..split_at])).?, (try self.buildBalanced(text[split_at..])).?);
    }

    fn createLeaf(self: *Rope, text: []const u8) !*Node {
        std.debug.assert(text.len <= leaf_capacity);

        return try self.createLeafWithLineCount(text, null);
    }

    fn createLeafWithLineCount(self: *Rope, text: []const u8, known_line_count: ?usize) !*Node {
        std.debug.assert(text.len <= leaf_capacity);

        const node = try self.allocNode();
        const data = try self.allocLeafData();
        var leaf: Leaf = .{
            .data = data,
            .len = @intCast(text.len),
            .line_count = 0,
        };
        data.* = .{ .text = undefined, .newline_bits = .{0} ** newline_word_count };
        @memcpy(leaf.data.text[0..text.len], text);
        const actual_line_count = rebuildNewlineBits(&leaf);
        leaf.line_count = @intCast(known_line_count orelse actual_line_count);
        node.* = .{ .leaf = leaf };
        return node;
    }

    fn createBranch(self: *Rope, left: *Node, right: *Node) !*Node {
        const node = try self.allocNode();
        const left_len = nodeByteLen(left);
        const right_len = nodeByteLen(right);
        const left_line_count = nodeLineCount(left);
        const right_line_count = nodeLineCount(right);
        node.* = .{ .branch = .{
            .left = left,
            .right = right,
            .weight = left_len,
            .line_count = left_line_count,
            .byte_len = left_len + right_len,
            .total_line_count = left_line_count + right_line_count,
            .height = @intCast(@max(nodeHeight(left), nodeHeight(right)) + 1),
        } };
        return node;
    }

    fn concatOpt(self: *Rope, left: ?*Node, right: ?*Node) !?*Node {
        if (left == null) return right;
        if (right == null) return left;
        return try self.concat(left.?, right.?);
    }

    fn appendOpt(self: *Rope, left: ?*Node, right: ?*Node) !?*Node {
        if (left == null) return right;
        if (right == null) return left;
        return try self.appendNode(left.?, right.?);
    }

    fn prependOpt(self: *Rope, left: ?*Node, right: ?*Node) !?*Node {
        if (left == null) return right;
        if (right == null) return left;
        return try self.prependNode(left.?, right.?);
    }

    fn appendNode(self: *Rope, left: *Node, right: *Node) error{OutOfMemory}!*Node {
        switch (left.*) {
            .leaf => return try self.concat(left, right),
            .branch => |*branch| {
                branch.right = try self.appendNode(branch.right, right);
                refreshBranch(branch);
                if (nodeHeight(branch.right) <= nodeHeight(branch.left) + 1) return left;
                return try self.concat(branch.left, branch.right);
            },
        }
    }

    fn prependNode(self: *Rope, left: *Node, right: *Node) error{OutOfMemory}!*Node {
        switch (right.*) {
            .leaf => return try self.concat(left, right),
            .branch => |*branch| {
                branch.left = try self.prependNode(left, branch.left);
                refreshBranch(branch);
                if (nodeHeight(branch.left) <= nodeHeight(branch.right) + 1) return right;
                return try self.concat(branch.left, branch.right);
            },
        }
    }

    fn concat(self: *Rope, left: *Node, right: *Node) error{OutOfMemory}!*Node {
        if (try self.concatLeaves(left, right)) |leaf| return leaf;

        const balance_factor = @as(isize, nodeHeight(left)) - @as(isize, nodeHeight(right));

        if (balance_factor > 1) {
            const branch = left.branch;
            if (nodeHeight(branch.left) >= nodeHeight(branch.right)) {
                return try self.rotateRight(branch.left, try self.concat(branch.right, right));
            }
            const lifted = branch.right.branch;
            const new_left = try self.concat(branch.left, lifted.left);
            const new_right = try self.concat(lifted.right, right);
            return try self.createBranch(new_left, new_right);
        }

        if (balance_factor < -1) {
            const branch = right.branch;
            if (nodeHeight(branch.right) >= nodeHeight(branch.left)) {
                return try self.rotateLeft(try self.concat(left, branch.left), branch.right);
            }
            const lifted = branch.left.branch;
            const new_left = try self.concat(left, lifted.left);
            const new_right = try self.concat(lifted.right, branch.right);
            return try self.createBranch(new_left, new_right);
        }

        return try self.createBranch(left, right);
    }

    fn concatLeaves(self: *Rope, left: *Node, right: *Node) !?*Node {
        switch (left.*) {
            .leaf => |left_leaf| switch (right.*) {
                .leaf => |right_leaf| {
                    const total_len = @as(usize, left_leaf.len) + right_leaf.len;
                    if (total_len > leaf_capacity) return null;

                    var text: [leaf_capacity]u8 = undefined;
                    @memcpy(text[0..left_leaf.len], left_leaf.data.text[0..left_leaf.len]);
                    @memcpy(text[left_leaf.len..total_len], right_leaf.data.text[0..right_leaf.len]);
                    return try self.createLeafWithLineCount(text[0..total_len], @as(usize, left_leaf.line_count) + right_leaf.line_count);
                },
                .branch => return null,
            },
            .branch => return null,
        }
    }

    fn rotateLeft(self: *Rope, left: *Node, right: *Node) !*Node {
        const branch = right.branch;
        return try self.createBranch(try self.createBranch(left, branch.left), branch.right);
    }

    fn rotateRight(self: *Rope, left: *Node, right: *Node) !*Node {
        const branch = left.branch;
        return try self.createBranch(branch.left, try self.createBranch(branch.right, right));
    }

    fn split(self: *Rope, node: ?*Node, offset: usize) error{OutOfMemory}!Split {
        const current = node orelse return .{ .left = null, .right = null };
        if (offset == 0) return .{ .left = null, .right = current };
        if (offset == nodeByteLen(current)) return .{ .left = current, .right = null };

        switch (current.*) {
            .leaf => |leaf| {
                std.debug.assert(offset <= leaf.len);
                return .{
                    .left = try self.createLeaf(leaf.data.text[0..offset]),
                    .right = try self.createLeaf(leaf.data.text[offset..leaf.len]),
                };
            },
            .branch => |branch| {
                if (offset == branch.weight) return .{ .left = branch.left, .right = branch.right };

                if (offset < branch.weight) {
                    const left_split = try self.split(branch.left, offset);
                    return .{
                        .left = left_split.left,
                        .right = try self.concatOpt(left_split.right, branch.right),
                    };
                }

                const right_split = try self.split(branch.right, offset - branch.weight);
                return .{
                    .left = try self.concatOpt(branch.left, right_split.left),
                    .right = right_split.right,
                };
            },
        }
    }
};

fn nodeByteLen(node: ?*const Rope.Node) usize {
    const current = node orelse return 0;
    return switch (current.*) {
        .leaf => |leaf| leaf.len,
        .branch => |branch| branch.byte_len,
    };
}

fn nodeLineCount(node: ?*const Rope.Node) usize {
    const current = node orelse return 0;
    return switch (current.*) {
        .leaf => |leaf| leaf.line_count,
        .branch => |branch| branch.total_line_count,
    };
}

fn refreshBranch(branch: *Rope.Branch) void {
    branch.weight = nodeByteLen(branch.left);
    branch.line_count = nodeLineCount(branch.left);
    branch.byte_len = branch.weight + nodeByteLen(branch.right);
    branch.total_line_count = branch.line_count + nodeLineCount(branch.right);
    branch.height = @intCast(@max(nodeHeight(branch.left), nodeHeight(branch.right)) + 1);
}

fn countNewlines(text: []const u8) usize {
    var count: usize = 0;
    for (text) |byte| {
        if (byte == '\n') count += 1;
    }
    return count;
}

fn rebuildNewlineBits(leaf: *Rope.Leaf) usize {
    var count: usize = 0;
    leaf.data.newline_bits = .{0} ** Rope.newline_word_count;
    for (leaf.data.text[0..leaf.len], 0..) |byte, index| {
        if (byte == '\n') {
            leaf.data.newline_bits[index / 64] |= @as(u64, 1) << @intCast(index % 64);
            count += 1;
        }
    }
    return count;
}

fn appendNewlineBits(leaf: *Rope.Leaf, old_len: usize, text: []const u8) void {
    for (text, 0..) |byte, index| {
        if (byte == '\n') {
            const bit_index = old_len + index;
            leaf.data.newline_bits[bit_index / 64] |= @as(u64, 1) << @intCast(bit_index % 64);
        }
    }
}

fn nthNewlineInLeaf(leaf: Rope.Leaf, target: usize) ?usize {
    var remaining = target;
    for (leaf.data.newline_bits, 0..) |word, word_index| {
        var bits = word;
        while (bits != 0) {
            const bit = @ctz(bits);
            remaining -= 1;
            if (remaining == 0) return word_index * 64 + bit;
            bits &= bits - 1;
        }
    }
    return null;
}

fn tryInsertInPlace(node: ?*Rope.Node, offset: usize, text: []const u8, new_lines: usize) bool {
    const current = node orelse return false;
    switch (current.*) {
        .leaf => |*leaf| {
            if (@as(usize, leaf.len) + text.len > Rope.leaf_capacity) return false;
            if (offset > leaf.len) return false;

            insertIntoLeaf(leaf, offset, text, new_lines);
            return true;
        },
        .branch => |*branch| {
            if (offset <= branch.weight and tryInsertInPlace(branch.left, offset, text, new_lines)) {
                branch.weight += text.len;
                branch.line_count += new_lines;
                branch.byte_len += text.len;
                branch.total_line_count += new_lines;
                return true;
            }

            if (offset >= branch.weight and tryInsertInPlace(branch.right, offset - branch.weight, text, new_lines)) {
                branch.byte_len += text.len;
                branch.total_line_count += new_lines;
                return true;
            }

            return false;
        },
    }
}

fn insertIntoLeaf(leaf: *Rope.Leaf, offset: usize, text: []const u8, new_lines: usize) void {
    const old_len = leaf.len;
    const new_len = @as(usize, old_len) + text.len;
    std.mem.copyBackwards(u8, leaf.data.text[offset + text.len .. new_len], leaf.data.text[offset..old_len]);
    @memcpy(leaf.data.text[offset..][0..text.len], text);
    leaf.len = @intCast(new_len);
    leaf.line_count += @intCast(new_lines);
    if (offset == old_len) {
        appendNewlineBits(leaf, old_len, text);
    } else {
        _ = rebuildNewlineBits(leaf);
    }
}

fn updateCursorPathAfterInsert(cursor: *Rope.Cursor, byte_delta: usize, line_delta: usize) void {
    for (cursor.path[0..cursor.path_len]) |entry| {
        switch (entry.node.*) {
            .leaf => unreachable,
            .branch => |*branch| {
                if (entry.went_left) {
                    branch.weight += byte_delta;
                    branch.line_count += line_delta;
                }
                branch.byte_len += byte_delta;
                branch.total_line_count += line_delta;
            },
        }
    }
}

fn tryDeleteInPlace(node: ?*Rope.Node, offset: usize, len: usize) ?usize {
    const current = node orelse return null;
    switch (current.*) {
        .leaf => |*leaf| {
            if (offset + len > leaf.len) return null;

            const old_len = leaf.len;
            const deleted_lines = countNewlines(leaf.data.text[offset..][0..len]);
            std.mem.copyForwards(u8, leaf.data.text[offset .. old_len - len], leaf.data.text[offset + len .. old_len]);
            leaf.len = @intCast(old_len - len);
            leaf.line_count -= @intCast(deleted_lines);
            _ = rebuildNewlineBits(leaf);
            return deleted_lines;
        },
        .branch => |*branch| {
            if (offset + len <= branch.weight) {
                const deleted_lines = tryDeleteInPlace(branch.left, offset, len) orelse return null;
                branch.weight -= len;
                branch.line_count -= deleted_lines;
                branch.byte_len -= len;
                branch.total_line_count -= deleted_lines;
                return deleted_lines;
            }

            if (offset >= branch.weight) {
                const right_offset = offset - branch.weight;
                const deleted_lines = tryDeleteInPlace(branch.right, right_offset, len) orelse return null;
                branch.byte_len -= len;
                branch.total_line_count -= deleted_lines;
                return deleted_lines;
            }

            return null;
        },
    }
}

fn pruneEmpty(node: ?*Rope.Node) ?*Rope.Node {
    const current = node orelse return null;
    switch (current.*) {
        .leaf => |leaf| return if (leaf.len == 0) null else current,
        .branch => |*branch| {
            const left = pruneEmpty(branch.left);
            const right = pruneEmpty(branch.right);

            if (left == null) return right;
            if (right == null) return left;

            branch.left = left.?;
            branch.right = right.?;
            branch.weight = nodeByteLen(branch.left);
            branch.line_count = nodeLineCount(branch.left);
            branch.byte_len = branch.weight + nodeByteLen(branch.right);
            branch.total_line_count = branch.line_count + nodeLineCount(branch.right);
            branch.height = @intCast(@max(nodeHeight(branch.left), nodeHeight(branch.right)) + 1);
            return current;
        },
    }
}

fn nodeHeight(node: *const Rope.Node) u8 {
    return switch (node.*) {
        .leaf => 1,
        .branch => |branch| branch.height,
    };
}

fn nodeHeightOpt(node: ?*const Rope.Node) usize {
    const current = node orelse return 0;
    return nodeHeight(current);
}

const NodeCounts = struct {
    nodes: usize = 0,
    branches: usize = 0,
    leaves: usize = 0,
};

fn countNodes(node: ?*const Rope.Node) NodeCounts {
    const current = node orelse return .{};
    return switch (current.*) {
        .leaf => .{ .nodes = 1, .leaves = 1 },
        .branch => |branch| blk: {
            const left = countNodes(branch.left);
            const right = countNodes(branch.right);
            break :blk .{
                .nodes = 1 + left.nodes + right.nodes,
                .branches = 1 + left.branches + right.branches,
                .leaves = left.leaves + right.leaves,
            };
        },
    };
}

fn nodeByteAt(node: *const Rope.Node, offset: usize) u8 {
    var current = node;
    var remaining = offset;

    while (true) switch (current.*) {
        .leaf => |leaf| return leaf.data.text[remaining],
        .branch => |branch| {
            if (remaining < branch.weight) {
                current = branch.left;
            } else {
                remaining -= branch.weight;
                current = branch.right;
            }
        },
    };
}

fn nthNewlineEnd(node: ?*const Rope.Node, target_line: usize) ?usize {
    var current = node orelse return null;
    var remaining = target_line;
    var offset: usize = 0;

    while (true) switch (current.*) {
        .leaf => |leaf| {
            const index = nthNewlineInLeaf(leaf, remaining) orelse return null;
            return offset + index + 1;
        },
        .branch => |branch| {
            if (remaining <= branch.line_count) {
                current = branch.left;
            } else {
                remaining -= branch.line_count;
                offset += branch.weight;
                current = branch.right;
            }
        },
    };
}

fn copyNode(node: ?*const Rope.Node, out: []u8, index: *usize) void {
    const current = node orelse return;
    switch (current.*) {
        .leaf => |leaf| {
            @memcpy(out[index.*..][0..leaf.len], leaf.data.text[0..leaf.len]);
            index.* += leaf.len;
        },
        .branch => |branch| {
            copyNode(branch.left, out, index);
            copyNode(branch.right, out, index);
        },
    }
}

test "builds balanced leaves from text" {
    var rope = Rope.init(std.testing.allocator);
    defer rope.deinit();

    try rope.setText("hello\nworld");

    try std.testing.expectEqual(@as(usize, 11), rope.byteLen());
    try std.testing.expectEqual(@as(usize, 1), rope.lineCount());
    try std.testing.expectEqual(@as(u8, 'w'), rope.byteAt(6));
}

test "empty rope supports no-op edits and flattening" {
    var rope = Rope.init(std.testing.allocator);
    defer rope.deinit();

    try rope.setText("");
    try rope.insert(0, "");
    try rope.delete(0, 0);

    const out = try rope.toOwnedSlice(std.testing.allocator);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("", out);
    try std.testing.expectEqual(@as(usize, 0), rope.byteLen());
    try std.testing.expectEqual(@as(usize, 0), rope.lineCount());
    try std.testing.expectEqual(@as(usize, 0), rope.stats().height);
}

test "setText replaces previous slabs" {
    var rope = Rope.init(std.testing.allocator);
    defer rope.deinit();

    var base: [Rope.leaf_capacity * 8]u8 = undefined;
    @memset(&base, 'x');
    try rope.setText(&base);
    try std.testing.expect(rope.stats().allocated_nodes > 1);

    try rope.setText("tiny");
    const stats = rope.stats();
    try std.testing.expectEqual(@as(usize, 4), stats.byte_len);
    try std.testing.expectEqual(@as(usize, 1), stats.node_count);
    try std.testing.expectEqual(@as(usize, 1), stats.allocated_nodes);
}

test "inserts at start middle and end" {
    var rope = Rope.init(std.testing.allocator);
    defer rope.deinit();

    try rope.setText("cd");
    try rope.insert(0, "ab");
    try rope.insert(4, "gh");
    try rope.insert(4, "ef");

    const out = try rope.toOwnedSlice(std.testing.allocator);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("abcdefgh", out);
}

test "boundary edits reuse existing nodes" {
    var rope = Rope.init(std.testing.allocator);
    defer rope.deinit();

    try rope.setText("abc");
    const before = rope.stats().allocated_nodes;

    try rope.insert(0, "");
    try rope.insert(rope.byteLen(), "");
    try rope.delete(0, 0);
    try rope.delete(rope.byteLen(), 0);

    try std.testing.expectEqual(before, rope.stats().allocated_nodes);
}

test "small insert keeps compact leaf" {
    var rope = Rope.init(std.testing.allocator);
    defer rope.deinit();

    try rope.setText("ac");
    const before = rope.stats().allocated_nodes;
    try rope.insert(1, "b");

    const stats = rope.stats();
    try std.testing.expectEqual(before, stats.allocated_nodes);
    try std.testing.expectEqual(@as(usize, 1), stats.leaf_count);
    try std.testing.expectEqual(@as(usize, 0), stats.branch_count);

    const out = try rope.toOwnedSlice(std.testing.allocator);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("abc", out);
}

test "small leaf edits update metrics in place" {
    var rope = Rope.init(std.testing.allocator);
    defer rope.deinit();

    try rope.setText("abef");
    const before = rope.stats().allocated_nodes;

    try rope.insert(2, "c\nd");
    try std.testing.expectEqual(@as(usize, 1), rope.lineCount());
    try std.testing.expectEqual(@as(usize, 3), rope.byteOffsetForLine(1));

    try rope.delete(2, 2);
    try std.testing.expectEqual(@as(usize, 0), rope.lineCount());
    try std.testing.expectEqual(before, rope.stats().allocated_nodes);

    const out = try rope.toOwnedSlice(std.testing.allocator);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("abdef", out);
}

test "inserts across leaf boundaries" {
    var rope = Rope.init(std.testing.allocator);
    defer rope.deinit();

    var base: [Rope.leaf_capacity * 2]u8 = undefined;
    @memset(&base, 'a');
    try rope.setText(&base);
    try rope.insert(Rope.leaf_capacity - 1, "XYZ");

    const out = try rope.toOwnedSlice(std.testing.allocator);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqual(@as(usize, Rope.leaf_capacity * 2 + 3), out.len);
    try std.testing.expectEqualStrings("aXYZa", out[Rope.leaf_capacity - 1 .. Rope.leaf_capacity + 4]);
}

test "inserts and deletes without flattening" {
    var rope = Rope.init(std.testing.allocator);
    defer rope.deinit();

    try rope.setText("hello world");
    try rope.insert(5, ", fast");
    try rope.delete(11, 6);

    const out = try rope.toOwnedSlice(std.testing.allocator);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("hello, fast", out);
}

test "deletes from start middle end and whole rope" {
    var rope = Rope.init(std.testing.allocator);
    defer rope.deinit();

    try rope.setText("0123456789");
    try rope.delete(0, 2);
    try rope.delete(3, 2);
    try rope.delete(4, 2);

    var out = try rope.toOwnedSlice(std.testing.allocator);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("23478", out);

    try rope.delete(0, rope.byteLen());
    out = try rope.toOwnedSlice(std.testing.allocator);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("", out);
    try std.testing.expectEqual(@as(usize, 0), rope.stats().node_count);
}

test "full delete clears root" {
    var rope = Rope.init(std.testing.allocator);
    defer rope.deinit();

    var base: [Rope.leaf_capacity * 2]u8 = undefined;
    @memset(&base, 'x');
    try rope.setText(&base);
    try rope.delete(0, base.len);

    const stats = rope.stats();
    try std.testing.expectEqual(@as(usize, 0), stats.byte_len);
    try std.testing.expectEqual(@as(usize, 0), stats.leaf_count);
    try std.testing.expectEqual(@as(usize, 0), stats.branch_count);
}

test "line offsets clamp to valid ranges" {
    var rope = Rope.init(std.testing.allocator);
    defer rope.deinit();

    try rope.setText("one\ntwo\nthree\n");

    try std.testing.expectEqual(@as(usize, 0), rope.byteOffsetForLine(0));
    try std.testing.expectEqual(@as(usize, 4), rope.byteOffsetForLine(1));
    try std.testing.expectEqual(@as(usize, 8), rope.byteOffsetForLine(2));
    try std.testing.expectEqual(@as(usize, 14), rope.byteOffsetForLine(3));
    try std.testing.expectEqual(@as(usize, 14), rope.byteOffsetForLine(99));
    try std.testing.expectEqual(@as(usize, 7), rope.byteOffsetForLineColumn(1, 99));
}

test "maps line and column to byte offsets" {
    var rope = Rope.init(std.testing.allocator);
    defer rope.deinit();

    try rope.setText("alpha\nbeta\ngamma");

    try std.testing.expectEqual(@as(usize, 0), rope.byteOffsetForLineColumn(0, 0));
    try std.testing.expectEqual(@as(usize, 6), rope.byteOffsetForLineColumn(1, 0));
    try std.testing.expectEqual(@as(usize, 9), rope.byteOffsetForLineColumn(1, 3));
    try std.testing.expectEqual(@as(usize, 11), rope.byteOffsetForLineColumn(1, 99));
}

test "byteAt reads every byte across many leaves" {
    var rope = Rope.init(std.testing.allocator);
    defer rope.deinit();

    var base: [Rope.leaf_capacity * 4 + 7]u8 = undefined;
    for (&base, 0..) |*byte, index| byte.* = @intCast('a' + index % 26);
    try rope.setText(&base);

    for (&base, 0..) |expected, index| {
        try std.testing.expectEqual(expected, rope.byteAt(index));
    }
}

test "repeated appends remain height balanced" {
    var rope = Rope.init(std.testing.allocator);
    defer rope.deinit();

    try rope.setText("");
    for (0..512) |index| {
        try rope.insert(rope.byteLen(), if (index % 8 == 0) "x\n" else "x");
    }

    const stats = rope.stats();
    try std.testing.expectEqual(@as(usize, 576), stats.byte_len);
    try std.testing.expectEqual(@as(usize, 64), stats.line_count);
    try std.testing.expect(stats.height < 32);
    try std.testing.expectEqual(stats.branch_count + stats.leaf_count, stats.node_count);
}

test "compact rebuilds live text into fresh slabs" {
    var rope = Rope.init(std.testing.allocator);
    defer rope.deinit();

    try rope.setText("hello world");
    for (0..100) |_| {
        try rope.insert(5, "x");
        try rope.delete(5, 1);
    }

    const before = rope.stats();
    try rope.compact();
    const after = rope.stats();

    try std.testing.expect(after.allocated_nodes < before.allocated_nodes);
    const out = try rope.toOwnedSlice(std.testing.allocator);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("hello world", out);
}

test "cursor inserts locally and updates metrics" {
    var rope = Rope.init(std.testing.allocator);
    defer rope.deinit();

    try rope.setText("");
    var cursor: Rope.Cursor = .{};
    rope.seekCursor(&cursor, 0);

    const before = rope.stats().allocated_nodes;
    try rope.insertAtCursor(&cursor, "a");
    try rope.insertAtCursor(&cursor, "\n");
    try rope.insertAtCursor(&cursor, "b");

    const out = try rope.toOwnedSlice(std.testing.allocator);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("a\nb", out);
    try std.testing.expectEqual(@as(usize, 1), rope.lineCount());
    try std.testing.expectEqual(@as(usize, 3), cursor.offset);
    try std.testing.expect(rope.stats().allocated_nodes <= before + 3);
}

test "mixed edits match array list model" {
    var rope = Rope.init(std.testing.allocator);
    defer rope.deinit();

    var model: std.ArrayList(u8) = .empty;
    defer model.deinit(std.testing.allocator);

    try rope.setText("seed");
    try model.appendSlice(std.testing.allocator, "seed");

    const inserts = [_][]const u8{ "alpha", "\n", "beta", "-", "gamma", "\nend" };
    for (inserts, 0..) |text, index| {
        const offset = (index * 7) % (model.items.len + 1);
        try rope.insert(offset, text);
        try model.insertSlice(std.testing.allocator, offset, text);
    }

    const deletes = [_]struct { offset: usize, len: usize }{
        .{ .offset = 0, .len = 2 },
        .{ .offset = 3, .len = 4 },
        .{ .offset = 8, .len = 1 },
    };
    for (deletes) |delete_op| {
        try rope.delete(delete_op.offset, delete_op.len);
        model.replaceRangeAssumeCapacity(delete_op.offset, delete_op.len, "");
    }

    const out = try rope.toOwnedSlice(std.testing.allocator);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings(model.items, out);
}
