const std = @import("std");
const Rope = @import("rope.zig").Rope;
const undotree = @import("undotree.zig");
const UndoTree = undotree.UndoTree;
const Node = undotree.Node;

/// A text buffer: owns the rope, tracks an edit generation for cursor safety,
/// a dirty flag, and layout policy (tab width, line ending). Headless: no
/// rendering or IO here.
pub const Buffer = struct {
    pub const default_max_file_bytes: usize = 1024 * 1024 * 1024;

    pub const LineEnding = enum { lf, crlf };
    pub const BoundaryMode = Rope.BoundaryMode;
    pub const ByteRange = Rope.ByteRange;

    rope: Rope,
    allocator: std.mem.Allocator,
    undo_tree: UndoTree,
    path: ?[]u8 = null,
    /// Reused scratch for capturing deleted bytes (avoids per-delete allocation).
    delete_scratch: std.ArrayListUnmanaged(u8) = .empty,
    /// Reused scratch for the downward path in `jumpToState`.
    jump_scratch: std.ArrayListUnmanaged(*Node) = .empty,
    generation: u64 = 1,
    dirty: bool = false,
    line_ending: LineEnding = .lf,
    tab_width: usize = 4,

    pub fn init(allocator: std.mem.Allocator) !Buffer {
        return .{
            .rope = Rope.init(allocator),
            .allocator = allocator,
            .undo_tree = try UndoTree.init(allocator),
        };
    }

    pub fn initFromText(allocator: std.mem.Allocator, text: []const u8) !Buffer {
        var buffer = try Buffer.init(allocator);
        errdefer buffer.deinit();
        try buffer.rope.setText(text);
        return buffer;
    }

    pub fn initWithPath(allocator: std.mem.Allocator, path: []const u8) !Buffer {
        var buffer = try Buffer.init(allocator);
        errdefer buffer.deinit();
        try buffer.setPath(path);
        buffer.dirty = false;
        return buffer;
    }

    pub fn loadFromFile(io: std.Io, allocator: std.mem.Allocator, path: []const u8) !Buffer {
        return loadFromFileLimit(io, allocator, path, default_max_file_bytes);
    }

    pub fn loadFromFileLimit(io: std.Io, allocator: std.mem.Allocator, path: []const u8, max_bytes: usize) !Buffer {
        const text = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(max_bytes));
        defer allocator.free(text);

        var buffer = try Buffer.init(allocator);
        errdefer buffer.deinit();
        try buffer.rope.setText(text);
        try buffer.setPath(path);
        buffer.dirty = false;
        return buffer;
    }

    pub fn deinit(self: *Buffer) void {
        if (self.path) |path| self.allocator.free(path);
        self.delete_scratch.deinit(self.allocator);
        self.jump_scratch.deinit(self.allocator);
        self.undo_tree.deinit();
        self.rope.deinit();
        self.* = undefined;
    }

    fn touch(self: *Buffer) void {
        self.generation += 1;
        self.dirty = true;
    }

    pub fn byteLen(self: Buffer) usize {
        return self.rope.byteLen();
    }

    /// Number of display lines (newline count + 1 for a non-empty final line).
    pub fn lineCount(self: Buffer) usize {
        return self.rope.lineCount() + 1;
    }

    pub fn lineAt(self: Buffer, offset: usize) usize {
        return self.rope.lineAt(offset);
    }

    pub fn byteOffsetForLine(self: Buffer, line: usize) usize {
        return self.rope.byteOffsetForLine(line);
    }

    pub fn lineRange(self: Buffer, line: usize) ByteRange {
        return self.rope.byteRangeForLines(line, 1);
    }

    /// The byte range of a line's content, excluding a trailing newline.
    pub fn lineContentRange(self: Buffer, line: usize) ByteRange {
        const range = self.rope.byteRangeForLines(line, 1);
        if (range.end > range.start and self.rope.byteAt(range.end - 1) == '\n') {
            return .{ .start = range.start, .end = range.end - 1 };
        }
        return range;
    }

    /// Visual column (tab-expanded, grapheme-aware) of `offset` within its line.
    pub fn visualColumnAt(self: Buffer, offset: usize) !usize {
        const line = self.rope.lineAt(offset);
        const start = self.rope.byteOffsetForLine(line);
        return try self.rope.displayWidth(.{ .start = start, .end = offset }, self.tab_width);
    }

    pub fn copyRange(self: Buffer, out: []u8, offset: usize) void {
        self.rope.copyRange(out, offset);
    }

    pub fn toOwnedSlice(self: Buffer, allocator: std.mem.Allocator) ![]u8 {
        return self.rope.toOwnedSlice(allocator);
    }

    pub fn insert(self: *Buffer, offset: usize, text: []const u8) !void {
        if (text.len == 0) return;
        try self.undo_tree.recordInsertion(offset, text);
        try self.rope.insert(offset, text);
        self.touch();
    }

    pub fn delete(self: *Buffer, offset: usize, len: usize) !void {
        if (len == 0) return;
        try self.recordDeletionRange(offset, len);
        try self.rope.delete(offset, len);
        self.touch();
    }

    pub fn insertUtf8(self: *Buffer, offset: usize, text: []const u8, mode: BoundaryMode) !usize {
        if (!std.unicode.utf8ValidateSlice(text)) return error.InvalidCodepoint;
        const at = try self.rope.resolveUtf8Boundary(offset, mode);
        if (text.len != 0) {
            try self.undo_tree.recordInsertion(at, text);
            try self.rope.insert(at, text);
            self.touch();
        }
        return at;
    }

    pub fn deleteUtf8(self: *Buffer, offset: usize, len: usize, mode: BoundaryMode) !ByteRange {
        const start = try self.rope.resolveUtf8Boundary(offset, mode);
        const requested_end = @min(offset + len, self.byteLen());
        const end = try self.rope.resolveUtf8Boundary(requested_end, mode);
        if (end > start) try self.delete(start, end - start);
        return .{ .start = start, .end = end };
    }

    /// Replace the whole buffer. Resets the undo tree (new file baseline).
    pub fn setText(self: *Buffer, text: []const u8) !void {
        try self.rope.setText(text);
        try self.undo_tree.reset();
        self.touch();
    }

    pub fn markSaved(self: *Buffer) void {
        self.dirty = false;
    }

    pub fn save(self: *Buffer, io: std.Io) !void {
        const path = self.path orelse return error.NoPath;
        try self.saveToFile(io, path);
    }

    pub fn saveToFile(self: *Buffer, io: std.Io, path: []const u8) !void {
        const text = try self.rope.toOwnedSlice(self.allocator);
        defer self.allocator.free(text);

        const file = try std.Io.Dir.cwd().createFile(io, path, .{ .truncate = true });
        defer file.close(io);
        try file.writeStreamingAll(io, text);
        try file.sync(io);

        try self.setPath(path);
        self.markSaved();
    }

    /// Open an undo group; edits until the matching `endUndoGroup` become one
    /// undoable unit (e.g. an entire insert-mode session). Groups may nest.
    pub fn beginUndoGroup(self: *Buffer, cursor_offset: usize) void {
        self.undo_tree.beginGroup(cursor_offset);
    }

    pub fn endUndoGroup(self: *Buffer, cursor_offset: usize) void {
        self.undo_tree.endGroup(cursor_offset);
    }

    /// Undo the current node's transition (move to its parent state). Returns
    /// the caret offset to restore, or null if already at the root.
    pub fn undo(self: *Buffer) !?usize {
        self.undo_tree.commitOpen();
        const node = self.undo_tree.current;
        const parent = node.parent orelse return null;
        try self.applyNodeInverse(node);
        self.undo_tree.current = parent;
        return node.cursor_before;
    }

    /// Redo along the most recent branch. Returns the caret offset to restore,
    /// or null if there is no child state.
    pub fn redo(self: *Buffer) !?usize {
        self.undo_tree.commitOpen();
        const child = self.undo_tree.redoChild() orelse return null;
        try self.applyNodeForward(child);
        child.parent.?.last_visited = indexOfChild(child);
        self.undo_tree.current = child;
        return child.cursor_after;
    }

    /// Jump to any recorded state by sequence id, walking the tree via the
    /// lowest common ancestor. Returns the caret offset to restore.
    pub fn jumpToState(self: *Buffer, seq: u64) !?usize {
        self.undo_tree.commitOpen();
        const target = self.undo_tree.findBySeq(seq) orelse return error.NoSuchState;
        const ancestor = UndoTree.lca(self.undo_tree.current, target);

        // Undo upward from current to the common ancestor.
        while (self.undo_tree.current != ancestor) {
            const node = self.undo_tree.current;
            try self.applyNodeInverse(node);
            self.undo_tree.current = node.parent.?;
        }

        // Collect the downward path (ancestor -> target), then apply it forward.
        self.jump_scratch.clearRetainingCapacity();
        var walker = target;
        while (walker != ancestor) {
            try self.jump_scratch.append(self.allocator, walker);
            walker = walker.parent.?;
        }
        var index = self.jump_scratch.items.len;
        while (index > 0) {
            index -= 1;
            const node = self.jump_scratch.items[index];
            try self.applyNodeForward(node);
            node.parent.?.last_visited = indexOfChild(node);
        }
        self.undo_tree.current = target;
        return target.cursor_after;
    }

    fn applyNodeForward(self: *Buffer, node: *Node) !void {
        for (node.edits.items) |edit| {
            try self.applyRaw(edit.offset, edit.old_text.items.len, edit.new_text.items);
        }
    }

    fn applyNodeInverse(self: *Buffer, node: *Node) !void {
        var index = node.edits.items.len;
        while (index > 0) {
            index -= 1;
            const edit = node.edits.items[index];
            if (edit.old_text_reversed) {
                try self.delete_scratch.resize(self.allocator, edit.old_text.items.len);
                for (edit.old_text.items, 0..) |byte, i| {
                    self.delete_scratch.items[edit.old_text.items.len - 1 - i] = byte;
                }
                try self.applyRaw(edit.offset, edit.new_text.items.len, self.delete_scratch.items);
            } else {
                try self.applyRaw(edit.offset, edit.new_text.items.len, edit.old_text.items);
            }
        }
    }

    /// Apply an edit without recording it (used by undo/redo/jump).
    fn applyRaw(self: *Buffer, offset: usize, del_len: usize, ins_text: []const u8) !void {
        if (del_len != 0) try self.rope.delete(offset, del_len);
        if (ins_text.len != 0) try self.rope.insert(offset, ins_text);
        self.touch();
    }

    fn recordDeletionRange(self: *Buffer, offset: usize, len: usize) !void {
        try self.delete_scratch.resize(self.allocator, len);
        self.rope.copyRange(self.delete_scratch.items, offset);
        try self.undo_tree.recordDeletion(offset, self.delete_scratch.items);
    }

    fn setPath(self: *Buffer, path: []const u8) !void {
        const copy = try self.allocator.dupe(u8, path);
        if (self.path) |old| self.allocator.free(old);
        self.path = copy;
    }
};

