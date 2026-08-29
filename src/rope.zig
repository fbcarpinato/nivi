const std = @import("std");

pub const Rope = struct {
    pub const leaf_capacity = 160;
    pub const max_cursor_depth = 64;
    /// Stack window (bytes) for local grapheme-boundary scanning; larger than any
    /// realistic single cluster, with an exact fallback for the rare overflow.
    const grapheme_window = 128;
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

    pub const ByteRange = struct {
        start: usize,
        end: usize,
    };

    pub const Codepoint = struct {
        offset: usize,
        len: u3,
        value: u21,
    };

    pub const Grapheme = struct {
        start: usize,
        end: usize,
        width: u8,
    };

    pub const Utf8Error = error{
        InvalidStartByte,
        TruncatedInput,
        InvalidCodepoint,
    };

    pub const BoundaryMode = enum {
        assert_boundary,
        clamp_backward,
        clamp_forward,
    };

    pub const UnicodeSupport = struct {
        utf8_validation: bool = true,
        utf8_boundaries: bool = true,
        codepoint_iteration: bool = true,
        grapheme_heuristics: bool = true,
        full_uax_graphemes: bool = false,
        display_width_heuristics: bool = true,
        full_east_asian_width: bool = false,
        normalization: NormalizationSupport = .ascii_fast_path_only,
    };

    pub const NormalizationSupport = enum {
        ascii_fast_path_only,
        full_nfc,
    };

    pub const NormalizationStatus = enum {
        normalized,
        not_normalized,
        unknown_without_tables,
    };

    pub const unicode_support: UnicodeSupport = .{};

    pub const CodepointIterator = struct {
        rope: *const Rope,
        offset: usize,
        end: usize,

        pub fn next(self: *CodepointIterator) Utf8Error!?Codepoint {
            if (self.offset >= self.end) return null;
            const codepoint = try self.rope.codepointAt(self.offset);
            if (self.offset + codepoint.len > self.end) return error.TruncatedInput;
            self.offset += codepoint.len;
            return codepoint;
        }
    };

    pub const GraphemeIterator = struct {
        codepoints: CodepointIterator,
        pending: ?Codepoint = null,

        pub fn next(self: *GraphemeIterator) Utf8Error!?Grapheme {
            const first = if (self.pending) |cp| blk: {
                self.pending = null;
                break :blk cp;
            } else (try self.codepoints.next()) orelse return null;

            var grapheme: Grapheme = .{
                .start = first.offset,
                .end = first.offset + first.len,
                .width = codepointDisplayWidth(first.value),
            };
            var previous = first.value;
            var regional_count: usize = if (isRegionalIndicator(first.value)) 1 else 0;

            while (try self.codepoints.next()) |next_cp| {
                if (!continuesGrapheme(previous, next_cp.value, regional_count)) {
                    self.pending = next_cp;
                    break;
                }

                grapheme.end = next_cp.offset + next_cp.len;
                if (next_cp.value == 0x200d) {
                    grapheme.width = @max(grapheme.width, 2);
                } else if (!isZeroWidthCodepoint(next_cp.value)) {
                    grapheme.width = @max(grapheme.width, codepointDisplayWidth(next_cp.value));
                }

                if (isRegionalIndicator(next_cp.value)) regional_count += 1;
                previous = next_cp.value;
            }

            return grapheme;
        }
    };

    pub const ValidationError = error{
        WrongByteLen,
        WrongLineCount,
        WrongHeight,
        WrongNewlineBits,
        WrongLeafCount,
    };

    const Validation = struct {
        byte_len: usize,
        line_count: usize,
        height: u8,
        leaf_count: usize,
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

    /// Returns the 0-based line index containing `offset`.
    pub fn lineAt(self: Rope, offset: usize) usize {
        std.debug.assert(offset <= self.byteLen());
        var current = self.root orelse return 0;
        var remaining = offset;
        var line: usize = 0;

        while (true) switch (current.*) {
            .leaf => |leaf| return line + newlinesBeforeInLeaf(leaf, remaining),
            .branch => |branch| {
                if (remaining < branch.weight) {
                    current = branch.left;
                } else {
                    line += branch.line_count;
                    remaining -= branch.weight;
                    current = branch.right;
                }
            },
        };
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

    pub fn insertUtf8(self: *Rope, offset: usize, text: []const u8, mode: BoundaryMode) !usize {
        if (!std.unicode.utf8ValidateSlice(text)) return error.InvalidCodepoint;
        const safe_offset = try self.resolveUtf8Boundary(offset, mode);
        try self.insert(safe_offset, text);
        return safe_offset;
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

    /// Delete `len` bytes starting at the cursor (forward / Del). Stays on the
    /// in-leaf fast path when the whole range lives in the cached leaf.
    pub fn deleteAtCursor(self: *Rope, cursor: *Cursor, len: usize) !void {
        if (len == 0) return;
        if (cursor.leaf) |leaf_node| switch (leaf_node.*) {
            .leaf => |*leaf| {
                const leaf_offset = cursor.offset - cursor.leaf_start;
                if (leaf_offset + len <= leaf.len and !(leaf_offset == 0 and len == leaf.len)) {
                    const deleted_lines = deleteFromLeaf(leaf, leaf_offset, len);
                    updateCursorPathAfterDelete(cursor, len, deleted_lines);
                    return;
                }
            },
            .branch => {},
        };

        const at = cursor.offset;
        try self.delete(at, len);
        self.seekCursor(cursor, at);
    }

    /// Delete `len` bytes ending at the cursor (backward / Backspace). Caller
    /// must ensure `len <= cursor.offset`.
    pub fn deleteBeforeCursor(self: *Rope, cursor: *Cursor, len: usize) !void {
        if (len == 0) return;
        const new_offset = cursor.offset - len;
        if (cursor.leaf) |leaf_node| switch (leaf_node.*) {
            .leaf => |*leaf| {
                if (new_offset >= cursor.leaf_start) {
                    const leaf_offset = new_offset - cursor.leaf_start;
                    if (leaf_offset + len <= leaf.len and !(leaf_offset == 0 and len == leaf.len)) {
                        const deleted_lines = deleteFromLeaf(leaf, leaf_offset, len);
                        updateCursorPathAfterDelete(cursor, len, deleted_lines);
                        cursor.offset = new_offset;
                        return;
                    }
                }
            },
            .branch => {},
        };

        try self.delete(new_offset, len);
        self.seekCursor(cursor, new_offset);
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

    pub fn deleteUtf8(self: *Rope, offset: usize, len: usize, mode: BoundaryMode) !ByteRange {
        const start = try self.resolveUtf8Boundary(offset, mode);
        const requested_end = @min(offset + len, self.byteLen());
        const end = try self.resolveUtf8Boundary(requested_end, mode);
        if (end > start) try self.delete(start, end - start);
        return .{ .start = start, .end = end };
    }

    pub fn byteAt(self: Rope, offset: usize) u8 {
        std.debug.assert(offset < self.byteLen());
        return nodeByteAt(self.root.?, offset);
    }

    pub fn isUtf8Boundary(self: Rope, offset: usize) bool {
        std.debug.assert(offset <= self.byteLen());
        return offset == 0 or offset == self.byteLen() or !isUtf8Continuation(self.byteAt(offset));
    }

    pub fn prevUtf8Boundary(self: Rope, offset: usize) usize {
        std.debug.assert(offset <= self.byteLen());
        var current = offset;
        while (current > 0 and !self.isUtf8Boundary(current)) current -= 1;
        return current;
    }

    pub fn nextUtf8Boundary(self: Rope, offset: usize) usize {
        std.debug.assert(offset <= self.byteLen());
        var current = offset;
        while (current < self.byteLen() and !self.isUtf8Boundary(current)) current += 1;
        return current;
    }

    pub fn resolveUtf8Boundary(self: Rope, offset: usize, mode: BoundaryMode) Utf8Error!usize {
        std.debug.assert(offset <= self.byteLen());
        if (self.isUtf8Boundary(offset)) return offset;
        return switch (mode) {
            .assert_boundary => error.InvalidCodepoint,
            .clamp_backward => self.prevUtf8Boundary(offset),
            .clamp_forward => self.nextUtf8Boundary(offset),
        };
    }

    /// Returns the byte offset of the grapheme-cluster boundary at or after `offset`.
    /// `offset` must already be a grapheme boundary (cursor invariant).
    pub fn nextGraphemeBoundary(self: *const Rope, offset: usize) Utf8Error!usize {
        std.debug.assert(offset <= self.byteLen());
        if (offset >= self.byteLen()) return self.byteLen();

        // Fast path: an ASCII byte followed by ASCII (or EOF) is a lone cluster.
        const first = self.byteAt(offset);
        if (first < 0x80) {
            if (offset + 1 >= self.byteLen()) return self.byteLen();
            if (self.byteAt(offset + 1) < 0x80) return offset + 1;
        }

        const window_len = @min(grapheme_window, self.byteLen() - offset);
        var window: [grapheme_window]u8 = undefined;
        self.copyRange(window[0..window_len], offset);

        const end = try firstGraphemeEndInSlice(window[0..window_len]);
        // Rare: a cluster longer than the window; fall back to the exact iterator.
        if (end == window_len and window_len < self.byteLen() - offset) {
            var iter = self.graphemes(.{ .start = offset, .end = self.byteLen() });
            const grapheme = (try iter.next()) orelse return self.byteLen();
            return grapheme.end;
        }
        return offset + end;
    }

    /// Returns the byte offset of the grapheme-cluster boundary before `offset`.
    pub fn prevGraphemeBoundary(self: *const Rope, offset: usize) Utf8Error!usize {
        std.debug.assert(offset <= self.byteLen());
        if (offset == 0) return 0;

        // Fast path: an ASCII codepoint before `offset` is always its own cluster
        // start (ASCII is never an extender/ZWJ-joined/regional continuation).
        const prev_start = self.prevUtf8Boundary(offset - 1);
        if (self.byteAt(prev_start) < 0x80) return prev_start;

        const raw_start = offset - @min(grapheme_window, offset);
        const window_start = if (raw_start == 0) 0 else self.nextUtf8Boundary(raw_start);
        const window_len = offset - window_start;

        var window: [grapheme_window]u8 = undefined;
        self.copyRange(window[0..window_len], window_start);

        const start = try lastGraphemeStartInSlice(window[0..window_len]);
        // Rare: cluster spans past the window start; fall back to the exact scan.
        if (start == 0 and window_start != 0) {
            var iter = self.graphemes(.{ .start = window_start, .end = offset });
            var last = window_start;
            while (try iter.next()) |grapheme| last = grapheme.start;
            return last;
        }
        return window_start + start;
    }

    pub fn codepointAt(self: Rope, offset: usize) Utf8Error!Codepoint {
        std.debug.assert(offset < self.byteLen());
        const first = self.byteAt(offset);
        const len = std.unicode.utf8ByteSequenceLength(first) catch return error.InvalidStartByte;
        if (offset + len > self.byteLen()) return error.TruncatedInput;

        var bytes: [4]u8 = undefined;
        for (0..len) |index| bytes[index] = self.byteAt(offset + index);
        const value = std.unicode.utf8Decode(bytes[0..len]) catch return error.InvalidCodepoint;
        return .{ .offset = offset, .len = len, .value = value };
    }

    pub fn codepoints(self: *const Rope, range: ByteRange) CodepointIterator {
        std.debug.assert(range.start <= range.end);
        std.debug.assert(range.end <= self.byteLen());
        return .{ .rope = self, .offset = range.start, .end = range.end };
    }

    pub fn validateUtf8(self: Rope) bool {
        var validator: Utf8Stream = .{};
        validateUtf8Node(self.root, &validator) catch return false;
        return validator.finish();
    }

    pub fn countCodepointsUtf8(self: *const Rope, range: ByteRange) Utf8Error!usize {
        if (range.start == 0 and range.end == self.byteLen()) {
            var validator: Utf8Stream = .{};
            try validateUtf8Node(self.root, &validator);
            if (!validator.finish()) return error.TruncatedInput;
            return validator.codepoint_count;
        }

        var iter = self.codepoints(range);
        var count: usize = 0;
        while (try iter.next() != null) count += 1;
        return count;
    }

    pub fn graphemes(self: *const Rope, range: ByteRange) GraphemeIterator {
        return .{ .codepoints = self.codepoints(range) };
    }

    pub fn displayWidth(self: *const Rope, range: ByteRange, tab_width: usize) Utf8Error!usize {
        if (range.start == 0 and range.end == self.byteLen()) return try self.displayWidthFull(tab_width);

        var iter = self.graphemes(range);
        var width: usize = 0;
        while (try iter.next()) |grapheme| {
            if (grapheme.width == tabSentinelWidth) {
                width += tab_width - (width % tab_width);
            } else {
                width += grapheme.width;
            }
        }
        return width;
    }

    pub fn countGraphemes(self: *const Rope, range: ByteRange) Utf8Error!usize {
        if (range.start == 0 and range.end == self.byteLen()) {
            var stream: GraphemeStream = .{};
            try graphemeStreamNode(self.root, &stream, 4, false);
            try stream.finish(false);
            return stream.grapheme_count;
        }

        var iter = self.graphemes(range);
        var count: usize = 0;
        while (try iter.next() != null) count += 1;
        return count;
    }

    fn displayWidthFull(self: *const Rope, tab_width: usize) Utf8Error!usize {
        var stream: GraphemeStream = .{};
        try graphemeStreamNode(self.root, &stream, tab_width, true);
        try stream.finish(true);
        return stream.width;
    }

    pub fn byteOffsetForLineVisualColumn(self: *const Rope, line: usize, visual_column: usize, tab_width: usize) Utf8Error!usize {
        const line_range = self.byteRangeForLines(line, 1);
        if (line_range.end - line_range.start <= 1024) {
            var scratch: [1024]u8 = undefined;
            const line_len = line_range.end - line_range.start;
            self.copyRange(scratch[0..line_len], line_range.start);
            return line_range.start + try visualColumnInSlice(scratch[0..line_len], visual_column, tab_width);
        }

        var iter = self.graphemes(line_range);
        var width: usize = 0;

        while (try iter.next()) |grapheme| {
            if (grapheme.end > line_range.start and self.byteAt(grapheme.end - 1) == '\n') return grapheme.start;
            const grapheme_width = if (grapheme.width == tabSentinelWidth) tab_width - (width % tab_width) else grapheme.width;
            if (width + grapheme_width > visual_column) return grapheme.start;
            width += grapheme_width;
        }

        return line_range.end;
    }

    pub fn nfcStatus(self: *const Rope, range: ByteRange) Utf8Error!NormalizationStatus {
        var iter = self.codepoints(range);
        while (try iter.next()) |cp| {
            if (cp.value >= 0x80) return .unknown_without_tables;
        }
        return .normalized;
    }

    pub fn isNormalizedNfc(self: *const Rope, range: ByteRange) Utf8Error!bool {
        return try self.nfcStatus(range) == .normalized;
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

    pub fn byteRangeForLines(self: Rope, first_line: usize, line_count: usize) ByteRange {
        const start = self.byteOffsetForLine(first_line);
        if (line_count == 0) return .{ .start = start, .end = start };
        return .{ .start = start, .end = self.byteOffsetForLine(first_line + line_count) };
    }

    pub fn copyRange(self: Rope, out: []u8, offset: usize) void {
        std.debug.assert(offset <= self.byteLen());
        std.debug.assert(out.len <= self.byteLen() - offset);
        var index: usize = 0;
        copyNodeRange(self.root, offset, out.len, out, &index);
    }

    pub fn validate(self: Rope) ValidationError!void {
        const validation = try validateNode(self.root);
        if (validation.byte_len != self.byteLen()) return error.WrongByteLen;
        if (validation.line_count != self.lineCount()) return error.WrongLineCount;
        if (validation.height != nodeHeightOptU8(self.root)) return error.WrongHeight;
    }

    pub fn toOwnedSlice(self: Rope, allocator: std.mem.Allocator) ![]u8 {
        const out = try allocator.alloc(u8, self.byteLen());
        self.copyRange(out, 0);
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

fn isUtf8Continuation(byte: u8) bool {
    return byte & 0b1100_0000 == 0b1000_0000;
}

const tabSentinelWidth: u8 = std.math.maxInt(u8);

fn continuesGrapheme(previous: u21, current: u21, regional_count: usize) bool {
    if (isCombiningMark(current)) return true;
    if (isVariationSelector(current)) return true;
    if (isEmojiModifier(current)) return true;
    if (previous == 0x200d) return true;
    if (current == 0x200d) return true;
    if (isRegionalIndicator(previous) and isRegionalIndicator(current) and regional_count % 2 == 1) return true;
    return false;
}

fn codepointDisplayWidth(cp: u21) u8 {
    if (cp == '\t') return tabSentinelWidth;
    if (cp == '\n' or cp == '\r') return 0;
    if (cp < 0x20 or (cp >= 0x7f and cp < 0xa0)) return 0;
    if (isZeroWidthCodepoint(cp)) return 0;
    if (isWideCodepoint(cp)) return 2;
    return 1;
}

fn isZeroWidthCodepoint(cp: u21) bool {
    return isCombiningMark(cp) or isVariationSelector(cp) or cp == 0x200d;
}

fn isCombiningMark(cp: u21) bool {
    return switch (cp) {
        0x0300...0x036f,
        0x0483...0x0489,
        0x0591...0x05bd,
        0x05bf,
        0x05c1...0x05c2,
        0x05c4...0x05c5,
        0x05c7,
        0x0610...0x061a,
        0x064b...0x065f,
        0x0670,
        0x06d6...0x06dc,
        0x06df...0x06e4,
        0x06e7...0x06e8,
        0x06ea...0x06ed,
        0x1ab0...0x1aff,
        0x1dc0...0x1dff,
        0x20d0...0x20ff,
        0xfe20...0xfe2f,
        => true,
        else => false,
    };
}

fn isVariationSelector(cp: u21) bool {
    return cp >= 0xfe00 and cp <= 0xfe0f or cp >= 0xe0100 and cp <= 0xe01ef;
}

fn isEmojiModifier(cp: u21) bool {
    return cp >= 0x1f3fb and cp <= 0x1f3ff;
}

fn isRegionalIndicator(cp: u21) bool {
    return cp >= 0x1f1e6 and cp <= 0x1f1ff;
}

fn isWideCodepoint(cp: u21) bool {
    return switch (cp) {
        0x1100...0x115f,
        0x2329...0x232a,
        0x2e80...0xa4cf,
        0xac00...0xd7a3,
        0xf900...0xfaff,
        0xfe10...0xfe19,
        0xfe30...0xfe6f,
        0xff00...0xff60,
        0xffe0...0xffe6,
        0x1f000...0x1faff,
        0x20000...0x3fffd,
        => true,
        else => false,
    };
}

const Utf8Stream = struct {
    bytes: [4]u8 = undefined,
    len: u3 = 0,
    expected: u3 = 0,
    codepoint_count: usize = 0,
    last_codepoint: u21 = 0,

    fn push(self: *Utf8Stream, byte: u8) Rope.Utf8Error!void {
        if (self.len == 0) {
            if (byte < 0x80) {
                self.codepoint_count += 1;
                self.last_codepoint = byte;
                return;
            }

            const expected = std.unicode.utf8ByteSequenceLength(byte) catch return error.InvalidStartByte;
            self.bytes[0] = byte;
            self.len = 1;
            self.expected = expected;
            return;
        }

        if (!isUtf8Continuation(byte)) return error.InvalidCodepoint;
        self.bytes[self.len] = byte;
        self.len += 1;

        if (self.len == self.expected) {
            self.last_codepoint = std.unicode.utf8Decode(self.bytes[0..self.expected]) catch return error.InvalidCodepoint;
            self.len = 0;
            self.expected = 0;
            self.codepoint_count += 1;
        }
    }

    fn finish(self: Utf8Stream) bool {
        return self.len == 0;
    }
};

fn validateUtf8Node(node: ?*const Rope.Node, validator: *Utf8Stream) Rope.Utf8Error!void {
    const current = node orelse return;
    switch (current.*) {
        .leaf => |leaf| {
            for (leaf.data.text[0..leaf.len]) |byte| try validator.push(byte);
        },
        .branch => |branch| {
            try validateUtf8Node(branch.left, validator);
            try validateUtf8Node(branch.right, validator);
        },
    }
}

const GraphemeStream = struct {
    utf8: Utf8Stream = .{},
    previous: ?u21 = null,
    regional_count: usize = 0,
    grapheme_count: usize = 0,
    width: usize = 0,
    current_width: usize = 0,

    fn push(self: *GraphemeStream, byte: u8, tab_width: usize, track_width: bool) Rope.Utf8Error!void {
        const before = self.utf8.codepoint_count;
        try self.utf8.push(byte);
        if (self.utf8.codepoint_count == before) return;

        const cp = self.utf8.last_codepoint;
        if (self.previous) |previous| {
            if (!continuesGrapheme(previous, cp, self.regional_count)) {
                self.commit(track_width);
                self.start(cp, tab_width);
            } else if (!isZeroWidthCodepoint(cp)) {
                self.current_width = @max(self.current_width, widthForColumn(cp, self.width + self.current_width, tab_width));
            }
        } else {
            self.start(cp, tab_width);
        }

        if (isRegionalIndicator(cp)) {
            self.regional_count += 1;
        } else if (cp != 0x200d) {
            self.regional_count = 0;
        }
        self.previous = cp;
    }

    fn start(self: *GraphemeStream, cp: u21, tab_width: usize) void {
        self.current_width = widthForColumn(cp, self.width, tab_width);
    }

    fn commit(self: *GraphemeStream, track_width: bool) void {
        self.grapheme_count += 1;
        if (track_width) self.width += self.current_width;
    }

    fn finish(self: *GraphemeStream, track_width: bool) Rope.Utf8Error!void {
        if (!self.utf8.finish()) return error.TruncatedInput;
        if (self.previous != null) {
            self.commit(track_width);
            self.previous = null;
        }
    }
};

fn widthForColumn(cp: u21, current_width: usize, tab_width: usize) usize {
    const width = codepointDisplayWidth(cp);
    if (width == tabSentinelWidth) return tab_width - (current_width % tab_width);
    return width;
}

fn firstGraphemeEndInSlice(bytes: []const u8) Rope.Utf8Error!usize {
    if (bytes.len == 0) return 0;
    var offset: usize = 0;
    var previous: ?u21 = null;
    var regional_count: usize = 0;
    var cluster_end: usize = 0;

    while (offset < bytes.len) {
        const cp_len = std.unicode.utf8ByteSequenceLength(bytes[offset]) catch return error.InvalidStartByte;
        if (offset + cp_len > bytes.len) break; // truncated at window edge
        const cp = std.unicode.utf8Decode(bytes[offset..][0..cp_len]) catch return error.InvalidCodepoint;
        if (previous) |prev| {
            if (!continuesGrapheme(prev, cp, regional_count)) break;
        }
        offset += cp_len;
        cluster_end = offset;
        if (isRegionalIndicator(cp)) {
            regional_count += 1;
        } else if (cp != 0x200d) {
            regional_count = 0;
        }
        previous = cp;
    }
    return cluster_end;
}

fn lastGraphemeStartInSlice(bytes: []const u8) Rope.Utf8Error!usize {
    var offset: usize = 0;
    var previous: ?u21 = null;
    var regional_count: usize = 0;
    var cluster_start: usize = 0;

    while (offset < bytes.len) {
        const cp_start = offset;
        const cp_len = std.unicode.utf8ByteSequenceLength(bytes[offset]) catch return error.InvalidStartByte;
        if (offset + cp_len > bytes.len) return error.TruncatedInput;
        const cp = std.unicode.utf8Decode(bytes[offset..][0..cp_len]) catch return error.InvalidCodepoint;
        if (previous) |prev| {
            if (!continuesGrapheme(prev, cp, regional_count)) cluster_start = cp_start;
        }
        offset += cp_len;
        if (isRegionalIndicator(cp)) {
            regional_count += 1;
        } else if (cp != 0x200d) {
            regional_count = 0;
        }
        previous = cp;
    }
    return cluster_start;
}

fn visualColumnInSlice(bytes: []const u8, visual_column: usize, tab_width: usize) Rope.Utf8Error!usize {
    var offset: usize = 0;
    var width: usize = 0;
    var cluster_start: usize = 0;
    var cluster_width: usize = 0;
    var previous: ?u21 = null;
    var regional_count: usize = 0;

    while (offset < bytes.len) {
        const cp_start = offset;
        const cp_len = std.unicode.utf8ByteSequenceLength(bytes[offset]) catch return error.InvalidStartByte;
        if (offset + cp_len > bytes.len) return error.TruncatedInput;
        const cp = std.unicode.utf8Decode(bytes[offset..][0..cp_len]) catch return error.InvalidCodepoint;
        offset += cp_len;

        if (cp == '\n') return cp_start;

        if (previous) |prev| {
            if (!continuesGrapheme(prev, cp, regional_count)) {
                if (width + cluster_width > visual_column) return cluster_start;
                width += cluster_width;
                cluster_start = cp_start;
                cluster_width = widthForColumn(cp, width, tab_width);
            } else if (!isZeroWidthCodepoint(cp)) {
                cluster_width = @max(cluster_width, widthForColumn(cp, width + cluster_width, tab_width));
            }
        } else {
            cluster_start = cp_start;
            cluster_width = widthForColumn(cp, width, tab_width);
        }

        if (isRegionalIndicator(cp)) {
            regional_count += 1;
        } else if (cp != 0x200d) {
            regional_count = 0;
        }
        previous = cp;
    }

    if (previous != null and width + cluster_width > visual_column) return cluster_start;
    return bytes.len;
}

fn graphemeStreamNode(node: ?*const Rope.Node, stream: *GraphemeStream, tab_width: usize, track_width: bool) Rope.Utf8Error!void {
    const current = node orelse return;
    switch (current.*) {
        .leaf => |leaf| {
            for (leaf.data.text[0..leaf.len]) |byte| try stream.push(byte, tab_width, track_width);
        },
        .branch => |branch| {
            try graphemeStreamNode(branch.left, stream, tab_width, track_width);
            try graphemeStreamNode(branch.right, stream, tab_width, track_width);
        },
    }
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

fn computeNewlineBits(text: []const u8) struct { bits: [Rope.newline_word_count]u64, count: usize } {
    var bits = [_]u64{0} ** Rope.newline_word_count;
    var count: usize = 0;
    for (text, 0..) |byte, index| {
        if (byte == '\n') {
            bits[index / 64] |= @as(u64, 1) << @intCast(index % 64);
            count += 1;
        }
    }
    return .{ .bits = bits, .count = count };
}

fn appendNewlineBits(leaf: *Rope.Leaf, old_len: usize, text: []const u8) void {
    for (text, 0..) |byte, index| {
        if (byte == '\n') {
            const bit_index = old_len + index;
            leaf.data.newline_bits[bit_index / 64] |= @as(u64, 1) << @intCast(bit_index % 64);
        }
    }
}

fn newlinesBeforeInLeaf(leaf: Rope.Leaf, upto: usize) usize {
    var count: usize = 0;
    var index: usize = 0;
    while (index < upto) {
        const word = index / 64;
        const bit_in_word = index % 64;
        const bits_here = @min(64 - bit_in_word, upto - index);
        var w = leaf.data.newline_bits[word] >> @intCast(bit_in_word);
        if (bits_here < 64) {
            const mask = (@as(u64, 1) << @intCast(bits_here)) - 1;
            w &= mask;
        }
        count += @popCount(w);
        index += bits_here;
    }
    return count;
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

fn updateCursorPathAfterDelete(cursor: *Rope.Cursor, byte_delta: usize, line_delta: usize) void {
    for (cursor.path[0..cursor.path_len]) |entry| {
        switch (entry.node.*) {
            .leaf => unreachable,
            .branch => |*branch| {
                if (entry.went_left) {
                    branch.weight -= byte_delta;
                    branch.line_count -= line_delta;
                }
                branch.byte_len -= byte_delta;
                branch.total_line_count -= line_delta;
            },
        }
    }
}

/// Remove `len` bytes at `offset` within a single leaf, keeping metrics and the
/// newline bitset in sync. Returns the number of newlines removed.
fn deleteFromLeaf(leaf: *Rope.Leaf, offset: usize, len: usize) usize {
    const old_len = leaf.len;
    const deleted_lines = countNewlines(leaf.data.text[offset..][0..len]);
    std.mem.copyForwards(u8, leaf.data.text[offset .. old_len - len], leaf.data.text[offset + len .. old_len]);
    leaf.len = @intCast(old_len - len);
    leaf.line_count -= @intCast(deleted_lines);
    _ = rebuildNewlineBits(leaf);
    return deleted_lines;
}

fn tryDeleteInPlace(node: ?*Rope.Node, offset: usize, len: usize) ?usize {
    const current = node orelse return null;
    switch (current.*) {
        .leaf => |*leaf| {
            if (offset + len > leaf.len) return null;
            return deleteFromLeaf(leaf, offset, len);
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

fn nodeHeightOptU8(node: ?*const Rope.Node) u8 {
    const current = node orelse return 0;
    return nodeHeight(current);
}

fn validateNode(node: ?*const Rope.Node) Rope.ValidationError!Rope.Validation {
    const current = node orelse return .{ .byte_len = 0, .line_count = 0, .height = 0, .leaf_count = 0 };

    return switch (current.*) {
        .leaf => |leaf| blk: {
            const actual_lines = countNewlines(leaf.data.text[0..leaf.len]);
            if (actual_lines != leaf.line_count) return error.WrongLineCount;

            const expected_bits = computeNewlineBits(leaf.data.text[0..leaf.len]);
            if (expected_bits.count != leaf.line_count) return error.WrongNewlineBits;
            for (leaf.data.newline_bits, expected_bits.bits) |actual, expected| {
                if (actual != expected) return error.WrongNewlineBits;
            }

            break :blk .{
                .byte_len = leaf.len,
                .line_count = leaf.line_count,
                .height = 1,
                .leaf_count = 1,
            };
        },
        .branch => |branch| blk: {
            const left = try validateNode(branch.left);
            const right = try validateNode(branch.right);
            const expected_height: u8 = @intCast(@max(left.height, right.height) + 1);

            if (branch.weight != left.byte_len) return error.WrongByteLen;
            if (branch.line_count != left.line_count) return error.WrongLineCount;
            if (branch.byte_len != left.byte_len + right.byte_len) return error.WrongByteLen;
            if (branch.total_line_count != left.line_count + right.line_count) return error.WrongLineCount;
            if (branch.height != expected_height) return error.WrongHeight;

            break :blk .{
                .byte_len = branch.byte_len,
                .line_count = branch.total_line_count,
                .height = branch.height,
                .leaf_count = left.leaf_count + right.leaf_count,
            };
        },
    };
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

fn copyNodeRange(node: ?*const Rope.Node, offset: usize, len: usize, out: []u8, index: *usize) void {
    if (len == 0) return;
    const current = node orelse return;

    switch (current.*) {
        .leaf => |leaf| {
            const end = offset + len;
            @memcpy(out[index.*..][0..len], leaf.data.text[offset..end]);
            index.* += len;
        },
        .branch => |branch| {
            if (offset < branch.weight) {
                const left_len = @min(len, branch.weight - offset);
                copyNodeRange(branch.left, offset, left_len, out, index);
                copyNodeRange(branch.right, 0, len - left_len, out, index);
            } else {
                copyNodeRange(branch.right, offset - branch.weight, len, out, index);
            }
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
    try std.testing.expectEqual(@as(usize, 4), rope.byteOffsetForLine(1));

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
    try std.testing.expectEqualStrings("aXYZa", out[Rope.leaf_capacity - 2 .. Rope.leaf_capacity + 3]);
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

    const out = try rope.toOwnedSlice(std.testing.allocator);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("2347", out);

    try rope.delete(0, rope.byteLen());
    const emptied = try rope.toOwnedSlice(std.testing.allocator);
    defer std.testing.allocator.free(emptied);
    try std.testing.expectEqualStrings("", emptied);
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
    try std.testing.expectEqual(@as(usize, 10), rope.byteOffsetForLineColumn(1, 99));
}

test "lineAt maps offsets to line indices" {
    var rope = Rope.init(std.testing.allocator);
    defer rope.deinit();

    try rope.setText("alpha\nbeta\ngamma");

    try std.testing.expectEqual(@as(usize, 0), rope.lineAt(0));
    try std.testing.expectEqual(@as(usize, 0), rope.lineAt(5));
    try std.testing.expectEqual(@as(usize, 1), rope.lineAt(6));
    try std.testing.expectEqual(@as(usize, 1), rope.lineAt(10));
    try std.testing.expectEqual(@as(usize, 2), rope.lineAt(11));
    try std.testing.expectEqual(@as(usize, 2), rope.lineAt(rope.byteLen()));

    for (0..rope.lineCount() + 1) |line| {
        try std.testing.expectEqual(line, rope.lineAt(rope.byteOffsetForLine(line)));
    }
}

test "grapheme boundaries move by cluster" {
    var rope = Rope.init(std.testing.allocator);
    defer rope.deinit();

    try rope.setText("a🌊b\n👩\u{200d}💻x");

    try std.testing.expectEqual(@as(usize, 1), try rope.nextGraphemeBoundary(0));
    try std.testing.expectEqual(@as(usize, 5), try rope.nextGraphemeBoundary(1));
    try std.testing.expectEqual(@as(usize, 1), try rope.prevGraphemeBoundary(5));
    try std.testing.expectEqual(@as(usize, 0), try rope.prevGraphemeBoundary(1));

    // ZWJ emoji sequence is a single cluster.
    const zwj_start = 7; // after "a🌊b\n"
    const after_zwj = try rope.nextGraphemeBoundary(zwj_start);
    try std.testing.expectEqual(zwj_start, try rope.prevGraphemeBoundary(after_zwj));
}

test "copies byte ranges across leaves" {
    var rope = Rope.init(std.testing.allocator);
    defer rope.deinit();

    var base: [Rope.leaf_capacity * 3 + 11]u8 = undefined;
    for (&base, 0..) |*byte, index| byte.* = @intCast('A' + index % 26);
    try rope.setText(&base);
    try rope.validate();

    var out: [Rope.leaf_capacity + 17]u8 = undefined;
    rope.copyRange(&out, Rope.leaf_capacity - 9);
    try std.testing.expectEqualSlices(u8, base[Rope.leaf_capacity - 9 ..][0..out.len], &out);
}

test "maps line ranges to byte ranges" {
    var rope = Rope.init(std.testing.allocator);
    defer rope.deinit();

    try rope.setText("zero\none\ntwo\nthree\nfour");

    var range = rope.byteRangeForLines(1, 2);
    try std.testing.expectEqual(@as(usize, 5), range.start);
    try std.testing.expectEqual(@as(usize, 13), range.end);

    range = rope.byteRangeForLines(4, 20);
    try std.testing.expectEqual(@as(usize, 19), range.start);
    try std.testing.expectEqual(rope.byteLen(), range.end);
}

test "preserves utf8 bytes through edits" {
    var rope = Rope.init(std.testing.allocator);
    defer rope.deinit();

    try rope.setText("ciao 🌊\n世界");
    try rope.insert(5, "veloce ");
    try rope.delete(0, 5);

    const out = try rope.toOwnedSlice(std.testing.allocator);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("veloce 🌊\n世界", out);
}

test "validates utf8 and detects invalid bytes" {
    var rope = Rope.init(std.testing.allocator);
    defer rope.deinit();

    try rope.setText("ascii 🌊 世界");
    try std.testing.expect(rope.validateUtf8());

    try rope.setText(&.{ 0xf0, 0x28, 0x8c, 0x28 });
    try std.testing.expect(!rope.validateUtf8());
}

test "finds utf8 boundaries" {
    var rope = Rope.init(std.testing.allocator);
    defer rope.deinit();

    try rope.setText("a🌊b");

    try std.testing.expect(rope.isUtf8Boundary(0));
    try std.testing.expect(rope.isUtf8Boundary(1));
    try std.testing.expect(!rope.isUtf8Boundary(2));
    try std.testing.expect(!rope.isUtf8Boundary(3));
    try std.testing.expect(!rope.isUtf8Boundary(4));
    try std.testing.expect(rope.isUtf8Boundary(5));
    try std.testing.expectEqual(@as(usize, 1), rope.prevUtf8Boundary(4));
    try std.testing.expectEqual(@as(usize, 5), rope.nextUtf8Boundary(2));
}

test "iterates utf8 codepoints across leaves" {
    var rope = Rope.init(std.testing.allocator);
    defer rope.deinit();

    var text: [Rope.leaf_capacity + 4]u8 = undefined;
    @memset(text[0 .. Rope.leaf_capacity - 1], 'x');
    @memcpy(text[Rope.leaf_capacity - 1 ..][0..4], "🌊");
    text[Rope.leaf_capacity + 3] = 'y';
    try rope.setText(&text);

    try std.testing.expect(rope.validateUtf8());
    const wave = try rope.codepointAt(Rope.leaf_capacity - 1);
    try std.testing.expectEqual(@as(u21, '🌊'), wave.value);
    try std.testing.expectEqual(@as(u3, 4), wave.len);
    try std.testing.expectEqual(@as(usize, Rope.leaf_capacity + 1), try rope.countCodepointsUtf8(.{ .start = 0, .end = rope.byteLen() }));
}

test "iterates grapheme clusters" {
    var rope = Rope.init(std.testing.allocator);
    defer rope.deinit();

    try rope.setText("a\u{0301} 👩\u{200d}💻 🇮🇹 x");
    var iter = rope.graphemes(.{ .start = 0, .end = rope.byteLen() });

    const first = (try iter.next()).?;
    try std.testing.expectEqual(@as(usize, 0), first.start);
    try std.testing.expectEqual(@as(u8, 1), first.width);

    _ = (try iter.next()).?;
    const zwj = (try iter.next()).?;
    try std.testing.expectEqual(@as(u8, 2), zwj.width);

    _ = (try iter.next()).?;
    const flag = (try iter.next()).?;
    try std.testing.expectEqual(@as(u8, 2), flag.width);
}

test "computes display width and visual columns" {
    var rope = Rope.init(std.testing.allocator);
    defer rope.deinit();

    try rope.setText("a\t世界\nnext");

    const first_line = rope.byteRangeForLines(0, 1);
    try std.testing.expectEqual(@as(usize, 8), try rope.displayWidth(first_line, 4));
    try std.testing.expectEqual(@as(usize, 0), try rope.byteOffsetForLineVisualColumn(0, 0, 4));
    try std.testing.expectEqual(@as(usize, 1), try rope.byteOffsetForLineVisualColumn(0, 1, 4));
    try std.testing.expectEqual(@as(usize, 2), try rope.byteOffsetForLineVisualColumn(0, 4, 4));
}

test "normalization fast path accepts ascii only" {
    var rope = Rope.init(std.testing.allocator);
    defer rope.deinit();

    try rope.setText("plain ascii");
    try std.testing.expect(try rope.isNormalizedNfc(.{ .start = 0, .end = rope.byteLen() }));
    try std.testing.expectEqual(Rope.NormalizationStatus.normalized, try rope.nfcStatus(.{ .start = 0, .end = rope.byteLen() }));

    try rope.setText("café");
    try std.testing.expect(!try rope.isNormalizedNfc(.{ .start = 0, .end = rope.byteLen() }));
    try std.testing.expectEqual(Rope.NormalizationStatus.unknown_without_tables, try rope.nfcStatus(.{ .start = 0, .end = rope.byteLen() }));
}

test "utf8 safe edits clamp to codepoint boundaries" {
    var rope = Rope.init(std.testing.allocator);
    defer rope.deinit();

    try rope.setText("a🌊b");
    try std.testing.expectError(error.InvalidCodepoint, rope.insertUtf8(2, "x", .assert_boundary));

    const inserted_at = try rope.insertUtf8(2, "x", .clamp_backward);
    try std.testing.expectEqual(@as(usize, 1), inserted_at);

    const out = try rope.toOwnedSlice(std.testing.allocator);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("ax🌊b", out);

    const deleted = try rope.deleteUtf8(3, 1, .clamp_forward);
    try std.testing.expectEqual(@as(usize, 6), deleted.start);
    try std.testing.expectEqual(@as(usize, 6), deleted.end);
}

test "utf8 safe insert rejects invalid text" {
    var rope = Rope.init(std.testing.allocator);
    defer rope.deinit();

    try rope.setText("abc");
    try std.testing.expectError(error.InvalidCodepoint, rope.insertUtf8(1, &.{0xff}, .assert_boundary));
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

    // A chunk larger than a leaf forces splits/path-copies (real node churn).
    var chunk: [Rope.leaf_capacity + 40]u8 = undefined;
    @memset(&chunk, 'a');

    try rope.setText("seed");
    for (0..200) |index| {
        const offset = (index * 7) % (rope.byteLen() + 1);
        try rope.insert(offset, &chunk);
    }

    const before = rope.stats();
    const text_before = try rope.toOwnedSlice(std.testing.allocator);
    defer std.testing.allocator.free(text_before);

    try rope.compact();
    const after = rope.stats();

    try std.testing.expect(after.allocated_nodes < before.allocated_nodes);

    const text_after = try rope.toOwnedSlice(std.testing.allocator);
    defer std.testing.allocator.free(text_after);
    try std.testing.expectEqualStrings(text_before, text_after);
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
    try rope.validate();

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
    try rope.validate();

    const out = try rope.toOwnedSlice(std.testing.allocator);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings(model.items, out);
}

test "deterministic random edits match array list model" {
    var rope = Rope.init(std.testing.allocator);
    defer rope.deinit();

    var model: std.ArrayList(u8) = .empty;
    defer model.deinit(std.testing.allocator);

    try rope.setText("");

    var rng = std.Random.DefaultPrng.init(0xdecafbad);
    const random = rng.random();
    const inserts = [_][]const u8{ "a", "bb", "ccc", "\n", "xyz" };

    for (0..2000) |index| {
        if (model.items.len == 0 or random.boolean()) {
            const text = inserts[random.uintLessThan(usize, inserts.len)];
            const offset = random.uintLessThan(usize, model.items.len + 1);
            try rope.insert(offset, text);
            try model.insertSlice(std.testing.allocator, offset, text);
        } else {
            const offset = random.uintLessThan(usize, model.items.len);
            const len = random.uintLessThan(usize, @min(8, model.items.len - offset)) + 1;
            try rope.delete(offset, len);
            model.replaceRangeAssumeCapacity(offset, len, "");
        }

        if (index % 257 == 0) try rope.validate();
    }
    try rope.validate();

    const out = try rope.toOwnedSlice(std.testing.allocator);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings(model.items, out);
}
