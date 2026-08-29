const std = @import("std");
const Buffer = @import("buffer.zig").Buffer;
const Cursor = @import("buffer.zig").Cursor;
const Selection = @import("buffer.zig").Selection;
const Key = @import("input.zig").Key;

pub const Action = enum {
    none,
    enter_insert,
    enter_visual,
    enter_visual_line,
    exit_visual,
};

const Operator = enum {
    delete,
    change,
    yank,
};

const Pending = struct {
    operator: Operator,
    count: usize,
};

const Register = struct {
    text: std.ArrayListUnmanaged(u8) = .empty,
    linewise: bool = false,

    fn deinit(self: *Register, allocator: std.mem.Allocator) void {
        self.text.deinit(allocator);
        self.* = undefined;
    }

    fn setFromRange(self: *Register, allocator: std.mem.Allocator, buffer: Buffer, range: Buffer.ByteRange, linewise: bool) !void {
        const end = @min(range.end, buffer.byteLen());
        const start = @min(range.start, end);
        self.text.clearRetainingCapacity();
        try self.text.resize(allocator, end - start);
        buffer.copyRange(self.text.items, start);
        self.linewise = linewise;
    }

    fn isEmpty(self: Register) bool {
        return self.text.items.len == 0;
    }
};

pub const State = struct {
    allocator: std.mem.Allocator,
    pending: ?Pending = null,
    pending_g_count: ?usize = null,
    pending_replace_count: ?usize = null,
    count: usize = 0,
    yank_register: Register = .{},
    delete_register: Register = .{},

    pub fn init(allocator: std.mem.Allocator) State {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *State) void {
        self.yank_register.deinit(self.allocator);
        self.delete_register.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn pasteText(self: State) []const u8 {
        return self.activePasteRegister().text.items;
    }

    pub fn cancel(self: *State) void {
        self.resetCommand();
    }

    pub fn handleNormal(self: *State, buffer: *Buffer, cursor: *Cursor, key: Key) !Action {
        switch (key) {
            .ctrl => |ch| switch (ch) {
                'u' => return self.applyMotion(buffer, cursor, .half_page_up),
                'd' => return self.applyMotion(buffer, cursor, .half_page_down),
                'k' => return self.applyMotion(buffer, cursor, .paragraph_backward),
                'j' => return self.applyMotion(buffer, cursor, .paragraph_forward),
                'p' => return self.applyMotion(buffer, cursor, .paragraph_backward),
                'n' => return self.applyMotion(buffer, cursor, .paragraph_forward),
                else => {
                    self.resetCommand();
                    return .none;
                },
            },
            .ctrl_arrow_up => return self.applyMotion(buffer, cursor, .paragraph_backward),
            .ctrl_arrow_down => return self.applyMotion(buffer, cursor, .paragraph_forward),
            .page_up => return self.applyMotion(buffer, cursor, .half_page_up),
            .page_down => return self.applyMotion(buffer, cursor, .half_page_down),
            .arrow_left => return self.applyMotion(buffer, cursor, .left),
            .arrow_down => return self.applyMotion(buffer, cursor, .down),
            .arrow_up => return self.applyMotion(buffer, cursor, .up),
            .arrow_right => return self.applyMotion(buffer, cursor, .right),
            .home => return self.applyMotion(buffer, cursor, .line_start),
            .end => return self.applyMotion(buffer, cursor, .line_end),
            .char => |ch| return self.handleChar(buffer, cursor, ch),
            else => {
                self.resetCommand();
                return .none;
            },
        }
    }

    fn handleChar(self: *State, buffer: *Buffer, cursor: *Cursor, ch: u21) !Action {
        if (self.pending_replace_count) |repeat| return self.replaceCharacters(buffer, cursor, ch, repeat);

        if (self.pending_g_count) |line_count| {
            self.pending_g_count = null;
            if (ch == 'g') return self.applyLineMotion(buffer, cursor, if (line_count == 0) 0 else line_count - 1);
            self.resetCommand();
            return .none;
        }

        if (ch >= '1' and ch <= '9') {
            self.count = self.count * 10 + @as(usize, @intCast(ch - '0'));
            return .none;
        }
        if (ch == '0' and (self.count != 0 or self.pending != null)) {
            self.count *= 10;
            return .none;
        }

        switch (ch) {
            'i' => {
                self.resetCommand();
                return .enter_insert;
            },
            'v' => {
                self.resetCommand();
                return .enter_visual;
            },
            'V' => {
                self.resetCommand();
                return .enter_visual_line;
            },
            'a' => return self.enterAppend(buffer, cursor),
            'A' => return self.enterLineEnd(buffer.*, cursor),
            'I' => return self.enterFirstNonBlank(buffer.*, cursor),
            'o' => return self.openLine(buffer, cursor, .below),
            'O' => return self.openLine(buffer, cursor, .above),
            'h' => return self.applyMotion(buffer, cursor, .left),
            'j' => return self.applyMotion(buffer, cursor, .down),
            'k' => return self.applyMotion(buffer, cursor, .up),
            'l' => return self.applyMotion(buffer, cursor, .right),
            '0' => return self.applyMotion(buffer, cursor, .line_start),
            '$' => return self.applyMotion(buffer, cursor, .line_end),
            'w' => return self.applyMotion(buffer, cursor, .word_forward),
            'b' => return self.applyMotion(buffer, cursor, .word_backward),
            'e' => return self.applyMotion(buffer, cursor, .word_end),
            '{' => return self.applyMotion(buffer, cursor, .paragraph_backward),
            '}' => return self.applyMotion(buffer, cursor, .paragraph_forward),
            'g' => {
                self.pending_g_count = self.count;
                self.count = 0;
                return .none;
            },
            'G' => return self.applyLineMotion(buffer, cursor, if (self.count == 0) buffer.lineCount() - 1 else self.count - 1),
            'x' => return self.deleteCharacters(buffer, cursor),
            's' => return self.substituteCharacters(buffer, cursor),
            'S' => return self.applyLineOperator(buffer, cursor, .change, commandCount(self.count)),
            'r' => {
                self.pending_replace_count = commandCount(self.count);
                self.count = 0;
                return .none;
            },
            'J' => return self.joinLines(buffer, cursor),
            '~' => return self.toggleCase(buffer, cursor),
            'D' => return self.applySuffixOperator(buffer, cursor, .delete),
            'C' => return self.applySuffixOperator(buffer, cursor, .change),
            'Y' => return self.applyLineOperator(buffer, cursor, .yank, commandCount(self.count)),
            'd' => return self.handleOperator(buffer, cursor, .delete),
            'c' => return self.handleOperator(buffer, cursor, .change),
            'y' => return self.handleOperator(buffer, cursor, .yank),
            'p' => return self.paste(buffer, cursor, .after),
            'P' => return self.paste(buffer, cursor, .before),
            else => {
                self.resetCommand();
                return .none;
            },
        }
    }

    pub fn handleVisual(self: *State, buffer: *Buffer, cursor: *Cursor, selection: *Selection, linewise: bool, key: Key) !Action {
        switch (key) {
            .escape => {
                self.resetCommand();
                return .exit_visual;
            },
            .ctrl => |ch| switch (ch) {
                'u' => return self.applyVisualMotion(buffer.*, cursor, selection, .half_page_up),
                'd' => return self.applyVisualMotion(buffer.*, cursor, selection, .half_page_down),
                'k', 'p' => return self.applyVisualMotion(buffer.*, cursor, selection, .paragraph_backward),
                'j', 'n' => return self.applyVisualMotion(buffer.*, cursor, selection, .paragraph_forward),
                else => return .none,
            },
            .ctrl_arrow_up => return self.applyVisualMotion(buffer.*, cursor, selection, .paragraph_backward),
            .ctrl_arrow_down => return self.applyVisualMotion(buffer.*, cursor, selection, .paragraph_forward),
            .page_up => return self.applyVisualMotion(buffer.*, cursor, selection, .half_page_up),
            .page_down => return self.applyVisualMotion(buffer.*, cursor, selection, .half_page_down),
            .arrow_left => return self.applyVisualMotion(buffer.*, cursor, selection, .left),
            .arrow_down => return self.applyVisualMotion(buffer.*, cursor, selection, .down),
            .arrow_up => return self.applyVisualMotion(buffer.*, cursor, selection, .up),
            .arrow_right => return self.applyVisualMotion(buffer.*, cursor, selection, .right),
            .home => return self.applyVisualMotion(buffer.*, cursor, selection, .line_start),
            .end => return self.applyVisualMotion(buffer.*, cursor, selection, .line_end),
            .char => |ch| switch (ch) {
                'v' => return .exit_visual,
                'V' => return if (linewise) .exit_visual else .enter_visual_line,
                'o', 'O' => return self.swapVisualEnds(buffer.*, cursor, selection),
                'h' => return self.applyVisualMotion(buffer.*, cursor, selection, .left),
                'j' => return self.applyVisualMotion(buffer.*, cursor, selection, .down),
                'k' => return self.applyVisualMotion(buffer.*, cursor, selection, .up),
                'J' => return self.moveVisualLines(buffer, cursor, selection, .down),
                'K' => return self.moveVisualLines(buffer, cursor, selection, .up),
                'l' => return self.applyVisualMotion(buffer.*, cursor, selection, .right),
                '0' => return self.applyVisualMotion(buffer.*, cursor, selection, .line_start),
                '$' => return self.applyVisualMotion(buffer.*, cursor, selection, .line_end),
                'w' => return self.applyVisualMotion(buffer.*, cursor, selection, .word_forward),
                'b' => return self.applyVisualMotion(buffer.*, cursor, selection, .word_backward),
                'e' => return self.applyVisualMotion(buffer.*, cursor, selection, .word_end),
                '{' => return self.applyVisualMotion(buffer.*, cursor, selection, .paragraph_backward),
                '}' => return self.applyVisualMotion(buffer.*, cursor, selection, .paragraph_forward),
                'd', 'x' => return self.applyVisualOperator(buffer, cursor, selection.*, .delete, linewise),
                'c', 's' => return self.applyVisualOperator(buffer, cursor, selection.*, .change, linewise),
                'y' => return self.applyVisualOperator(buffer, cursor, selection.*, .yank, linewise),
                'p', 'P' => return self.pasteOverVisual(buffer, cursor, selection.*, linewise),
                else => return .none,
            },
            else => return .none,
        }
    }

    fn applyVisualMotion(self: *State, buffer: Buffer, cursor: *Cursor, selection: *Selection, motion: Motion) !Action {
        const repeat = commandCount(self.count);
        self.resetCommand();
        try moveCursor(buffer, cursor, motion, repeat);
        selection.setHead(buffer, cursor.offset);
        return .none;
    }

    fn swapVisualEnds(self: *State, buffer: Buffer, cursor: *Cursor, selection: *Selection) !Action {
        self.resetCommand();
        const old_anchor = selection.anchor;
        selection.anchor = selection.head;
        selection.head = old_anchor;
        try cursor.setOffset(buffer, selection.head);
        return .none;
    }

    fn applyVisualOperator(self: *State, buffer: *Buffer, cursor: *Cursor, selection: Selection, operator: Operator, linewise: bool) !Action {
        self.resetCommand();
        const range = try selectedRange(buffer.*, selection, linewise);
        if (range.end <= range.start) return .exit_visual;
        try self.setRegister(operator, buffer.*, range, linewise);
        if (operator == .yank) return .exit_visual;
        try buffer.delete(range.start, range.end - range.start);
        try cursor.setOffset(buffer.*, range.start);
        return if (operator == .change) .enter_insert else .exit_visual;
    }

    fn pasteOverVisual(self: *State, buffer: *Buffer, cursor: *Cursor, selection: Selection, linewise: bool) !Action {
        self.resetCommand();
        const register = self.activePasteRegister();
        if (register.isEmpty()) return .exit_visual;
        const range = try selectedRange(buffer.*, selection, linewise);
        if (range.end <= range.start) return .exit_visual;
        if (!self.yank_register.isEmpty()) try self.delete_register.setFromRange(self.allocator, buffer.*, range, linewise);
        try buffer.replace(range.start, range.end - range.start, register.text.items);
        try cursor.setOffset(buffer.*, range.start);
        return .exit_visual;
    }

    fn moveVisualLines(self: *State, buffer: *Buffer, cursor: *Cursor, selection: *Selection, direction: VerticalDirection) !Action {
        self.resetCommand();
        const original_anchor = selection.anchor;
        const original_head = selection.head;
        const anchor_line = buffer.lineAt(original_anchor);
        const head_line = buffer.lineAt(original_head);
        const start_line = @min(anchor_line, head_line);
        const end_line = @max(anchor_line, head_line);
        const start = buffer.byteOffsetForLine(start_line);
        const end = if (end_line + 1 >= buffer.lineCount()) buffer.byteLen() else buffer.byteOffsetForLine(end_line + 1);

        switch (direction) {
            .up => {
                if (start_line == 0) return .none;
                const other_start = buffer.byteOffsetForLine(start_line - 1);
                try self.swapLineBlocks(buffer, other_start, start, end);
                const delta = start - other_start;
                selection.anchor = original_anchor - delta;
                selection.head = original_head - delta;
                try cursor.setOffset(buffer.*, selection.head);
            },
            .down => {
                if (end_line + 1 >= buffer.lineCount()) return .none;
                const other_end = if (end_line + 2 >= buffer.lineCount()) buffer.byteLen() else buffer.byteOffsetForLine(end_line + 2);
                try self.swapLineBlocks(buffer, start, end, other_end);
                const delta = other_end - end;
                selection.anchor = original_anchor + delta;
                selection.head = original_head + delta;
                try cursor.setOffset(buffer.*, selection.head);
            },
        }
        return .none;
    }

    fn swapLineBlocks(self: *State, buffer: *Buffer, first_start: usize, second_start: usize, second_end: usize) !void {
        const first_len = second_start - first_start;
        const second_len = second_end - second_start;
        var replacement: std.ArrayListUnmanaged(u8) = .empty;
        defer replacement.deinit(self.allocator);
        try replacement.resize(self.allocator, first_len + second_len);
        buffer.copyRange(replacement.items[0..second_len], second_start);
        buffer.copyRange(replacement.items[second_len..], first_start);
        try buffer.replace(first_start, second_end - first_start, replacement.items);
    }

    fn handleOperator(self: *State, buffer: *Buffer, cursor: *Cursor, operator: Operator) !Action {
        if (self.pending) |pending| {
            if (pending.operator == operator) {
                return self.applyLineOperator(buffer, cursor, operator, pending.count * commandCount(self.count));
            }
            self.resetCommand();
            return .none;
        }

        self.pending = .{ .operator = operator, .count = commandCount(self.count) };
        self.count = 0;
        return .none;
    }

    fn applyMotion(self: *State, buffer: *Buffer, cursor: *Cursor, motion: Motion) !Action {
        if (self.pending) |pending| {
            const repeat = pending.count * commandCount(self.count);
            const start = cursor.offset;
            const end = try motionTarget(buffer.*, start, motion, repeat);
            const range = rangeForMotion(start, end, motion);
            return self.applyRangeOperator(buffer, cursor, pending.operator, range);
        }

        const repeat = commandCount(self.count);
        self.resetCommand();
        try moveCursor(buffer.*, cursor, motion, repeat);
        return .none;
    }

    fn deleteCharacters(self: *State, buffer: *Buffer, cursor: *Cursor) !Action {
        const repeat = commandCount(self.count);
        self.resetCommand();

        const start = cursor.offset;
        const end = try motionTarget(buffer.*, start, .right, repeat);
        if (end <= start) return .none;
        try self.setRegister(.delete, buffer.*, .{ .start = start, .end = end }, false);
        try buffer.delete(start, end - start);
        try cursor.setOffset(buffer.*, start);
        return .none;
    }

    fn substituteCharacters(self: *State, buffer: *Buffer, cursor: *Cursor) !Action {
        const repeat = commandCount(self.count);
        self.resetCommand();
        const start = cursor.offset;
        const end = try motionTarget(buffer.*, start, .right, repeat);
        if (end > start) {
            try self.setRegister(.delete, buffer.*, .{ .start = start, .end = end }, false);
            try buffer.delete(start, end - start);
        }
        try cursor.setOffset(buffer.*, start);
        return .enter_insert;
    }

    fn replaceCharacters(self: *State, buffer: *Buffer, cursor: *Cursor, ch: u21, repeat: usize) !Action {
        self.resetCommand();
        if (ch == '\n' or ch == '\r') return .none;
        var bytes: [4]u8 = undefined;
        const len = try std.unicode.utf8Encode(ch, &bytes);
        const start = cursor.offset;
        const end = try motionTarget(buffer.*, start, .right, repeat);
        if (end <= start) return .none;

        if (repeat == 1) {
            try buffer.replace(start, end - start, bytes[0..len]);
        } else {
            var replacement: std.ArrayListUnmanaged(u8) = .empty;
            defer replacement.deinit(self.allocator);
            var n: usize = 0;
            while (n < repeat) : (n += 1) try replacement.appendSlice(self.allocator, bytes[0..len]);
            try buffer.replace(start, end - start, replacement.items);
        }
        try cursor.setOffset(buffer.*, start);
        return .none;
    }

    fn applyLineOperator(self: *State, buffer: *Buffer, cursor: *Cursor, operator: Operator, repeat: usize) !Action {
        self.resetCommand();
        try cursor.sync(buffer.*);
        const line = buffer.lineAt(cursor.offset);
        const end_line = @min(buffer.lineCount(), line + @max(repeat, 1));
        const start = buffer.byteOffsetForLine(line);
        const end = if (operator == .change)
            buffer.lineContentRange(line).end
        else if (end_line >= buffer.lineCount())
            buffer.byteLen()
        else
            buffer.byteOffsetForLine(end_line);
        const range: Buffer.ByteRange = .{ .start = start, .end = end };
        const linewise = operator != .change;
        try self.setRegister(operator, buffer.*, range, linewise);
        if (operator == .yank) return .none;
        if (range.end > range.start) try buffer.delete(range.start, range.end - range.start);
        try cursor.setOffset(buffer.*, range.start);
        return if (operator == .change) .enter_insert else .none;
    }

    fn applySuffixOperator(self: *State, buffer: *Buffer, cursor: *Cursor, operator: Operator) !Action {
        const repeat = commandCount(self.count);
        self.resetCommand();
        try cursor.sync(buffer.*);
        const start = cursor.offset;
        var target = Cursor.at(buffer.*, start);
        try moveCursor(buffer.*, &target, .line_end, repeat);
        const range: Buffer.ByteRange = .{ .start = start, .end = target.offset };
        if (range.end <= range.start) return if (operator == .change) .enter_insert else .none;
        try self.setRegister(operator, buffer.*, range, false);
        try buffer.delete(range.start, range.end - range.start);
        try cursor.setOffset(buffer.*, range.start);
        return if (operator == .change) .enter_insert else .none;
    }

    fn joinLines(self: *State, buffer: *Buffer, cursor: *Cursor) !Action {
        const repeat = commandCount(self.count);
        self.resetCommand();
        var n: usize = 0;
        while (n < repeat) : (n += 1) {
            try cursor.sync(buffer.*);
            const line = buffer.lineAt(cursor.offset);
            if (line + 1 >= buffer.lineCount()) break;
            const line_end = buffer.lineContentRange(line).end;
            var next_start = buffer.byteOffsetForLine(line + 1);
            while (next_start < buffer.byteLen() and isBlank(buffer.byteAt(next_start))) : (next_start += 1) {}
            try buffer.replace(line_end, next_start - line_end, " ");
            try cursor.setOffset(buffer.*, line_end);
        }
        return .none;
    }

    fn toggleCase(self: *State, buffer: *Buffer, cursor: *Cursor) !Action {
        const repeat = commandCount(self.count);
        self.resetCommand();
        try cursor.sync(buffer.*);
        var offset = cursor.offset;
        var n: usize = 0;
        while (n < repeat and offset < buffer.byteLen()) : (n += 1) {
            const byte = buffer.byteAt(offset);
            if (!std.ascii.isAlphabetic(byte)) {
                offset += 1;
                continue;
            }
            const toggled: u8 = if (std.ascii.isLower(byte)) std.ascii.toUpper(byte) else std.ascii.toLower(byte);
            try buffer.replace(offset, 1, &.{toggled});
            offset += 1;
        }
        try cursor.setOffset(buffer.*, offset);
        return .none;
    }

    fn applyRangeOperator(self: *State, buffer: *Buffer, cursor: *Cursor, operator: Operator, range: Buffer.ByteRange) !Action {
        self.resetCommand();
        const clamped = clampRange(buffer.*, range);
        if (clamped.end <= clamped.start) return .none;
        try self.setRegister(operator, buffer.*, clamped, false);
        if (operator == .yank) return .none;
        try buffer.delete(clamped.start, clamped.end - clamped.start);
        try cursor.setOffset(buffer.*, clamped.start);
        return if (operator == .change) .enter_insert else .none;
    }

    fn paste(self: *State, buffer: *Buffer, cursor: *Cursor, position: PastePosition) !Action {
        const repeat = commandCount(self.count);
        self.resetCommand();
        const register = self.activePasteRegister();
        if (register.isEmpty()) return .none;

        const at = try pasteOffset(buffer.*, cursor, register.linewise, position);
        var offset = at;
        var n: usize = 0;
        while (n < repeat) : (n += 1) {
            try buffer.insert(offset, register.text.items);
            offset += register.text.items.len;
        }
        try cursor.setOffset(buffer.*, at);
        return .none;
    }

    fn setRegister(self: *State, operator: Operator, buffer: Buffer, range: Buffer.ByteRange, linewise: bool) !void {
        switch (operator) {
            .yank => try self.yank_register.setFromRange(self.allocator, buffer, range, linewise),
            .delete, .change => try self.delete_register.setFromRange(self.allocator, buffer, range, linewise),
        }
    }

    fn activePasteRegister(self: State) Register {
        return if (!self.yank_register.isEmpty()) self.yank_register else self.delete_register;
    }

    fn enterAppend(self: *State, buffer: *Buffer, cursor: *Cursor) !Action {
        self.resetCommand();
        try cursor.moveRight(buffer.*);
        return .enter_insert;
    }

    fn enterLineEnd(self: *State, buffer: Buffer, cursor: *Cursor) !Action {
        self.resetCommand();
        try cursor.moveToLineEnd(buffer);
        return .enter_insert;
    }

    fn enterFirstNonBlank(self: *State, buffer: Buffer, cursor: *Cursor) !Action {
        self.resetCommand();
        try cursor.sync(buffer);
        const range = buffer.lineContentRange(buffer.lineAt(cursor.offset));
        var offset = range.start;
        while (offset < range.end and isBlank(buffer.byteAt(offset))) : (offset += 1) {}
        try cursor.setOffset(buffer, offset);
        return .enter_insert;
    }

    fn openLine(self: *State, buffer: *Buffer, cursor: *Cursor, position: OpenPosition) !Action {
        self.resetCommand();
        try cursor.sync(buffer.*);
        const line = buffer.lineAt(cursor.offset);
        const at = switch (position) {
            .above => buffer.byteOffsetForLine(line),
            .below => blk: {
                const next = line + 1;
                break :blk if (next >= buffer.lineCount()) buffer.byteLen() else buffer.byteOffsetForLine(next);
            },
        };
        try buffer.insert(at, "\n");
        try cursor.setOffset(buffer.*, at);
        return .enter_insert;
    }

    fn applyLineMotion(self: *State, buffer: *Buffer, cursor: *Cursor, line: usize) !Action {
        if (self.pending) |pending| {
            const target = @min(line, buffer.lineCount() - 1);
            try cursor.sync(buffer.*);
            const current = buffer.lineAt(cursor.offset);
            const start_line = @min(current, target);
            const end_line = @max(current, target);
            const start = buffer.byteOffsetForLine(start_line);
            const end = if (end_line + 1 >= buffer.lineCount()) buffer.byteLen() else buffer.byteOffsetForLine(end_line + 1);
            self.resetCommand();
            const range: Buffer.ByteRange = .{ .start = start, .end = end };
            try self.setRegister(pending.operator, buffer.*, range, true);
            if (pending.operator == .yank) return .none;
            if (range.end > range.start) try buffer.delete(range.start, range.end - range.start);
            try cursor.setOffset(buffer.*, range.start);
            return if (pending.operator == .change) .enter_insert else .none;
        }

        return self.moveToLine(buffer.*, cursor, line);
    }

    fn moveToLine(self: *State, buffer: Buffer, cursor: *Cursor, line: usize) !Action {
        self.resetCommand();
        const target = @min(line, buffer.lineCount() - 1);
        try cursor.setOffset(buffer, buffer.byteOffsetForLine(target));
        return .none;
    }

    fn resetCommand(self: *State) void {
        self.pending = null;
        self.pending_g_count = null;
        self.pending_replace_count = null;
        self.count = 0;
    }
};

const Motion = enum {
    left,
    down,
    up,
    right,
    line_start,
    line_end,
    word_forward,
    word_backward,
    word_end,
    paragraph_forward,
    paragraph_backward,
    half_page_up,
    half_page_down,
};

const PastePosition = enum {
    before,
    after,
};

const OpenPosition = enum {
    above,
    below,
};

fn commandCount(count: usize) usize {
    return if (count == 0) 1 else count;
}

fn moveCursor(buffer: Buffer, cursor: *Cursor, motion: Motion, repeat: usize) !void {
    var n: usize = 0;
    while (n < repeat) : (n += 1) switch (motion) {
        .left => try cursor.moveLeft(buffer),
        .down => try cursor.moveDown(buffer),
        .up => try cursor.moveUp(buffer),
        .right => try cursor.moveRight(buffer),
        .line_start => {
            try cursor.moveToLineStart(buffer);
            return;
        },
        .line_end => {
            try cursor.moveToLineEnd(buffer);
            return;
        },
        .word_forward => try cursor.setOffset(buffer, nextWord(buffer, cursor.offset, 1)),
        .word_backward => try cursor.setOffset(buffer, prevWord(buffer, cursor.offset, 1)),
        .word_end => try cursor.setOffset(buffer, endWord(buffer, cursor.offset, 1)),
        .paragraph_forward => try cursor.setOffset(buffer, nextParagraph(buffer, cursor.offset, 1)),
        .paragraph_backward => try cursor.setOffset(buffer, prevParagraph(buffer, cursor.offset, 1)),
        .half_page_up => try moveLines(buffer, cursor, .up, 12 * repeat),
        .half_page_down => try moveLines(buffer, cursor, .down, 12 * repeat),
    };
}

fn motionTarget(buffer: Buffer, start: usize, motion: Motion, repeat: usize) !usize {
    var cursor = Cursor.at(buffer, start);
    switch (motion) {
        .word_forward => try cursor.setOffset(buffer, nextWord(buffer, cursor.offset, repeat)),
        .word_backward => try cursor.setOffset(buffer, prevWord(buffer, cursor.offset, repeat)),
        .word_end => try cursor.setOffset(buffer, endWord(buffer, cursor.offset, repeat)),
        .paragraph_forward => try cursor.setOffset(buffer, nextParagraph(buffer, cursor.offset, repeat)),
        .paragraph_backward => try cursor.setOffset(buffer, prevParagraph(buffer, cursor.offset, repeat)),
        .half_page_up, .half_page_down => try moveCursor(buffer, &cursor, motion, repeat),
        else => try moveCursor(buffer, &cursor, motion, repeat),
    }
    return cursor.offset;
}

const VerticalDirection = enum { up, down };

fn moveLines(buffer: Buffer, cursor: *Cursor, direction: VerticalDirection, count: usize) !void {
    var n: usize = 0;
    while (n < count) : (n += 1) switch (direction) {
        .up => try cursor.moveUp(buffer),
        .down => try cursor.moveDown(buffer),
    };
}

fn rangeForMotion(start: usize, end: usize, motion: Motion) Buffer.ByteRange {
    if (motion == .line_end and end >= start) return .{ .start = start, .end = end };
    if (motion == .word_end and end >= start) return .{ .start = start, .end = end + 1 };
    return .{ .start = @min(start, end), .end = @max(start, end) };
}

pub fn selectedRange(buffer: Buffer, selection: Selection, linewise: bool) !Buffer.ByteRange {
    if (linewise) {
        const anchor_line = buffer.lineAt(selection.anchor);
        const head_line = buffer.lineAt(selection.head);
        const start_line = @min(anchor_line, head_line);
        const end_line = @max(anchor_line, head_line);
        return .{
            .start = buffer.byteOffsetForLine(start_line),
            .end = if (end_line + 1 >= buffer.lineCount()) buffer.byteLen() else buffer.byteOffsetForLine(end_line + 1),
        };
    }

    const start = @min(selection.anchor, selection.head);
    const max = @max(selection.anchor, selection.head);
    var end_cursor = Cursor.at(buffer, max);
    try end_cursor.moveRight(buffer);
    const end = if (end_cursor.offset == max) @min(max + 1, buffer.byteLen()) else end_cursor.offset;
    return .{ .start = start, .end = end };
}

fn clampRange(buffer: Buffer, range: Buffer.ByteRange) Buffer.ByteRange {
    const end = @min(range.end, buffer.byteLen());
    return .{ .start = @min(range.start, end), .end = end };
}

fn pasteOffset(buffer: Buffer, cursor: *Cursor, linewise: bool, position: PastePosition) !usize {
    try cursor.sync(buffer);
    const line = buffer.lineAt(cursor.offset);
    if (linewise) {
        return switch (position) {
            .before => buffer.byteOffsetForLine(line),
            .after => if (line + 1 >= buffer.lineCount()) buffer.byteLen() else buffer.byteOffsetForLine(line + 1),
        };
    }

    if (position == .before) return cursor.offset;
    var after = Cursor.at(buffer, cursor.offset);
    try after.moveRight(buffer);
    return after.offset;
}

fn nextWord(buffer: Buffer, offset: usize, repeat: usize) usize {
    var at = @min(offset, buffer.byteLen());
    var n: usize = 0;
    while (n < repeat) : (n += 1) {
        if (at >= buffer.byteLen()) return buffer.byteLen();
        at = skipWord(buffer, at);
        at = skipWhitespace(buffer, at);
    }
    return at;
}

fn prevWord(buffer: Buffer, offset: usize, repeat: usize) usize {
    var at = @min(offset, buffer.byteLen());
    var n: usize = 0;
    while (n < repeat) : (n += 1) {
        if (at == 0) return 0;
        at = skipWhitespaceBackward(buffer, at);
        if (at == 0) return 0;
        at = skipWordBackward(buffer, at);
    }
    return at;
}

fn endWord(buffer: Buffer, offset: usize, repeat: usize) usize {
    var at = @min(offset, buffer.byteLen());
    var n: usize = 0;
    while (n < repeat) : (n += 1) {
        if (at >= buffer.byteLen()) return buffer.byteLen();
        if (!std.ascii.isWhitespace(buffer.byteAt(at))) {
            const current = wordClass(buffer.byteAt(at));
            if (at + 1 < buffer.byteLen() and wordClass(buffer.byteAt(at + 1)) == current and buffer.byteAt(at + 1) != '\n') {
                while (at + 1 < buffer.byteLen() and wordClass(buffer.byteAt(at + 1)) == current and buffer.byteAt(at + 1) != '\n') : (at += 1) {}
                continue;
            }
            at += 1;
        }
        at = skipWhitespace(buffer, at);
        if (at >= buffer.byteLen()) return buffer.byteLen();
        const first_word = wordClass(buffer.byteAt(at));
        while (at + 1 < buffer.byteLen() and wordClass(buffer.byteAt(at + 1)) == first_word and buffer.byteAt(at + 1) != '\n') : (at += 1) {}
    }
    return at;
}

fn nextParagraph(buffer: Buffer, offset: usize, repeat: usize) usize {
    var at = @min(offset, buffer.byteLen());
    var n: usize = 0;
    while (n < repeat) : (n += 1) {
        if (at >= buffer.byteLen()) return buffer.byteLen();
        at = findNextBlankLine(buffer, at + 1);
        at = skipBlankLinesForward(buffer, at);
    }
    return at;
}

fn prevParagraph(buffer: Buffer, offset: usize, repeat: usize) usize {
    var at = @min(offset, buffer.byteLen());
    var n: usize = 0;
    while (n < repeat) : (n += 1) {
        if (at == 0) return 0;
        at = skipBlankLinesBackward(buffer, at);
        at = findPrevBlankLine(buffer, at);
    }
    return at;
}

fn findNextBlankLine(buffer: Buffer, offset: usize) usize {
    var line = buffer.lineAt(@min(offset, buffer.byteLen()));
    while (line < buffer.lineCount()) : (line += 1) {
        if (isBlankLine(buffer, line)) return buffer.byteOffsetForLine(line);
    }
    return buffer.byteLen();
}

fn findPrevBlankLine(buffer: Buffer, offset: usize) usize {
    var line = buffer.lineAt(offset - 1);
    while (true) {
        if (isBlankLine(buffer, line)) return if (line + 1 >= buffer.lineCount()) buffer.byteLen() else buffer.byteOffsetForLine(line + 1);
        if (line == 0) return 0;
        line -= 1;
    }
}

fn skipBlankLinesForward(buffer: Buffer, offset: usize) usize {
    var line = buffer.lineAt(@min(offset, buffer.byteLen()));
    while (line < buffer.lineCount() and isBlankLine(buffer, line)) : (line += 1) {}
    return if (line >= buffer.lineCount()) buffer.byteLen() else buffer.byteOffsetForLine(line);
}

fn skipBlankLinesBackward(buffer: Buffer, offset: usize) usize {
    if (offset == 0) return 0;
    var line = buffer.lineAt(offset - 1);
    while (line > 0 and isBlankLine(buffer, line)) : (line -= 1) {}
    return buffer.byteOffsetForLine(line);
}

fn isBlankLine(buffer: Buffer, line: usize) bool {
    const range = buffer.lineContentRange(line);
    var offset = range.start;
    while (offset < range.end) : (offset += 1) {
        if (!isBlank(buffer.byteAt(offset))) return false;
    }
    return true;
}

fn skipWord(buffer: Buffer, offset: usize) usize {
    var at = offset;
    if (at >= buffer.byteLen()) return at;
    const first_word = wordClass(buffer.byteAt(at));
    while (at < buffer.byteLen() and wordClass(buffer.byteAt(at)) == first_word and buffer.byteAt(at) != '\n') : (at += 1) {}
    return at;
}

fn skipWhitespace(buffer: Buffer, offset: usize) usize {
    var at = offset;
    while (at < buffer.byteLen() and std.ascii.isWhitespace(buffer.byteAt(at))) : (at += 1) {}
    return at;
}

fn skipWhitespaceBackward(buffer: Buffer, offset: usize) usize {
    var at = offset;
    while (at > 0 and std.ascii.isWhitespace(buffer.byteAt(at - 1))) : (at -= 1) {}
    return at;
}

fn skipWordBackward(buffer: Buffer, offset: usize) usize {
    var at = offset;
    if (at == 0) return 0;
    const first_word = wordClass(buffer.byteAt(at - 1));
    while (at > 0 and wordClass(buffer.byteAt(at - 1)) == first_word and buffer.byteAt(at - 1) != '\n') : (at -= 1) {}
    return at;
}

fn wordClass(byte: u8) enum { whitespace, word, punctuation } {
    if (std.ascii.isWhitespace(byte)) return .whitespace;
    if (std.ascii.isAlphanumeric(byte) or byte == '_') return .word;
    return .punctuation;
}

fn isBlank(byte: u8) bool {
    return byte == ' ' or byte == '\t';
}

test "vim normal motions accept counts" {
    var buffer = try Buffer.initFromText(std.testing.allocator, "abcd\nef");
    defer buffer.deinit();
    var cursor = Cursor.init(buffer);
    var vim = State.init(std.testing.allocator);
    defer vim.deinit();

    _ = try vim.handleNormal(&buffer, &cursor, .{ .char = '3' });
    _ = try vim.handleNormal(&buffer, &cursor, .{ .char = 'l' });
    try std.testing.expectEqual(@as(usize, 3), cursor.offset);
    _ = try vim.handleNormal(&buffer, &cursor, .{ .char = '0' });
    try std.testing.expectEqual(@as(usize, 0), cursor.offset);
}

test "vim deletes word and yanks deleted text" {
    var buffer = try Buffer.initFromText(std.testing.allocator, "one two three");
    defer buffer.deinit();
    var cursor = Cursor.init(buffer);
    var vim = State.init(std.testing.allocator);
    defer vim.deinit();

    _ = try vim.handleNormal(&buffer, &cursor, .{ .char = 'd' });
    _ = try vim.handleNormal(&buffer, &cursor, .{ .char = 'w' });

    const text = try buffer.toOwnedSlice(std.testing.allocator);
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("two three", text);
    try std.testing.expectEqualStrings("one ", vim.delete_register.text.items);
}

test "vim line operators delete change and yank" {
    var buffer = try Buffer.initFromText(std.testing.allocator, "one\ntwo\nthree");
    defer buffer.deinit();
    var cursor = Cursor.init(buffer);
    var vim = State.init(std.testing.allocator);
    defer vim.deinit();

    _ = try vim.handleNormal(&buffer, &cursor, .{ .char = '2' });
    _ = try vim.handleNormal(&buffer, &cursor, .{ .char = 'y' });
    _ = try vim.handleNormal(&buffer, &cursor, .{ .char = 'y' });
    try std.testing.expectEqualStrings("one\ntwo\n", vim.yank_register.text.items);

    _ = try vim.handleNormal(&buffer, &cursor, .{ .char = 'd' });
    _ = try vim.handleNormal(&buffer, &cursor, .{ .char = 'd' });
    const after_delete = try buffer.toOwnedSlice(std.testing.allocator);
    defer std.testing.allocator.free(after_delete);
    try std.testing.expectEqualStrings("two\nthree", after_delete);

    const action = try vim.handleNormal(&buffer, &cursor, .{ .char = 'c' });
    try std.testing.expectEqual(Action.none, action);
    try std.testing.expectEqual(Action.enter_insert, try vim.handleNormal(&buffer, &cursor, .{ .char = 'c' }));
    const after_change = try buffer.toOwnedSlice(std.testing.allocator);
    defer std.testing.allocator.free(after_change);
    try std.testing.expectEqualStrings("\nthree", after_change);
}

test "vim delete does not clobber stable yank paste register" {
    var buffer = try Buffer.initFromText(std.testing.allocator, "copy\ntrash\nend");
    defer buffer.deinit();
    var cursor = Cursor.init(buffer);
    var vim = State.init(std.testing.allocator);
    defer vim.deinit();

    _ = try vim.handleNormal(&buffer, &cursor, .{ .char = 'y' });
    _ = try vim.handleNormal(&buffer, &cursor, .{ .char = 'y' });
    try std.testing.expectEqualStrings("copy\n", vim.pasteText());

    try cursor.moveDown(buffer);
    _ = try vim.handleNormal(&buffer, &cursor, .{ .char = 'd' });
    _ = try vim.handleNormal(&buffer, &cursor, .{ .char = 'd' });
    try std.testing.expectEqualStrings("copy\n", vim.pasteText());

    _ = try vim.handleNormal(&buffer, &cursor, .{ .char = 'p' });
    _ = try vim.handleNormal(&buffer, &cursor, .{ .char = 'p' });

    const text = try buffer.toOwnedSlice(std.testing.allocator);
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("copy\nendcopy\ncopy\n", text);
}

test "vim paste falls back to delete register when no yank exists" {
    var buffer = try Buffer.initFromText(std.testing.allocator, "one\ntwo");
    defer buffer.deinit();
    var cursor = Cursor.init(buffer);
    var vim = State.init(std.testing.allocator);
    defer vim.deinit();

    _ = try vim.handleNormal(&buffer, &cursor, .{ .char = 'd' });
    _ = try vim.handleNormal(&buffer, &cursor, .{ .char = 'd' });
    _ = try vim.handleNormal(&buffer, &cursor, .{ .char = 'p' });

    const text = try buffer.toOwnedSlice(std.testing.allocator);
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("twoone\n", text);
}

test "vim word backward and end motions" {
    var buffer = try Buffer.initFromText(std.testing.allocator, "one two three");
    defer buffer.deinit();
    var cursor = Cursor.init(buffer);
    var vim = State.init(std.testing.allocator);
    defer vim.deinit();

    _ = try vim.handleNormal(&buffer, &cursor, .{ .char = 'e' });
    try std.testing.expectEqual(@as(usize, 2), cursor.offset);
    _ = try vim.handleNormal(&buffer, &cursor, .{ .char = 'e' });
    try std.testing.expectEqual(@as(usize, 6), cursor.offset);
    _ = try vim.handleNormal(&buffer, &cursor, .{ .char = 'b' });
    try std.testing.expectEqual(@as(usize, 4), cursor.offset);
}

test "vim gg and G line jumps" {
    var buffer = try Buffer.initFromText(std.testing.allocator, "one\ntwo\nthree\nfour");
    defer buffer.deinit();
    var cursor = Cursor.init(buffer);
    var vim = State.init(std.testing.allocator);
    defer vim.deinit();

    _ = try vim.handleNormal(&buffer, &cursor, .{ .char = 'G' });
    try std.testing.expectEqual(@as(usize, 14), cursor.offset);
    _ = try vim.handleNormal(&buffer, &cursor, .{ .char = 'g' });
    _ = try vim.handleNormal(&buffer, &cursor, .{ .char = 'g' });
    try std.testing.expectEqual(@as(usize, 0), cursor.offset);
    _ = try vim.handleNormal(&buffer, &cursor, .{ .char = '3' });
    _ = try vim.handleNormal(&buffer, &cursor, .{ .char = 'G' });
    try std.testing.expectEqual(@as(usize, 8), cursor.offset);
}

test "vim suffix operators D C and Y" {
    var delete_buffer = try Buffer.initFromText(std.testing.allocator, "one two\nthree four");
    defer delete_buffer.deinit();
    var delete_cursor = Cursor.init(delete_buffer);
    var delete_vim = State.init(std.testing.allocator);
    defer delete_vim.deinit();

    _ = try delete_vim.handleNormal(&delete_buffer, &delete_cursor, .{ .char = 'w' });
    _ = try delete_vim.handleNormal(&delete_buffer, &delete_cursor, .{ .char = 'D' });
    const after_delete = try delete_buffer.toOwnedSlice(std.testing.allocator);
    defer std.testing.allocator.free(after_delete);
    try std.testing.expectEqualStrings("one \nthree four", after_delete);

    var change_buffer = try Buffer.initFromText(std.testing.allocator, "one two\nthree four");
    defer change_buffer.deinit();
    var change_cursor = Cursor.at(change_buffer, 8);
    var change_vim = State.init(std.testing.allocator);
    defer change_vim.deinit();

    try std.testing.expectEqual(Action.enter_insert, try change_vim.handleNormal(&change_buffer, &change_cursor, .{ .char = 'C' }));
    const after_change = try change_buffer.toOwnedSlice(std.testing.allocator);
    defer std.testing.allocator.free(after_change);
    try std.testing.expectEqualStrings("one two\n", after_change);

    var yank_buffer = try Buffer.initFromText(std.testing.allocator, "one\ntwo\nthree");
    defer yank_buffer.deinit();
    var yank_cursor = Cursor.init(yank_buffer);
    var yank_vim = State.init(std.testing.allocator);
    defer yank_vim.deinit();

    _ = try yank_vim.handleNormal(&yank_buffer, &yank_cursor, .{ .char = 'Y' });
    try std.testing.expectEqualStrings("one\n", yank_vim.yank_register.text.items);
}

test "vim line jumps act as linewise operator motions" {
    var buffer = try Buffer.initFromText(std.testing.allocator, "one\ntwo\nthree\nfour");
    defer buffer.deinit();
    var cursor = Cursor.init(buffer);
    var vim = State.init(std.testing.allocator);
    defer vim.deinit();

    _ = try vim.handleNormal(&buffer, &cursor, .{ .char = '3' });
    _ = try vim.handleNormal(&buffer, &cursor, .{ .char = 'G' });
    _ = try vim.handleNormal(&buffer, &cursor, .{ .char = 'd' });
    _ = try vim.handleNormal(&buffer, &cursor, .{ .char = 'g' });
    _ = try vim.handleNormal(&buffer, &cursor, .{ .char = 'g' });

    const text = try buffer.toOwnedSlice(std.testing.allocator);
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("four", text);
    try std.testing.expectEqualStrings("one\ntwo\nthree\n", vim.delete_register.text.items);
}

test "vim append and line insert transitions place cursor" {
    var buffer = try Buffer.initFromText(std.testing.allocator, "  one\ntwo");
    defer buffer.deinit();
    var cursor = Cursor.init(buffer);
    var vim = State.init(std.testing.allocator);
    defer vim.deinit();

    try std.testing.expectEqual(Action.enter_insert, try vim.handleNormal(&buffer, &cursor, .{ .char = 'a' }));
    try std.testing.expectEqual(@as(usize, 1), cursor.offset);

    try cursor.setOffset(buffer, 0);
    try std.testing.expectEqual(Action.enter_insert, try vim.handleNormal(&buffer, &cursor, .{ .char = 'A' }));
    try std.testing.expectEqual(@as(usize, 5), cursor.offset);

    try std.testing.expectEqual(Action.enter_insert, try vim.handleNormal(&buffer, &cursor, .{ .char = 'I' }));
    try std.testing.expectEqual(@as(usize, 2), cursor.offset);
}

test "vim open line commands insert blank lines" {
    var buffer = try Buffer.initFromText(std.testing.allocator, "one\ntwo");
    defer buffer.deinit();
    var cursor = Cursor.init(buffer);
    var vim = State.init(std.testing.allocator);
    defer vim.deinit();

    try std.testing.expectEqual(Action.enter_insert, try vim.handleNormal(&buffer, &cursor, .{ .char = 'o' }));
    try std.testing.expectEqual(@as(usize, 4), cursor.offset);
    const after_below = try buffer.toOwnedSlice(std.testing.allocator);
    defer std.testing.allocator.free(after_below);
    try std.testing.expectEqualStrings("one\n\ntwo", after_below);

    try cursor.setOffset(buffer, buffer.byteLen());
    try std.testing.expectEqual(Action.enter_insert, try vim.handleNormal(&buffer, &cursor, .{ .char = 'O' }));
    try std.testing.expectEqual(@as(usize, 5), cursor.offset);
    const after_above = try buffer.toOwnedSlice(std.testing.allocator);
    defer std.testing.allocator.free(after_above);
    try std.testing.expectEqualStrings("one\n\n\ntwo", after_above);
}

test "vim fast paragraph and half page movements" {
    var buffer = try Buffer.initFromText(std.testing.allocator, "one\n\ntwo\nthree\n\nfour\n");
    defer buffer.deinit();
    var cursor = Cursor.init(buffer);
    var vim = State.init(std.testing.allocator);
    defer vim.deinit();

    _ = try vim.handleNormal(&buffer, &cursor, .{ .char = '}' });
    try std.testing.expectEqual(@as(usize, 5), cursor.offset);
    _ = try vim.handleNormal(&buffer, &cursor, .{ .char = '}' });
    try std.testing.expectEqual(@as(usize, 16), cursor.offset);
    _ = try vim.handleNormal(&buffer, &cursor, .{ .char = '{' });
    try std.testing.expectEqual(@as(usize, 5), cursor.offset);

    _ = try vim.handleNormal(&buffer, &cursor, .{ .ctrl = 'n' });
    try std.testing.expectEqual(@as(usize, 16), cursor.offset);
    _ = try vim.handleNormal(&buffer, &cursor, .{ .ctrl = 'p' });
    try std.testing.expectEqual(@as(usize, 5), cursor.offset);

    _ = try vim.handleNormal(&buffer, &cursor, .{ .ctrl = 'd' });
    try std.testing.expectEqual(@as(usize, buffer.byteOffsetForLine(buffer.lineCount() - 1)), cursor.offset);
    _ = try vim.handleNormal(&buffer, &cursor, .page_up);
    try std.testing.expectEqual(@as(usize, 0), cursor.offset);
}

test "vim substitute replace join and toggle commands" {
    var buffer = try Buffer.initFromText(std.testing.allocator, "abc\ndef");
    defer buffer.deinit();
    var cursor = Cursor.init(buffer);
    var vim = State.init(std.testing.allocator);
    defer vim.deinit();

    try std.testing.expectEqual(Action.enter_insert, try vim.handleNormal(&buffer, &cursor, .{ .char = 's' }));
    const after_substitute = try buffer.toOwnedSlice(std.testing.allocator);
    defer std.testing.allocator.free(after_substitute);
    try std.testing.expectEqualStrings("bc\ndef", after_substitute);

    try cursor.setOffset(buffer, 0);
    _ = try vim.handleNormal(&buffer, &cursor, .{ .char = 'r' });
    _ = try vim.handleNormal(&buffer, &cursor, .{ .char = 'Z' });
    const after_replace = try buffer.toOwnedSlice(std.testing.allocator);
    defer std.testing.allocator.free(after_replace);
    try std.testing.expectEqualStrings("Zc\ndef", after_replace);

    _ = try vim.handleNormal(&buffer, &cursor, .{ .char = '~' });
    const after_toggle = try buffer.toOwnedSlice(std.testing.allocator);
    defer std.testing.allocator.free(after_toggle);
    try std.testing.expectEqualStrings("zc\ndef", after_toggle);

    try cursor.setOffset(buffer, 0);
    _ = try vim.handleNormal(&buffer, &cursor, .{ .char = 'J' });
    const after_join = try buffer.toOwnedSlice(std.testing.allocator);
    defer std.testing.allocator.free(after_join);
    try std.testing.expectEqualStrings("zc def", after_join);
}

test "vim visual character yank and delete" {
    var buffer = try Buffer.initFromText(std.testing.allocator, "abcdef");
    defer buffer.deinit();
    var cursor = Cursor.init(buffer);
    var selection = Selection.fromCursor(cursor);
    var vim = State.init(std.testing.allocator);
    defer vim.deinit();

    _ = try vim.handleVisual(&buffer, &cursor, &selection, false, .{ .char = 'l' });
    _ = try vim.handleVisual(&buffer, &cursor, &selection, false, .{ .char = 'y' });
    try std.testing.expectEqualStrings("ab", vim.yank_register.text.items);

    selection = Selection.fromCursor(cursor);
    _ = try vim.handleVisual(&buffer, &cursor, &selection, false, .{ .char = 'l' });
    try std.testing.expectEqual(Action.exit_visual, try vim.handleVisual(&buffer, &cursor, &selection, false, .{ .char = 'd' }));

    const text = try buffer.toOwnedSlice(std.testing.allocator);
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("adef", text);
}

test "vim visual line change uses full line range" {
    var buffer = try Buffer.initFromText(std.testing.allocator, "one\ntwo\nthree");
    defer buffer.deinit();
    var cursor = Cursor.init(buffer);
    var selection = Selection.fromCursor(cursor);
    var vim = State.init(std.testing.allocator);
    defer vim.deinit();

    _ = try vim.handleVisual(&buffer, &cursor, &selection, true, .{ .char = 'j' });
    try std.testing.expectEqual(Action.enter_insert, try vim.handleVisual(&buffer, &cursor, &selection, true, .{ .char = 'c' }));

    const text = try buffer.toOwnedSlice(std.testing.allocator);
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("three", text);
    try std.testing.expectEqualStrings("one\ntwo\n", vim.delete_register.text.items);
}

test "vim visual o swaps anchor and head" {
    var buffer = try Buffer.initFromText(std.testing.allocator, "abcdef");
    defer buffer.deinit();
    var cursor = Cursor.init(buffer);
    var selection = Selection.fromCursor(cursor);
    var vim = State.init(std.testing.allocator);
    defer vim.deinit();

    _ = try vim.handleVisual(&buffer, &cursor, &selection, false, .{ .char = 'l' });
    _ = try vim.handleVisual(&buffer, &cursor, &selection, false, .{ .char = 'l' });
    try std.testing.expectEqual(@as(usize, 0), selection.anchor);
    try std.testing.expectEqual(@as(usize, 2), selection.head);

    _ = try vim.handleVisual(&buffer, &cursor, &selection, false, .{ .char = 'o' });
    try std.testing.expectEqual(@as(usize, 2), selection.anchor);
    try std.testing.expectEqual(@as(usize, 0), selection.head);
    try std.testing.expectEqual(@as(usize, 0), cursor.offset);
}

test "vim visual paste replaces selection without clobbering yank register" {
    var buffer = try Buffer.initFromText(std.testing.allocator, "abcdef");
    defer buffer.deinit();
    var cursor = Cursor.at(buffer, 1);
    var selection = Selection.fromCursor(cursor);
    var vim = State.init(std.testing.allocator);
    defer vim.deinit();
    try vim.yank_register.setFromRange(std.testing.allocator, buffer, .{ .start = 3, .end = 6 }, false);

    _ = try vim.handleVisual(&buffer, &cursor, &selection, false, .{ .char = 'l' });
    try std.testing.expectEqual(Action.exit_visual, try vim.handleVisual(&buffer, &cursor, &selection, false, .{ .char = 'p' }));

    const text = try buffer.toOwnedSlice(std.testing.allocator);
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("adefdef", text);
    try std.testing.expectEqualStrings("def", vim.yank_register.text.items);
    try std.testing.expectEqualStrings("bc", vim.delete_register.text.items);
}

test "vim visual J and K move selected lines" {
    var buffer = try Buffer.initFromText(std.testing.allocator, "one\ntwo\nthree\nfour\n");
    defer buffer.deinit();
    var cursor = Cursor.at(buffer, buffer.byteOffsetForLine(1));
    var selection = Selection.fromCursor(cursor);
    var vim = State.init(std.testing.allocator);
    defer vim.deinit();

    _ = try vim.handleVisual(&buffer, &cursor, &selection, true, .{ .char = 'J' });
    const after_down = try buffer.toOwnedSlice(std.testing.allocator);
    defer std.testing.allocator.free(after_down);
    try std.testing.expectEqualStrings("one\nthree\ntwo\nfour\n", after_down);
    try std.testing.expectEqual(@as(usize, buffer.byteOffsetForLine(2)), cursor.offset);

    _ = try vim.handleVisual(&buffer, &cursor, &selection, true, .{ .char = 'K' });
    const after_up = try buffer.toOwnedSlice(std.testing.allocator);
    defer std.testing.allocator.free(after_up);
    try std.testing.expectEqualStrings("one\ntwo\nthree\nfour\n", after_up);
    try std.testing.expectEqual(@as(usize, buffer.byteOffsetForLine(1)), cursor.offset);
}