fn indexOfChild(node: *Node) usize {
    const parent = node.parent.?;
    for (parent.children.items, 0..) |child, index| {
        if (child == node) return index;
    }
    unreachable;
}

/// A grapheme-aware caret. Positions are byte offsets; the cursor is
/// generation-stamped so it can be re-validated after edits it did not perform.
///
/// For typing (`insertText`, `deleteBackward`, `deleteForward`) it drives an
/// internal `Rope.Cursor` fast path: consecutive edits at the caret mutate the
/// cached leaf in place and update ancestor metrics without descending from the
/// root. The fast path is auto-invalidated (lazy re-seek) whenever the buffer
/// changed under us or the caret moved.
pub const Cursor = struct {
    offset: usize = 0,
    generation: u64 = 0,
    /// Sticky visual column for vertical movement; null resets on horizontal moves.
    goal_column: ?usize = null,

    /// Cached physical position for the typing fast path.
    rope_cursor: Rope.Cursor = .{},
    /// Buffer generation for which `rope_cursor` is valid (0 = never seeded).
    rope_cursor_generation: u64 = 0,

    pub fn init(buffer: Buffer) Cursor {
        return .{ .offset = 0, .generation = buffer.generation };
    }

    pub fn at(buffer: Buffer, offset: usize) Cursor {
        return .{ .offset = @min(offset, buffer.byteLen()), .generation = buffer.generation };
    }

    /// Re-validate against the buffer if it changed under us: clamp to length
    /// and snap back to a codepoint boundary. Cheap when generations match.
    pub fn sync(self: *Cursor, buffer: Buffer) !void {
        if (self.generation == buffer.generation) return;
        if (self.offset > buffer.byteLen()) self.offset = buffer.byteLen();
        self.offset = try buffer.rope.resolveUtf8Boundary(self.offset, .clamp_backward);
        self.generation = buffer.generation;
    }

    pub fn setOffset(self: *Cursor, buffer: Buffer, offset: usize) !void {
        self.offset = @min(offset, buffer.byteLen());
        self.generation = buffer.generation;
        self.goal_column = null;
    }

    /// Ensure the cached `rope_cursor` matches the current buffer state and
    /// caret offset; re-seed from the root only when stale.
    fn ensureRopeCursor(self: *Cursor, buffer: *Buffer) void {
        if (self.rope_cursor_generation != buffer.generation or self.rope_cursor.offset != self.offset) {
            buffer.rope.seekCursor(&self.rope_cursor, self.offset);
            self.rope_cursor_generation = buffer.generation;
        }
    }

    fn adoptRopeCursor(self: *Cursor, buffer: *Buffer) void {
        buffer.touch();
        self.offset = self.rope_cursor.offset;
        self.generation = buffer.generation;
        self.rope_cursor_generation = buffer.generation;
        self.goal_column = null;
    }

    // Typing fast path: consecutive edits at the caret mutate the cached leaf.

    pub fn insertText(self: *Cursor, buffer: *Buffer, text: []const u8) !void {
        if (text.len == 0) return;
        try self.sync(buffer.*);
        try buffer.undo_tree.recordInsertion(self.offset, text);
        self.ensureRopeCursor(buffer);
        try buffer.rope.insertAtCursor(&self.rope_cursor, text);
        self.adoptRopeCursor(buffer);
    }

    /// Delete the grapheme cluster before the caret (Backspace).
    pub fn deleteBackward(self: *Cursor, buffer: *Buffer) !void {
        try self.sync(buffer.*);
        if (self.offset == 0) return;
        const prev = try buffer.rope.prevGraphemeBoundary(self.offset);
        try buffer.recordDeletionRange(prev, self.offset - prev);
        self.ensureRopeCursor(buffer);
        try buffer.rope.deleteBeforeCursor(&self.rope_cursor, self.offset - prev);
        self.adoptRopeCursor(buffer);
    }

    /// Delete the grapheme cluster at the caret (Delete).
    pub fn deleteForward(self: *Cursor, buffer: *Buffer) !void {
        try self.sync(buffer.*);
        if (self.offset >= buffer.byteLen()) return;
        const next = try buffer.rope.nextGraphemeBoundary(self.offset);
        try buffer.recordDeletionRange(self.offset, next - self.offset);
        self.ensureRopeCursor(buffer);
        try buffer.rope.deleteAtCursor(&self.rope_cursor, next - self.offset);
        self.adoptRopeCursor(buffer);
    }

    pub fn line(self: *Cursor, buffer: Buffer) !usize {
        try self.sync(buffer);
        return buffer.rope.lineAt(self.offset);
    }

    pub fn visualColumn(self: *Cursor, buffer: Buffer) !usize {
        try self.sync(buffer);
        return buffer.visualColumnAt(self.offset);
    }

    pub fn moveLeft(self: *Cursor, buffer: Buffer) !void {
        try self.sync(buffer);
        const line_start = buffer.rope.byteOffsetForLine(buffer.rope.lineAt(self.offset));
        if (self.offset <= line_start) return;
        self.offset = try buffer.rope.prevGraphemeBoundary(self.offset);
        self.goal_column = null;
    }

    pub fn moveRight(self: *Cursor, buffer: Buffer) !void {
        try self.sync(buffer);
        const content_end = buffer.lineContentRange(buffer.rope.lineAt(self.offset)).end;
        if (self.offset >= content_end) return;
        self.offset = try buffer.rope.nextGraphemeBoundary(self.offset);
        self.goal_column = null;
    }

    pub fn moveToLineStart(self: *Cursor, buffer: Buffer) !void {
        try self.sync(buffer);
        const current = buffer.rope.lineAt(self.offset);
        self.offset = buffer.rope.byteOffsetForLine(current);
        self.goal_column = null;
    }

    pub fn moveToLineEnd(self: *Cursor, buffer: Buffer) !void {
        try self.sync(buffer);
        const current = buffer.rope.lineAt(self.offset);
        self.offset = buffer.lineContentRange(current).end;
        self.goal_column = null;
    }

    pub fn moveUp(self: *Cursor, buffer: Buffer) !void {
        try self.sync(buffer);
        const current = buffer.rope.lineAt(self.offset);
        if (current == 0) {
            self.offset = 0;
            return;
        }
        try self.moveToLine(buffer, current - 1);
    }

    pub fn moveDown(self: *Cursor, buffer: Buffer) !void {
        try self.sync(buffer);
        const current = buffer.rope.lineAt(self.offset);
        const last_line = buffer.lineCount() - 1;
        if (current >= last_line) {
            self.offset = buffer.byteLen();
            return;
        }
        try self.moveToLine(buffer, current + 1);
    }

    fn moveToLine(self: *Cursor, buffer: Buffer, target_line: usize) !void {
        const column = self.goal_column orelse try buffer.visualColumnAt(self.offset);
        self.goal_column = column;
        self.offset = try buffer.rope.byteOffsetForLineVisualColumn(target_line, column, buffer.tab_width);
        self.generation = buffer.generation;
    }
};

/// A directional selection: `anchor` is fixed, `head` is the moving caret.
pub const Selection = struct {
    anchor: usize = 0,
    head: usize = 0,
    generation: u64 = 0,

    pub fn init(buffer: Buffer) Selection {
        return .{ .anchor = 0, .head = 0, .generation = buffer.generation };
    }

    pub fn fromCursor(cursor: Cursor) Selection {
        return .{ .anchor = cursor.offset, .head = cursor.offset, .generation = cursor.generation };
    }

    pub fn range(self: Selection) Rope.ByteRange {
        return .{ .start = @min(self.anchor, self.head), .end = @max(self.anchor, self.head) };
    }

    pub fn isEmpty(self: Selection) bool {
        return self.anchor == self.head;
    }

    pub fn len(self: Selection) usize {
        const r = self.range();
        return r.end - r.start;
    }

    pub fn collapseToHead(self: *Selection) void {
        self.anchor = self.head;
    }

    pub fn setHead(self: *Selection, buffer: Buffer, offset: usize) void {
        self.head = @min(offset, buffer.byteLen());
        self.generation = buffer.generation;
    }

    pub fn sync(self: *Selection, buffer: Buffer) !void {
        if (self.generation == buffer.generation) return;
        const max = buffer.byteLen();
        if (self.anchor > max) self.anchor = max;
        if (self.head > max) self.head = max;
        self.anchor = try buffer.rope.resolveUtf8Boundary(self.anchor, .clamp_backward);
        self.head = try buffer.rope.resolveUtf8Boundary(self.head, .clamp_backward);
        self.generation = buffer.generation;
    }

    /// Delete the selected range from the buffer and collapse to its start.
    pub fn deleteFrom(self: *Selection, buffer: *Buffer) !void {
        try self.sync(buffer.*);
        const r = self.range();
        if (r.end > r.start) try buffer.delete(r.start, r.end - r.start);
        self.anchor = r.start;
        self.head = r.start;
        self.generation = buffer.generation;
    }
};

test "buffer tracks generation and dirty flag" {
    var buffer = try Buffer.initFromText(std.testing.allocator, "hello");
    defer buffer.deinit();

    try std.testing.expect(!buffer.dirty);
    const before = buffer.generation;
    try buffer.insert(5, " world");
    try std.testing.expect(buffer.dirty);
    try std.testing.expect(buffer.generation > before);
    try std.testing.expectEqual(@as(usize, 11), buffer.byteLen());

    buffer.markSaved();
    try std.testing.expect(!buffer.dirty);
}

test "buffer loads and saves files" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "in.txt", .data = "one\ntwo" });
    const in_path = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..], "in.txt" });
    defer std.testing.allocator.free(in_path);
    const out_path = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..], "out.txt" });
    defer std.testing.allocator.free(out_path);

    var buffer = try Buffer.loadFromFile(std.testing.io, std.testing.allocator, in_path);
    defer buffer.deinit();
    try std.testing.expect(!buffer.dirty);
    try std.testing.expect(buffer.path != null);

    const loaded = try buffer.toOwnedSlice(std.testing.allocator);
    defer std.testing.allocator.free(loaded);
    try std.testing.expectEqualStrings("one\ntwo", loaded);

    try buffer.insert(buffer.byteLen(), "\nthree");
    try std.testing.expect(buffer.dirty);
    try buffer.saveToFile(std.testing.io, out_path);
    try std.testing.expect(!buffer.dirty);

    const saved = try tmp.dir.readFileAlloc(std.testing.io, "out.txt", std.testing.allocator, .limited(Buffer.default_max_file_bytes));
    defer std.testing.allocator.free(saved);
    try std.testing.expectEqualStrings("one\ntwo\nthree", saved);
}

test "buffer save requires a path" {
    var buffer = try Buffer.initFromText(std.testing.allocator, "scratch");
    defer buffer.deinit();

    try std.testing.expectError(error.NoPath, buffer.save(std.testing.io));
}

test "buffer line metrics" {
    var buffer = try Buffer.initFromText(std.testing.allocator, "one\ntwo\nthree");
    defer buffer.deinit();

    try std.testing.expectEqual(@as(usize, 3), buffer.lineCount());
    try std.testing.expectEqual(@as(usize, 0), buffer.lineAt(0));
    try std.testing.expectEqual(@as(usize, 1), buffer.lineAt(5));
    try std.testing.expectEqual(@as(usize, 2), buffer.lineAt(9));

    const content = buffer.lineContentRange(1);
    try std.testing.expectEqual(@as(usize, 4), content.start);
    try std.testing.expectEqual(@as(usize, 7), content.end);
}

test "cursor moves by grapheme cluster" {
    var buffer = try Buffer.initFromText(std.testing.allocator, "a🌊b");
    defer buffer.deinit();

    var cursor = Cursor.init(buffer);
    try cursor.moveRight(buffer);
    try std.testing.expectEqual(@as(usize, 1), cursor.offset);
    try cursor.moveRight(buffer);
    try std.testing.expectEqual(@as(usize, 5), cursor.offset); // skipped 4-byte emoji
    try cursor.moveRight(buffer);
    try std.testing.expectEqual(@as(usize, 6), cursor.offset);
    try cursor.moveRight(buffer); // clamps at end
    try std.testing.expectEqual(@as(usize, 6), cursor.offset);

    try cursor.moveLeft(buffer);
    try std.testing.expectEqual(@as(usize, 5), cursor.offset);
    try cursor.moveLeft(buffer);
    try std.testing.expectEqual(@as(usize, 1), cursor.offset);
}

test "cursor left and right stay within the current line" {
    var buffer = try Buffer.initFromText(std.testing.allocator, "ab\ncd");
    defer buffer.deinit();

    // At the end of line 0 ("ab"), moveRight must not cross into line 1.
    var cursor = Cursor.at(buffer, 2);
    try cursor.moveRight(buffer);
    try std.testing.expectEqual(@as(usize, 2), cursor.offset);

    // At the start of line 1 ("cd", offset 3), moveLeft must not cross back up.
    try cursor.setOffset(buffer, 3);
    try cursor.moveLeft(buffer);
    try std.testing.expectEqual(@as(usize, 3), cursor.offset);

    // Within a line, movement still works.
    try cursor.moveRight(buffer);
    try std.testing.expectEqual(@as(usize, 4), cursor.offset);
    try cursor.moveLeft(buffer);
    try std.testing.expectEqual(@as(usize, 3), cursor.offset);
}

test "cursor line start and end" {
    var buffer = try Buffer.initFromText(std.testing.allocator, "hello\nworld");
    defer buffer.deinit();

    var cursor = Cursor.at(buffer, 8);
    try cursor.moveToLineStart(buffer);
    try std.testing.expectEqual(@as(usize, 6), cursor.offset);
    try cursor.moveToLineEnd(buffer);
    try std.testing.expectEqual(@as(usize, 11), cursor.offset);
}

test "cursor vertical movement keeps goal column" {
    var buffer = try Buffer.initFromText(std.testing.allocator, "abcdef\nxy\nlongline");
    defer buffer.deinit();

    var cursor = Cursor.at(buffer, 5); // line 0, column 5
    try cursor.moveDown(buffer); // line 1 only has 2 columns -> clamp to end
    try std.testing.expectEqual(@as(usize, 9), cursor.offset); // end of "xy"
    try cursor.moveDown(buffer); // line 2, goal column 5 restored
    try std.testing.expectEqual(@as(usize, 15), cursor.offset); // "longl|ine"
}

test "cursor re-syncs after external edit" {
    var buffer = try Buffer.initFromText(std.testing.allocator, "hello world");
    defer buffer.deinit();

    var cursor = Cursor.at(buffer, 11);
    try buffer.delete(5, 6); // now "hello", generation bumped
    try cursor.sync(buffer);
    try std.testing.expectEqual(@as(usize, 5), cursor.offset);
}

test "selection range and delete" {
    var buffer = try Buffer.initFromText(std.testing.allocator, "hello world");
    defer buffer.deinit();

    var selection = Selection.init(buffer);
    selection.anchor = 0;
    selection.setHead(buffer, 6);
    try std.testing.expectEqual(@as(usize, 6), selection.len());
    try std.testing.expect(!selection.isEmpty());

    try selection.deleteFrom(&buffer);
    try std.testing.expect(selection.isEmpty());
    try std.testing.expectEqual(@as(usize, 0), selection.head);

    const out = try buffer.toOwnedSlice(std.testing.allocator);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("world", out);
}

test "cursor typing fast path inserts and advances" {
    var buffer = try Buffer.init(std.testing.allocator);
    defer buffer.deinit();

    var cursor = Cursor.init(buffer);
    for ("hello") |ch| try cursor.insertText(&buffer, &.{ch});
    try std.testing.expectEqual(@as(usize, 5), cursor.offset);

    // Consecutive keystrokes stay in one leaf (no tree growth).
    try std.testing.expectEqual(@as(usize, 1), buffer.rope.stats().node_count);

    const out = try buffer.toOwnedSlice(std.testing.allocator);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("hello", out);
}

test "cursor backspace and delete are grapheme-aware" {
    var buffer = try Buffer.init(std.testing.allocator);
    defer buffer.deinit();

    var cursor = Cursor.init(buffer);
    try cursor.insertText(&buffer, "a🌊b");
    try std.testing.expectEqual(@as(usize, 6), cursor.offset);

    try cursor.deleteBackward(&buffer); // removes 'b'
    try std.testing.expectEqual(@as(usize, 5), cursor.offset);
    try cursor.deleteBackward(&buffer); // removes 4-byte emoji cluster
    try std.testing.expectEqual(@as(usize, 1), cursor.offset);

    const out = try buffer.toOwnedSlice(std.testing.allocator);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("a", out);

    // deleteForward at start of "a" removes it.
    try cursor.setOffset(buffer, 0);
    try cursor.deleteForward(&buffer);
    const empty = try buffer.toOwnedSlice(std.testing.allocator);
    defer std.testing.allocator.free(empty);
    try std.testing.expectEqualStrings("", empty);
}

test "typing fast path re-seeks after movement" {
    var buffer = try Buffer.initFromText(std.testing.allocator, "one\ntwo\nthree");
    defer buffer.deinit();

    var cursor = Cursor.at(buffer, buffer.byteLen());
    try cursor.insertText(&buffer, "!");
    try cursor.moveToLineStart(buffer); // caret jumps; fast path must re-seed
    try cursor.insertText(&buffer, ">");

    const out = try buffer.toOwnedSlice(std.testing.allocator);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("one\ntwo\n>three!", out);
    try buffer.rope.validate();
}

test "typing matches model after mixed edits and moves" {
    var buffer = try Buffer.init(std.testing.allocator);
    defer buffer.deinit();

    var model: std.ArrayList(u8) = .empty;
    defer model.deinit(std.testing.allocator);

    var cursor = Cursor.init(buffer);
    const words = [_][]const u8{ "fast ", "rope ", "editor ", "🚀 ", "líne\n" };
    for (words) |word| {
        try cursor.insertText(&buffer, word);
        try model.appendSlice(std.testing.allocator, word);
    }

    // Backspace twice at the end.
    try cursor.deleteBackward(&buffer);
    try cursor.deleteBackward(&buffer);
    model.shrinkRetainingCapacity(model.items.len - 2); // "líne\n" -> remove '\n' then 'e'

    try buffer.rope.validate();
    const out = try buffer.toOwnedSlice(std.testing.allocator);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings(model.items, out);
}

fn expectBufferText(buffer: Buffer, expected: []const u8) !void {
    const out = try buffer.toOwnedSlice(std.testing.allocator);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings(expected, out);
}

test "undo and redo a single edit" {
    var buffer = try Buffer.initFromText(std.testing.allocator, "hello");
    defer buffer.deinit();

    try buffer.insert(5, " world");
    try expectBufferText(buffer, "hello world");
    try std.testing.expect(buffer.undo_tree.canUndo());

    const undo_offset = try buffer.undo();
    try std.testing.expectEqual(@as(?usize, 5), undo_offset);
    try expectBufferText(buffer, "hello");

    const redo_offset = try buffer.redo();
    try std.testing.expectEqual(@as(?usize, 11), redo_offset);
    try expectBufferText(buffer, "hello world");

    // Nothing left to redo.
    try std.testing.expectEqual(@as(?usize, null), try buffer.redo());
}

test "insert-mode typing group is one undo unit" {
    var buffer = try Buffer.init(std.testing.allocator);
    defer buffer.deinit();

    var cursor = Cursor.init(buffer);
    buffer.beginUndoGroup(cursor.offset);
    for ("hello") |ch| try cursor.insertText(&buffer, &.{ch});
    buffer.endUndoGroup(cursor.offset);

    try expectBufferText(buffer, "hello");
    // Coalesced into a single edit on a single tree node.
    try std.testing.expectEqual(@as(usize, 1), buffer.undo_tree.root.children.items[0].edits.items.len);

    const off = try buffer.undo();
    try std.testing.expectEqual(@as(?usize, 0), off);
    try expectBufferText(buffer, "");
    _ = try buffer.redo();
    try expectBufferText(buffer, "hello");
}

test "grouped backspaces undo together" {
    var buffer = try Buffer.initFromText(std.testing.allocator, "abcdef");
    defer buffer.deinit();

    var cursor = Cursor.at(buffer, 6);
    buffer.beginUndoGroup(cursor.offset);
    try cursor.deleteBackward(&buffer);
    try cursor.deleteBackward(&buffer);
    try cursor.deleteBackward(&buffer);
    buffer.endUndoGroup(cursor.offset);
    try expectBufferText(buffer, "abc");
    try std.testing.expectEqual(@as(usize, 1), buffer.undo_tree.current.edits.items.len);
    try std.testing.expect(buffer.undo_tree.current.edits.items[0].old_text_reversed);

    const off = try buffer.undo();
    try std.testing.expectEqual(@as(?usize, 6), off);
    try expectBufferText(buffer, "abcdef");
}

test "unicode backspaces undo without byte reversal corruption" {
    var buffer = try Buffer.initFromText(std.testing.allocator, "a🌊b");
    defer buffer.deinit();

    var cursor = Cursor.at(buffer, buffer.byteLen());
    buffer.beginUndoGroup(cursor.offset);
    try cursor.deleteBackward(&buffer);
    try cursor.deleteBackward(&buffer);
    buffer.endUndoGroup(cursor.offset);
    try expectBufferText(buffer, "a");
    try std.testing.expectEqual(@as(usize, 2), buffer.undo_tree.current.edits.items.len);

    const off = try buffer.undo();
    try std.testing.expectEqual(@as(?usize, 6), off);
    try expectBufferText(buffer, "a🌊b");
}

test "new edit after undo creates a branch instead of discarding" {
    var buffer = try Buffer.initFromText(std.testing.allocator, "a");
    defer buffer.deinit();

    try buffer.insert(1, "b"); // "ab"  (root -> n1)
    try buffer.insert(2, "c"); // "abc" (n1 -> n2)
    _ = try buffer.undo(); // "ab"  (current = n1)
    _ = try buffer.undo(); // "a"   (current = root)
    try buffer.insert(1, "X"); // "aX"  (root -> n3, new branch)

    try expectBufferText(buffer, "aX");
    // The tree preserves both branches under the root.
    try std.testing.expectEqual(@as(usize, 2), buffer.undo_tree.root.children.items.len);
    // A plain redo now follows the newest branch ("aX" is current, no redo).
    try std.testing.expect(!buffer.undo_tree.canRedo());
}

test "deep history is stack-safe for undo, redo and jump" {
    var buffer = try Buffer.init(std.testing.allocator);
    defer buffer.deinit();

    // A long linear chain that would overflow a recursive traversal.
    const depth = 5000;
    for (0..depth) |_| try buffer.insert(buffer.byteLen(), "x");
    try std.testing.expectEqual(@as(usize, depth), buffer.byteLen());

    const tip_seq = buffer.undo_tree.current.seq;

    // Jump straight to the root state, then back to the tip.
    _ = try buffer.jumpToState(0);
    try std.testing.expectEqual(@as(usize, 0), buffer.byteLen());
    _ = try buffer.jumpToState(tip_seq);
    try std.testing.expectEqual(@as(usize, depth), buffer.byteLen());

    // Undo and redo the whole chain step by step.
    var n: usize = 0;
    while (n < depth) : (n += 1) _ = try buffer.undo();
    try std.testing.expectEqual(@as(usize, 0), buffer.byteLen());
    n = 0;
    while (n < depth) : (n += 1) _ = try buffer.redo();
    try std.testing.expectEqual(@as(usize, depth), buffer.byteLen());
}

test "jump to any recorded state across branches" {
    var buffer = try Buffer.initFromText(std.testing.allocator, "");
    defer buffer.deinit();

    try buffer.insert(0, "a"); // seq 1: "a"
    const seq_a = buffer.undo_tree.current.seq;
    try buffer.insert(1, "b"); // seq 2: "ab"
    const seq_ab = buffer.undo_tree.current.seq;

    _ = try buffer.undo(); // back to "a"
    try buffer.insert(1, "Z"); // seq 3: "aZ" (branch)
    const seq_az = buffer.undo_tree.current.seq;

    // Jump straight to the "ab" state on the other branch.
    const at_ab = try buffer.jumpToState(seq_ab);
    try std.testing.expectEqual(@as(?usize, 2), at_ab);
    try expectBufferText(buffer, "ab");

    // Jump back to the branch tip we created.
    _ = try buffer.jumpToState(seq_az);
    try expectBufferText(buffer, "aZ");

    // Jump to the earliest edit.
    _ = try buffer.jumpToState(seq_a);
    try expectBufferText(buffer, "a");

    // Root state (empty file baseline).
    _ = try buffer.jumpToState(0);
    try expectBufferText(buffer, "");
}

test "undo restores caret and cursor re-syncs" {
    var buffer = try Buffer.initFromText(std.testing.allocator, "hello world");
    defer buffer.deinit();

    var cursor = Cursor.at(buffer, 11);
    buffer.beginUndoGroup(cursor.offset);
    try cursor.deleteBackward(&buffer);
    try cursor.deleteBackward(&buffer);
    buffer.endUndoGroup(cursor.offset);
    try expectBufferText(buffer, "hello wor");

    const restore = (try buffer.undo()).?;
    try cursor.setOffset(buffer, restore);
    try cursor.sync(buffer);
    try std.testing.expectEqual(@as(usize, 11), cursor.offset);
    try expectBufferText(buffer, "hello world");
}

test "undo redo round-trips against a model" {
    var buffer = try Buffer.init(std.testing.allocator);
    defer buffer.deinit();

    const snapshots = [_][]const u8{ "", "one", "one two", "onetwo", "onetwo three" };

    try buffer.insert(0, "one"); // -> "one"
    try buffer.insert(3, " two"); // -> "one two"
    try buffer.delete(3, 1); // -> "onetwo"
    try buffer.insert(6, " three"); // -> "onetwo three"
    try expectBufferText(buffer, snapshots[4]);

    // Undo all the way back.
    var i: usize = 4;
    while (i > 0) : (i -= 1) {
        try expectBufferText(buffer, snapshots[i]);
        _ = try buffer.undo();
    }
    try expectBufferText(buffer, snapshots[0]);

    // Redo all the way forward.
    for (1..5) |j| {
        _ = try buffer.redo();
        try expectBufferText(buffer, snapshots[j]);
    }
}
