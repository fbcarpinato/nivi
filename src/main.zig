const std = @import("std");
const nivi = @import("nivi");

const Io = std.Io;
const Buffer = nivi.Buffer;
const Cursor = nivi.Cursor;
const Selection = nivi.Selection;
const Key = nivi.input.Key;
const Rect = nivi.render.Rect;

const Mode = enum { normal, insert, command, visual, visual_line };
const WorkspaceCommand = enum { toggle_undo_tree };
const KeyMapping = struct {
    sequence: []const u21,
    command: WorkspaceCommand,
};
const key_mappings = [_]KeyMapping{.{ .sequence = &.{ ',', 'u', 't' }, .command = .toggle_undo_tree }};
const syntax_debounce_ns: i128 = 25 * std.time.ns_per_ms;
const insert_syntax_idle_ns: i128 = 100 * std.time.ns_per_ms;
const syntax_budget_ns: u64 = 2 * std.time.ns_per_ms;
const syntax_recovery_samples = 3;
const frame_timeout_ms = 16;

const SyntaxLatency = struct {
    const capacity = 128;

    samples: [capacity]u64 = .{0} ** capacity,
    count: usize = 0,
    next: usize = 0,
    total_ns: u128 = 0,
    max_ns: u64 = 0,
    over_budget: u64 = 0,

    fn record(self: *SyntaxLatency, elapsed_ns: u64) void {
        if (self.count == capacity) {
            self.total_ns -= self.samples[self.next];
        } else {
            self.count += 1;
        }
        self.samples[self.next] = elapsed_ns;
        self.next = (self.next + 1) % capacity;
        self.total_ns += elapsed_ns;
        self.max_ns = @max(self.max_ns, elapsed_ns);
        if (elapsed_ns > syntax_budget_ns) self.over_budget += 1;
    }

    fn averageNs(self: SyntaxLatency) u64 {
        return if (self.count == 0) 0 else @intCast(self.total_ns / self.count);
    }

    fn percentileNs(self: SyntaxLatency, percentile: u8) u64 {
        if (self.count == 0) return 0;
        var sorted: [capacity]u64 = undefined;
        @memcpy(sorted[0..self.count], self.samples[0..self.count]);
        std.mem.sort(u64, sorted[0..self.count], {}, std.sort.asc(u64));
        const rank = (@as(usize, percentile) * (self.count - 1) + 99) / 100;
        return sorted[@min(rank, self.count - 1)];
    }
};

const SyntaxScheduler = struct {
    latency: SyntaxLatency = .{},
    defer_until_idle: bool = false,
    fast_streak: u8 = 0,

    fn record(self: *SyntaxScheduler, elapsed_ns: u64) void {
        self.latency.record(elapsed_ns);
        if (elapsed_ns > syntax_budget_ns) {
            self.defer_until_idle = true;
            self.fast_streak = 0;
        } else if (self.defer_until_idle) {
            self.fast_streak +|= 1;
            if (self.fast_streak >= syntax_recovery_samples) {
                self.defer_until_idle = false;
                self.fast_streak = 0;
            }
        }
    }
};

const App = struct {
    allocator: std.mem.Allocator,
    io: Io,
    buffer: *Buffer,
    cursor: Cursor,
    selection: Selection,
    vim: nivi.vim.State,
    syntax: nivi.syntax.Highlighter,
    workspace: nivi.Workspace,
    mode: Mode = .normal,
    first_line: usize = 0,
    first_column: usize = 0,
    editor_area: Rect = .{ .x = 0, .y = 0, .width = 0, .height = 1 },
    cursor_line: usize = 0,
    cursor_visual_column: usize = 0,
    command: std.ArrayListUnmanaged(u8) = .empty,
    message: std.ArrayListUnmanaged(u8) = .empty,
    render_scratch: std.ArrayListUnmanaged(u8) = .empty,
    indent_scratch: std.ArrayListUnmanaged(u8) = .empty,
    syntax_highlights: std.ArrayListUnmanaged(nivi.syntax.HighlightSpan) = .empty,
    syntax_highlights_back: std.ArrayListUnmanaged(nivi.syntax.HighlightSpan) = .empty,
    syntax_generation: u64 = 0,
    syntax_highlight_generation: u64 = 0,
    syntax_visible: nivi.syntax.ByteRange = .{ .start = 0, .end = 0 },
    syntax_refresh_after_ns: i128 = 0,
    syntax_scheduler: SyntaxScheduler = .{},
    needs_render: bool = true,
    mapping_buffer: [8]u21 = undefined,
    mapping_len: usize = 0,
    insert_group_open: bool = false,
    should_quit: bool = false,

    fn deinit(self: *App) void {
        self.closeInsertGroup();
        self.workspace.deinit();
        self.syntax.deinit();
        self.vim.deinit();
        self.command.deinit(self.allocator);
        self.message.deinit(self.allocator);
        self.render_scratch.deinit(self.allocator);
        self.indent_scratch.deinit(self.allocator);
        self.syntax_highlights.deinit(self.allocator);
        self.syntax_highlights_back.deinit(self.allocator);
    }

    fn setMessage(self: *App, comptime fmt: []const u8, args: anytype) !void {
        self.message.clearRetainingCapacity();
        var buf: [256]u8 = undefined;
        const text = std.fmt.bufPrint(&buf, fmt, args) catch "message too long";
        try self.message.appendSlice(self.allocator, text);
    }

    fn handleKey(self: *App, key: Key) !void {
        const before_generation = self.buffer.generation;
        if (self.mode == .normal and self.globalNormalCommand(key)) {
            // handled global normal-mode command
        } else if (self.mode == .normal and try self.handleMapping(key)) {
            // handled global key mapping
        } else if (self.mode == .normal and self.handleFocusKey(key)) {
            // handled workspace focus movement
        } else if (self.mode == .normal and self.workspace.focusedKind() != .editor) {
            try self.applyComponentAction(self.workspace.handleFocusedKey(key));
        } else {
            switch (self.mode) {
                .normal => try self.handleNormal(key),
                .insert => try self.handleInsert(key),
                .command => try self.handleCommand(key),
                .visual, .visual_line => try self.handleVisual(key),
            }
        }
        if (self.buffer.generation != before_generation) {
            if (self.buffer.generation == before_generation + 1) {
                self.adjustSyntaxHighlightsForLastEdit(before_generation);
                const delay = if (self.mode == .insert) insert_syntax_idle_ns else syntax_debounce_ns;
                self.syntax_refresh_after_ns = if (self.syntax_scheduler.defer_until_idle) monotonicNowNs() + delay else 0;
            } else {
                // Multi-edit commands cannot be remapped from only `last_edit`.
                // Rebuild before the next frame while the front-buffered spans
                // remain visible; only a complete replacement is swapped in.
                self.syntax_refresh_after_ns = 0;
            }
        }
        self.needs_render = true;
        try self.keepCursorVisible();
    }

    fn globalNormalCommand(self: *App, key: Key) bool {
        switch (key) {
            .char => |ch| if (ch == ':') {
                self.vim.cancel();
                self.mapping_len = 0;
                self.command.clearRetainingCapacity();
                self.setMode(.command);
                return true;
            },
            else => {},
        }
        return false;
    }

    fn setMode(self: *App, mode: Mode) void {
        if (self.mode == .insert and mode != .insert) {
            self.closeInsertGroup();
            if (self.syntax_generation != self.buffer.generation) self.syntax_refresh_after_ns = 0;
        }
        if (mode != .normal) self.mapping_len = 0;
        self.mode = mode;
    }

    fn ensureInsertGroup(self: *App) void {
        if (self.insert_group_open) return;
        self.buffer.beginUndoGroup(self.cursor.offset);
        self.insert_group_open = true;
    }

    fn closeInsertGroup(self: *App) void {
        if (!self.insert_group_open) return;
        self.buffer.endUndoGroup(self.cursor.offset);
        self.insert_group_open = false;
    }

    fn handleMapping(self: *App, key: Key) !bool {
        const had_pending = self.mapping_len != 0;
        const ch = switch (key) {
            .char => |value| value,
            else => {
                if (had_pending) self.mapping_len = 0;
                return had_pending;
            },
        };
        if (self.mapping_len >= self.mapping_buffer.len) {
            self.mapping_len = 0;
            return had_pending;
        }
        self.mapping_buffer[self.mapping_len] = ch;
        self.mapping_len += 1;

        var has_prefix = false;
        for (key_mappings) |mapping| {
            if (self.mapping_len > mapping.sequence.len) continue;
            if (!std.mem.eql(u21, self.mapping_buffer[0..self.mapping_len], mapping.sequence[0..self.mapping_len])) continue;
            has_prefix = true;
            if (self.mapping_len == mapping.sequence.len) {
                self.mapping_len = 0;
                self.vim.cancel();
                try self.executeWorkspaceCommand(mapping.command);
                return true;
            }
        }
        if (has_prefix) {
            self.vim.cancel();
            return true;
        }
        self.mapping_len = 0;
        return had_pending;
    }

    fn executeWorkspaceCommand(self: *App, command: WorkspaceCommand) !void {
        switch (command) {
            .toggle_undo_tree => try self.workspace.toggleUndoTree(),
        }
        try self.workspace.refresh(self.buffer);
    }

    fn handleFocusKey(self: *App, key: Key) bool {
        const direction: nivi.component.Direction = switch (key) {
            .ctrl => |ch| switch (ch) {
                'h' => .left,
                'j' => .down,
                'k' => .up,
                'l' => .right,
                else => return false,
            },
            else => return false,
        };
        self.vim.cancel();
        self.workspace.focusDirection(direction);
        return true;
    }

    fn applyComponentAction(self: *App, action: nivi.component.Action) !void {
        if (self.workspace.applyAction(action)) |seq| {
            if (try self.buffer.jumpToState(seq)) |offset| try self.cursor.setOffset(self.buffer.*, offset);
            try self.workspace.refresh(self.buffer);
            self.workspace.selectCurrentUndo(self.buffer);
        }
    }

    fn refreshCursorMetrics(self: *App) !void {
        self.cursor_line = try self.cursor.line(self.buffer.*);
        self.cursor_visual_column = try self.cursor.visualColumn(self.buffer.*);
    }

    fn handleNormal(self: *App, key: Key) !void {
        switch (key) {
            .char => |ch| switch (ch) {
                ':' => {},
                'u' => {
                    self.vim.cancel();
                    if (try self.buffer.undo()) |offset| try self.cursor.setOffset(self.buffer.*, offset);
                },
                'o' => try self.openIndentedLine(key, true),
                'O' => try self.openIndentedLine(key, false),
                else => try self.handleVimNormal(key),
            },
            .ctrl => |ch| if (ch == 'r') {
                self.vim.cancel();
                if (try self.buffer.redo()) |offset| try self.cursor.setOffset(self.buffer.*, offset);
            } else try self.handleVimNormal(key),
            .arrow_left, .arrow_right, .arrow_up, .arrow_down, .ctrl_arrow_up, .ctrl_arrow_down, .home, .end, .page_up, .page_down => try self.handleVimNormal(key),
            .unknown => |bytes| try self.setUnknownKeyMessage(bytes),
            else => {},
        }
    }

    fn setUnknownKeyMessage(self: *App, bytes: []const u8) !void {
        self.message.clearRetainingCapacity();
        try self.message.appendSlice(self.allocator, "unknown key:");
        for (bytes) |byte| {
            var buf: [8]u8 = undefined;
            const part = std.fmt.bufPrint(&buf, " {X:0>2}", .{byte}) catch unreachable;
            try self.message.appendSlice(self.allocator, part);
        }
    }

    fn handleVimNormal(self: *App, key: Key) !void {
        switch (try self.vim.handleNormal(self.buffer, &self.cursor, key)) {
            .none => {},
            .enter_insert => self.setMode(.insert),
            .enter_visual => try self.enterVisual(.visual),
            .enter_visual_line => try self.enterVisual(.visual_line),
            .exit_visual => self.setMode(.normal),
        }
    }

    fn enterVisual(self: *App, mode: Mode) !void {
        try self.cursor.sync(self.buffer.*);
        self.selection = Selection.fromCursor(self.cursor);
        self.setMode(mode);
    }

    fn handleVisual(self: *App, key: Key) !void {
        switch (try self.vim.handleVisual(self.buffer, &self.cursor, &self.selection, self.mode == .visual_line, key)) {
            .none => {},
            .enter_insert => self.setMode(.insert),
            .enter_visual => try self.enterVisual(.visual),
            .enter_visual_line => self.setMode(.visual_line),
            .exit_visual => self.setMode(.normal),
        }
    }

    fn handleInsert(self: *App, key: Key) !void {
        switch (key) {
            .escape => self.setMode(.normal),
            .enter => {
                self.ensureInsertGroup();
                const columns = try self.desiredIndent(self.cursor.offset, true);
                const text = try self.newlineWithIndent(columns);
                try self.cursor.insertText(self.buffer, text);
            },
            .backspace => {
                self.ensureInsertGroup();
                try self.cursor.deleteBackward(self.buffer);
            },
            .delete => {
                self.ensureInsertGroup();
                try self.cursor.deleteForward(self.buffer);
            },
            .arrow_left => {
                self.closeInsertGroup();
                try self.cursor.moveLeft(self.buffer.*);
            },
            .arrow_right => {
                self.closeInsertGroup();
                try self.cursor.moveRight(self.buffer.*);
            },
            .arrow_up => {
                self.closeInsertGroup();
                try self.cursor.moveUp(self.buffer.*);
            },
            .arrow_down => {
                self.closeInsertGroup();
                try self.cursor.moveDown(self.buffer.*);
            },
            .char => |ch| {
                const token_start = self.cursor.offset;
                const line_prefix_is_whitespace = self.cursorPrefixIsWhitespace();
                var bytes: [4]u8 = undefined;
                const len = try std.unicode.utf8Encode(ch, &bytes);
                self.ensureInsertGroup();
                try self.cursor.insertText(self.buffer, bytes[0..len]);
                if (line_prefix_is_whitespace) try self.reindentIfIndentEnd(token_start, len);
            },
            else => {},
        }
    }

    fn cursorPrefixIsWhitespace(self: App) bool {
        const line = self.buffer.lineAt(self.cursor.offset);
        const line_start = self.buffer.byteOffsetForLine(line);
        var offset = line_start;
        while (offset < self.cursor.offset) : (offset += 1) {
            const byte = self.buffer.byteAt(offset);
            if (byte != ' ' and byte != '\t') return false;
        }
        return true;
    }

    fn reindentIfIndentEnd(self: *App, token_start: usize, token_len: usize) !void {
        const columns = (try self.syntax.indentEndColumns(self.buffer, token_start, self.buffer.tab_width)) orelse return;
        const line = self.buffer.lineAt(token_start);
        const line_start = self.buffer.byteOffsetForLine(line);
        const old_indent_len = token_start - line_start;
        if (old_indent_len == columns) {
            var all_spaces = true;
            var offset = line_start;
            while (offset < token_start) : (offset += 1) {
                if (self.buffer.byteAt(offset) != ' ') {
                    all_spaces = false;
                    break;
                }
            }
            if (all_spaces) return;
        }

        const indent = try self.indentText(columns);
        try self.buffer.replace(line_start, old_indent_len, indent);
        try self.cursor.setOffset(self.buffer.*, line_start + columns + token_len);
    }

    fn openIndentedLine(self: *App, key: Key, below: bool) !void {
        try self.cursor.sync(self.buffer.*);
        const line = self.buffer.lineAt(self.cursor.offset);
        const context_offset = if (below) self.buffer.lineContentRange(line).end else self.buffer.byteOffsetForLine(line);
        const columns = try self.desiredIndent(context_offset, below);
        self.ensureInsertGroup();
        try self.handleVimNormal(key);
        if (columns != 0) {
            const indent = try self.indentText(columns);
            try self.cursor.insertText(self.buffer, indent);
        }
    }

    fn desiredIndent(self: *App, offset: usize, after_line: bool) !usize {
        if (try self.syntax.indentColumns(self.buffer, offset, self.buffer.tab_width)) |columns| return columns;
        return self.fallbackIndent(offset, after_line);
    }

    fn fallbackIndent(self: App, offset: usize, after_line: bool) usize {
        var line = self.buffer.lineAt(@min(offset, self.buffer.byteLen()));
        var range = self.buffer.lineContentRange(line);
        while (range.start == range.end and line > 0) {
            line -= 1;
            range = self.buffer.lineContentRange(line);
        }
        var columns: usize = 0;
        var at = range.start;
        while (at < range.end) : (at += 1) switch (self.buffer.byteAt(at)) {
            ' ' => columns += 1,
            '\t' => columns += self.buffer.tab_width - (columns % self.buffer.tab_width),
            else => break,
        };
        if (after_line and range.end > range.start) {
            var end = range.end;
            while (end > range.start and (self.buffer.byteAt(end - 1) == ' ' or self.buffer.byteAt(end - 1) == '\t')) : (end -= 1) {}
            if (end > range.start) switch (self.buffer.byteAt(end - 1)) {
                '{', '[', '(' => columns += self.buffer.tab_width,
                else => {},
            };
        }
        return columns;
    }

    fn newlineWithIndent(self: *App, columns: usize) ![]const u8 {
        self.indent_scratch.clearRetainingCapacity();
        try self.indent_scratch.append(self.allocator, '\n');
        try self.indent_scratch.appendNTimes(self.allocator, ' ', columns);
        return self.indent_scratch.items;
    }

    fn indentText(self: *App, columns: usize) ![]const u8 {
        self.indent_scratch.clearRetainingCapacity();
        try self.indent_scratch.appendNTimes(self.allocator, ' ', columns);
        return self.indent_scratch.items;
    }

    fn handleCommand(self: *App, key: Key) !void {
        switch (key) {
            .escape => self.setMode(.normal),
            .backspace => {
                if (self.command.items.len != 0) _ = self.command.pop();
            },
            .enter => try self.executeCommand(),
            .char => |ch| if (ch < 0x80 and std.ascii.isPrint(@intCast(ch))) {
                try self.command.append(self.allocator, @intCast(ch));
            },
            else => {},
        }
    }

    fn executeCommand(self: *App) !void {
        const cmd = std.mem.trim(u8, self.command.items, " \t");
        defer self.command.clearRetainingCapacity();
        self.setMode(.normal);

        if (std.mem.eql(u8, cmd, "w")) {
            try self.buffer.save(self.io);
            try self.setMessage("written", .{});
        } else if (std.mem.eql(u8, cmd, "q")) {
            if (self.buffer.dirty) {
                try self.setMessage("unsaved changes (use :w or :q!)", .{});
            } else {
                self.should_quit = true;
            }
        } else if (std.mem.eql(u8, cmd, "q!")) {
            self.should_quit = true;
        } else if (std.mem.eql(u8, cmd, "wq") or std.mem.eql(u8, cmd, "x")) {
            try self.buffer.save(self.io);
            self.should_quit = true;
        } else if (std.mem.eql(u8, cmd, "syntax")) {
            const latency = self.syntax_scheduler.latency;
            try self.setMessage("syntax n={d} avg={d}us p50={d}us p99={d}us max={d}us slow={d} mode={s}", .{
                latency.count,
                latency.averageNs() / std.time.ns_per_us,
                latency.percentileNs(50) / std.time.ns_per_us,
                latency.percentileNs(99) / std.time.ns_per_us,
                latency.max_ns / std.time.ns_per_us,
                latency.over_budget,
                if (self.syntax_scheduler.defer_until_idle) "idle" else "immediate",
            });
        } else {
            try self.setMessage("not an editor command: {s}", .{cmd});
        }
    }

    fn keepCursorVisible(self: *App) !void {
        try self.refreshCursorMetrics();
        const line = self.cursor_line;
        if (line < self.first_line) self.first_line = line;
        const height = @max(self.editor_area.height, 1);
        if (line >= self.first_line + height) self.first_line = line - height + 1;
        const line_count = self.buffer.lineCount();
        if (line_count > height and self.first_line > line_count - height) self.first_line = line_count - height;
        if (line_count <= height) self.first_line = 0;

        const gutter = nivi.render.gutterWidth(self.buffer.*);
        const text_width = self.editor_area.width -| gutter;
        const col = self.cursor_visual_column;
        if (text_width == 0) {
            self.first_column = 0;
        } else if (col < self.first_column) {
            self.first_column = col;
        } else if (col >= self.first_column + text_width) {
            self.first_column = col - text_width + 1;
        }
    }

    fn renderSelection(self: *App) !?Buffer.ByteRange {
        return switch (self.mode) {
            .visual => try nivi.vim.selectedRange(self.buffer.*, self.selection, false),
            .visual_line => try nivi.vim.selectedRange(self.buffer.*, self.selection, true),
            else => null,
        };
    }

    fn renderHighlights(self: *App, visible: nivi.syntax.ByteRange, now_ns: i128) !?[]const nivi.syntax.HighlightSpan {
        if (!self.syntax.enabled()) return null;
        if (self.syntax_generation == self.buffer.generation) {
            if (self.syntax_highlight_generation == self.buffer.generation and std.meta.eql(self.syntax_visible, visible)) return self.syntax_highlights.items;
            try self.rebuildVisibleHighlights(visible);
            return self.syntax_highlights.items;
        }
        if (self.syntax_generation != 0 and now_ns < self.syntax_refresh_after_ns) return self.syntax_highlights.items;

        const started_ns = monotonicNowNs();
        self.syntax_highlights_back.clearRetainingCapacity();
        const incremental = self.syntax_generation != 0 and self.syntax_generation + 1 == self.buffer.generation and self.buffer.last_edit != null and self.buffer.last_edit.?.generation == self.buffer.generation;
        const budget_ns: ?u64 = if (self.syntax_generation != 0 and !self.syntax_scheduler.defer_until_idle) syntax_budget_ns else null;
        if (incremental) {
            try self.syntax_highlights_back.appendSlice(self.allocator, self.syntax_highlights.items);
            const edit = self.buffer.last_edit.?;
            self.syntax.collectEditBudgeted(&self.syntax_highlights_back, self.buffer, .{
                .offset = edit.offset,
                .old_end = edit.old_end,
                .new_end = edit.new_end,
                .start_point = .{ .row = edit.start_point.row, .column = edit.start_point.column },
                .old_end_point = .{ .row = edit.old_end_point.row, .column = edit.old_end_point.column },
                .new_end_point = .{ .row = edit.new_end_point.row, .column = edit.new_end_point.column },
            }, visible, budget_ns) catch |err| switch (err) {
                error.ParseCancelled => {
                    self.deferSyntaxRefresh(started_ns);
                    return self.syntax_highlights.items;
                },
                else => return err,
            };
            if (!std.meta.eql(self.syntax_visible, visible)) {
                self.syntax_highlights_back.clearRetainingCapacity();
                try self.syntax.collectVisible(&self.syntax_highlights_back, self.buffer, visible);
            }
        } else {
            self.syntax.collectFullBudgeted(&self.syntax_highlights_back, self.buffer, visible, budget_ns) catch |err| switch (err) {
                error.ParseCancelled => {
                    self.deferSyntaxRefresh(started_ns);
                    return self.syntax_highlights.items;
                },
                else => return err,
            };
        }

        self.swapSyntaxHighlights();
        self.syntax_generation = self.buffer.generation;
        self.syntax_highlight_generation = self.buffer.generation;
        self.syntax_visible = visible;
        self.recordSyntaxLatency(started_ns);
        return self.syntax_highlights.items;
    }

    fn rebuildVisibleHighlights(self: *App, visible: nivi.syntax.ByteRange) !void {
        const started_ns = monotonicNowNs();
        self.syntax_highlights_back.clearRetainingCapacity();
        try self.syntax.collectVisible(&self.syntax_highlights_back, self.buffer, visible);
        self.swapSyntaxHighlights();
        self.syntax_highlight_generation = self.buffer.generation;
        self.syntax_visible = visible;
        self.recordSyntaxLatency(started_ns);
    }

    fn swapSyntaxHighlights(self: *App) void {
        std.mem.swap(std.ArrayListUnmanaged(nivi.syntax.HighlightSpan), &self.syntax_highlights, &self.syntax_highlights_back);
    }

    fn recordSyntaxLatency(self: *App, started_ns: i128) void {
        const finished_ns = monotonicNowNs();
        const elapsed_ns: u64 = if (finished_ns > started_ns) @intCast(@min(finished_ns - started_ns, std.math.maxInt(u64))) else 0;
        self.syntax_scheduler.record(elapsed_ns);
    }

    fn deferSyntaxRefresh(self: *App, started_ns: i128) void {
        const finished_ns = monotonicNowNs();
        const elapsed_ns: u64 = if (finished_ns > started_ns) @intCast(@min(finished_ns - started_ns, std.math.maxInt(u64))) else syntax_budget_ns + 1;
        self.syntax_scheduler.record(@max(elapsed_ns, syntax_budget_ns + 1));
        self.syntax_highlights_back.clearRetainingCapacity();
        self.syntax_refresh_after_ns = finished_ns + insert_syntax_idle_ns;
    }

    fn adjustSyntaxHighlightsForLastEdit(self: *App, previous_generation: u64) void {
        if (self.syntax_highlight_generation != previous_generation) return;
        const edit = self.buffer.last_edit orelse return;
        if (edit.generation != self.buffer.generation) return;

        const old_len = edit.old_end - edit.offset;
        const new_len = edit.new_end - edit.offset;
        const grow = new_len >= old_len;
        const delta = if (grow) new_len - old_len else old_len - new_len;

        var out: usize = 0;
        for (self.syntax_highlights.items) |span| {
            var next = span;
            if (next.end <= edit.offset) {
                // unchanged
            } else if (next.start >= edit.old_end) {
                if (grow) {
                    next.start += delta;
                    next.end += delta;
                } else {
                    next.start -= @min(delta, next.start);
                    next.end -= @min(delta, next.end);
                }
            } else {
                // Edited-through spans are intentionally dropped until the next parse.
                continue;
            }
            self.syntax_highlights.items[out] = next;
            out += 1;
        }
        self.syntax_highlights.shrinkRetainingCapacity(out);
        self.syntax_highlight_generation = self.buffer.generation;
    }

    fn syntaxRefreshDue(self: App, now_ns: i128) bool {
        return self.syntax.enabled() and self.syntax_generation != 0 and self.syntax_generation != self.buffer.generation and now_ns >= self.syntax_refresh_after_ns;
    }

    fn pollTimeoutMs(self: App, now_ns: i128) i32 {
        if (!self.syntax.enabled() or self.syntax_generation == 0 or self.syntax_generation == self.buffer.generation) return frame_timeout_ms;
        if (now_ns >= self.syntax_refresh_after_ns) return 0;
        const remaining_ns = self.syntax_refresh_after_ns - now_ns;
        const remaining_ms = @max(@as(i128, 1), @divTrunc(remaining_ns + std.time.ns_per_ms - 1, std.time.ns_per_ms));
        return @intCast(@min(@as(i128, frame_timeout_ms), remaining_ms));
    }

    fn visibleByteRange(self: App, area: Rect) nivi.syntax.ByteRange {
        const start_line = @min(self.first_line, self.buffer.lineCount() - 1);
        const end_line = @min(self.buffer.lineCount(), start_line + area.height);
        const start = self.buffer.byteOffsetForLine(start_line);
        const end = if (end_line >= self.buffer.lineCount()) self.buffer.byteLen() else self.buffer.byteOffsetForLine(end_line);
        return .{ .start = start, .end = end };
    }

    fn render(self: *App, frame: *nivi.render.FrameRenderer, now_ns: i128) !void {
        try self.refreshCursorMetrics();
        frame.beginRetainedFrame();
        const screen = frame.current.rect();
        const command_split = screen.splitBottom(1);
        const status_split = command_split.second.splitBottom(1);
        const workspace_area = status_split.second;
        const status_area = status_split.first;
        const command_area = command_split.first;
        try self.workspace.refresh(self.buffer);
        self.workspace.layout(workspace_area);
        const editor_area = self.workspace.editorRect();
        self.editor_area = editor_area;
        const highlights = try self.renderHighlights(self.visibleByteRange(editor_area), now_ns);

        frame.current.fillRect(editor_area, .space(.{}));
        try nivi.render.renderBufferViewportScratch(self.allocator, &self.render_scratch, &frame.current, editor_area, self.buffer.*, .{
            .first_line = self.first_line,
            .first_column = self.first_column,
            .cursor_line = self.cursor_line,
            .relative_line_numbers = true,
            .selection = try self.renderSelection(),
            .highlights = highlights,
        });
        try frame.markDirty(editor_area);
        try self.workspace.renderComponents(frame, self.buffer, wallNowSeconds());
        self.renderStatus(&frame.current, status_area);
        try frame.markDirty(status_area);
        frame.current.fillRect(command_area, .space(.{}));
        self.renderCommand(&frame.current, command_area);
        try frame.markDirty(command_area);
        self.needs_render = false;
    }

    fn placeTerminalCursor(self: *App, writer: *Io.Writer, screen: Rect) !void {
        const shape: nivi.render.AnsiRenderer.CursorShape = switch (self.mode) {
            .insert => .bar,
            .normal, .command, .visual, .visual_line => .block,
        };
        try nivi.render.AnsiRenderer.setCursorShape(writer, shape);

        const command_area = screen.splitBottom(1).first;
        if (self.mode == .command) {
            const x = @min(command_area.x + 1 + self.command.items.len, command_area.right() -| 1);
            try nivi.render.AnsiRenderer.cursorTo(writer, x, command_area.y);
            try nivi.render.AnsiRenderer.showCursor(writer);
            return;
        }

        if (self.workspace.focusedKind() != .editor) {
            const position = self.workspace.focusedCursorPosition() orelse return;
            try nivi.render.AnsiRenderer.cursorTo(writer, position.x, position.y);
            try nivi.render.AnsiRenderer.showCursor(writer);
            return;
        }

        const editor_area = self.workspace.editorRect();
        const row = if (self.cursor_line >= self.first_line) self.cursor_line - self.first_line else 0;
        const gutter = nivi.render.gutterWidth(self.buffer.*);
        const scrolled_col = self.cursor_visual_column -| self.first_column;
        const col = scrolled_col + gutter;
        const x = @min(editor_area.x + col, editor_area.right() -| 1);
        const y = @min(editor_area.y + row, editor_area.bottom() -| 1);
        try nivi.render.AnsiRenderer.cursorTo(writer, x, y);
        try nivi.render.AnsiRenderer.showCursor(writer);
    }

    fn renderStatus(self: *App, surface: *nivi.render.Surface, area: Rect) void {
        if (area.width == 0 or area.height == 0) return;
        const status_style: nivi.render.Style = .{ .fg = .status, .inverse = true };
        surface.fillRect(area, .space(status_style));
        var buf: [256]u8 = undefined;
        const name = self.buffer.path orelse "[No Name]";
        const mode = switch (self.mode) {
            .normal => "NORMAL",
            .insert => "INSERT",
            .command => "COMMAND",
            .visual => "VISUAL",
            .visual_line => "V-LINE",
        };
        const focus = @tagName(self.workspace.focusedKind());
        const line = self.cursor_line + 1;
        const col = self.cursor_visual_column + 1;
        const text = std.fmt.bufPrint(&buf, " {s} {s}{s}  {d}:{d}  {d} bytes  [{s}]", .{ mode, name, if (self.buffer.dirty) " [+]" else "", line, col, self.buffer.byteLen(), focus }) catch " status error";
        surface.writeAscii(area.x, area.y, area.width, text, status_style);
    }

    fn renderCommand(self: *App, surface: *nivi.render.Surface, area: Rect) void {
        if (area.width == 0 or area.height == 0) return;
        switch (self.mode) {
            .command => {
                surface.putCell(area.x, area.y, .ascii(':', .{ .fg = .accent }));
                if (area.width > 1) surface.writeAscii(area.x + 1, area.y, area.width - 1, self.command.items, .{ .fg = .accent });
            },
            else => if (self.message.items.len != 0) {
                surface.writeAscii(area.x, area.y, area.width, self.message.items, .{ .fg = .accent });
            },
        }
    }
};

fn monotonicNowNs() i128 {
    var ts: std.c.timespec = undefined;
    if (std.c.clock_gettime(.MONOTONIC, &ts) != 0) return 0;
    return @as(i128, ts.sec) * std.time.ns_per_s + ts.nsec;
}

fn undoTimestamp() i64 {
    return wallNowSeconds();
}

fn wallNowSeconds() i64 {
    var ts: std.c.timespec = undefined;
    if (std.c.clock_gettime(.REALTIME, &ts) != 0) return 0;
    return ts.sec;
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_file_writer: Io.File.Writer = .init(.stdout(), init.io, &stdout_buffer);
    const stdout = &stdout_file_writer.interface;
    defer stdout.flush() catch {};

    var stderr_buffer: [1024]u8 = undefined;
    var stderr_file_writer: Io.File.Writer = .init(.stderr(), init.io, &stderr_buffer);
    const stderr = &stderr_file_writer.interface;
    defer stderr.flush() catch {};

    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, allocator);
    defer args.deinit();
    _ = args.skip();

    var force_line = false;
    var path_arg: ?[]const u8 = null;
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--line")) force_line = true else if (path_arg == null) path_arg = arg else {
            try stderr.writeAll("error: expected one file path\n\n");
            try printUsage(stderr);
            return error.InvalidArgs;
        }
    }
    if (path_arg == null or std.mem.eql(u8, path_arg.?, "-h") or std.mem.eql(u8, path_arg.?, "--help")) {
        try printUsage(stdout);
        return;
    }

    var buffer = Buffer.loadFromFile(init.io, allocator, path_arg.?) catch |err| switch (err) {
        error.FileNotFound => try Buffer.initWithPath(allocator, path_arg.?),
        else => |e| return e,
    };
    defer buffer.deinit();

    if (!force_line) {
        runFullscreen(init.io, allocator, &buffer, nivi.terminal.size(std.posix.STDOUT_FILENO, init.environ_map.*)) catch |err| switch (err) {
            error.UnsupportedTerminal, error.NotATerminal, error.AccessDenied => return try runLineEditor(init.io, allocator, &buffer, stdout, path_arg.?),
            else => |e| return e,
        };
        return;
    }

    try runLineEditor(init.io, allocator, &buffer, stdout, path_arg.?);
}

fn runFullscreen(io: Io, allocator: std.mem.Allocator, buffer: *Buffer, size: nivi.terminal.Size) !void {
    var stdout_buffer: [16 * 1024]u8 = undefined;
    var stdout_file_writer: Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const stdout = &stdout_file_writer.interface;
    defer stdout.flush() catch {};

    var raw = try nivi.terminal.RawMode.enable(std.posix.STDIN_FILENO);
    defer raw.disable(std.posix.STDIN_FILENO);
    try nivi.terminal.Screen.enter(stdout);
    defer nivi.terminal.Screen.leave(stdout) catch {};

    var frame = try nivi.render.FrameRenderer.init(allocator, size.width, size.height);
    defer frame.deinit();
    buffer.undo_tree.clock = undoTimestamp;

    var app: App = .{
        .allocator = allocator,
        .io = io,
        .buffer = buffer,
        .cursor = Cursor.init(buffer.*),
        .selection = Selection.init(buffer.*),
        .vim = nivi.vim.State.init(allocator),
        .syntax = try nivi.syntax.Highlighter.init(io, allocator, buffer.path),
        .workspace = try nivi.Workspace.init(allocator),
    };
    defer app.deinit();

    // Bytes read but not yet consumed (an escape/UTF-8 sequence split across
    // reads). Retained across iterations so partial sequences never leak as
    // literal input.
    var pending: [256]u8 = undefined;
    var pending_len: usize = 0;
    var read_buf: [256]u8 = undefined;
    while (!app.should_quit) {
        if (nivi.terminal.detectedSize(std.posix.STDOUT_FILENO)) |detected| {
            if (frame.current.width != detected.width or frame.current.height != detected.height) {
                try frame.resize(detected.width, detected.height);
                app.needs_render = true;
            }
        }

        const now_ns = monotonicNowNs();
        if (app.needs_render or app.syntaxRefreshDue(now_ns)) {
            try app.render(&frame, now_ns);
            try nivi.render.AnsiRenderer.hideCursor(stdout);
            try frame.present(stdout);
            try app.placeTerminalCursor(stdout, frame.current.rect());
            try stdout.flush();
        }

        var poll_fds = [_]std.posix.pollfd{.{ .fd = std.posix.STDIN_FILENO, .events = std.posix.POLL.IN, .revents = 0 }};
        const ready = try std.posix.poll(&poll_fds, app.pollTimeoutMs(monotonicNowNs()));
        if (ready == 0) {
            // A lone pending ESC resolves to an Escape keypress after one frame;
            // any other stale partial sequence is dropped.
            if (pending_len == 1 and pending[0] == 0x1b) try app.handleKey(.escape);
            pending_len = 0;
            continue;
        }

        const n = try std.posix.read(std.posix.STDIN_FILENO, &read_buf);
        if (n == 0) continue;

        const copy = @min(n, pending.len - pending_len);
        @memcpy(pending[pending_len..][0..copy], read_buf[0..copy]);
        pending_len += copy;

        var index: usize = 0;
        while (index < pending_len) {
            const decoded = nivi.input.decode(pending[index..pending_len]) orelse break;
            try app.handleKey(decoded.key);
            index += decoded.used;
        }

        // Drop a stuck full buffer that never forms a valid sequence.
        if (index == 0 and pending_len == pending.len) pending_len = 0;
        if (index != 0) {
            std.mem.copyForwards(u8, pending[0 .. pending_len - index], pending[index..pending_len]);
            pending_len -= index;
        }
    }
}

fn printUsage(writer: *Io.Writer) !void {
    try writer.writeAll(
        \\usage: nivi [--line] <file>
        \\
        \\Default mode opens a raw terminal editor. Use --line for the old line-command fallback.
        \\
    );
}

fn runLineEditor(io: Io, allocator: std.mem.Allocator, buffer: *Buffer, stdout: *Io.Writer, path: []const u8) !void {
    try stdout.print("nivi: {s} ({d} bytes)\n", .{ path, buffer.byteLen() });
    try printHelp(stdout);

    var stdin_buffer: [4096]u8 = undefined;
    var stdin_reader = Io.File.stdin().reader(io, &stdin_buffer);
    const stdin = &stdin_reader.interface;

    while (true) {
        try stdout.writeAll(if (buffer.dirty) "* " else ": ");
        try stdout.flush();

        const line = (try stdin.takeDelimiter('\n')) orelse break;
        const command = std.mem.trim(u8, line, " \t\r");
        if (command.len == 0) continue;

        if (try runLineCommand(io, allocator, buffer, stdout, command)) break;
    }
}

fn printHelp(writer: *Io.Writer) !void {
    try writer.writeAll(
        \\commands:
        \\  p                    print whole buffer
        \\  v [first h w]        render viewport (1-based line, height, width)
        \\  i <offset> <text>    insert text at byte offset
        \\  d <offset> <len>     delete len bytes at byte offset
        \\  u                    undo
        \\  r                    redo
        \\  w                    write
        \\  q                    quit if clean
        \\  q!                   quit without saving
        \\  h                    help
        \\
    );
}

fn runLineCommand(io: Io, allocator: std.mem.Allocator, buffer: *Buffer, stdout: *Io.Writer, command: []const u8) !bool {
    if (std.mem.eql(u8, command, "h")) {
        try printHelp(stdout);
        return false;
    }
    if (std.mem.eql(u8, command, "p")) {
        const text = try buffer.toOwnedSlice(allocator);
        defer allocator.free(text);
        try stdout.writeAll(text);
        if (text.len == 0 or text[text.len - 1] != '\n') try stdout.writeByte('\n');
        return false;
    }
    if (std.mem.eql(u8, command, "v") or std.mem.startsWith(u8, command, "v ")) {
        var parts = std.mem.tokenizeAny(u8, if (command.len == 1) "" else command[2..], " \t");
        const first_line = if (parts.next()) |text| blk: {
            const parsed = std.fmt.parseUnsigned(usize, text, 10) catch {
                try stdout.writeAll("invalid first line\n");
                return false;
            };
            break :blk if (parsed == 0) 0 else parsed - 1;
        } else 0;
        const height = if (parts.next()) |text| std.fmt.parseUnsigned(usize, text, 10) catch {
            try stdout.writeAll("invalid height\n");
            return false;
        } else 24;
        const width = if (parts.next()) |text| std.fmt.parseUnsigned(usize, text, 10) catch {
            try stdout.writeAll("invalid width\n");
            return false;
        } else 80;

        var surface = try nivi.render.Surface.init(allocator, width, height);
        defer surface.deinit();
        try nivi.render.renderBufferViewport(allocator, &surface, surface.rect(), buffer.*, .{ .first_line = first_line });
        try surface.writeTo(stdout);
        return false;
    }
    if (std.mem.eql(u8, command, "u")) {
        _ = try buffer.undo();
        return false;
    }
    if (std.mem.eql(u8, command, "r")) {
        _ = try buffer.redo();
        return false;
    }
    if (std.mem.eql(u8, command, "w")) {
        try buffer.save(io);
        try stdout.writeAll("written\n");
        return false;
    }
    if (std.mem.eql(u8, command, "q")) {
        if (buffer.dirty) {
            try stdout.writeAll("unsaved changes (use w or q!)\n");
            return false;
        }
        return true;
    }
    if (std.mem.eql(u8, command, "q!")) return true;

    if (std.mem.startsWith(u8, command, "i ")) {
        const rest = trimLeft(command[2..]);
        const split = std.mem.indexOfAny(u8, rest, " \t") orelse {
            try stdout.writeAll("usage: i <offset> <text>\n");
            return false;
        };
        const offset = std.fmt.parseUnsigned(usize, rest[0..split], 10) catch {
            try stdout.writeAll("invalid offset\n");
            return false;
        };
        const text = trimLeft(rest[split..]);
        if (offset > buffer.byteLen()) {
            try stdout.writeAll("offset out of range\n");
            return false;
        }
        try buffer.insert(offset, text);
        return false;
    }

    if (std.mem.startsWith(u8, command, "d ")) {
        var parts = std.mem.tokenizeAny(u8, command[2..], " \t");
        const offset_text = parts.next() orelse {
            try stdout.writeAll("usage: d <offset> <len>\n");
            return false;
        };
        const len_text = parts.next() orelse {
            try stdout.writeAll("usage: d <offset> <len>\n");
            return false;
        };
        const offset = std.fmt.parseUnsigned(usize, offset_text, 10) catch {
            try stdout.writeAll("invalid offset\n");
            return false;
        };
        const len = std.fmt.parseUnsigned(usize, len_text, 10) catch {
            try stdout.writeAll("invalid len\n");
            return false;
        };
        if (offset > buffer.byteLen() or len > buffer.byteLen() - offset) {
            try stdout.writeAll("range out of bounds\n");
            return false;
        }
        try buffer.delete(offset, len);
        return false;
    }

    try stdout.writeAll("unknown command (h for help)\n");
    return false;
}

fn trimLeft(text: []const u8) []const u8 {
    var index: usize = 0;
    while (index < text.len and (text[index] == ' ' or text[index] == '\t')) : (index += 1) {}
    return text[index..];
}

test "app groups insert-mode typing into one undo node" {
    var buffer = try Buffer.initFromText(std.testing.allocator, "");
    defer buffer.deinit();
    var app: App = .{
        .allocator = std.testing.allocator,
        .io = undefined,
        .buffer = &buffer,
        .cursor = Cursor.init(buffer),
        .selection = Selection.init(buffer),
        .vim = nivi.vim.State.init(std.testing.allocator),
        .syntax = try nivi.syntax.Highlighter.init(std.testing.io, std.testing.allocator, null),
        .workspace = try nivi.Workspace.init(std.testing.allocator),
    };
    defer app.deinit();

    app.setMode(.insert);
    try app.handleInsert(.{ .char = 'a' });
    try app.handleInsert(.{ .char = 'b' });
    app.setMode(.normal);

    try std.testing.expectEqual(@as(usize, 1), buffer.undo_tree.root.children.items.len);
    try std.testing.expectEqualStrings("ab", buffer.undo_tree.root.children.items[0].edits.items[0].new_text.items);
}

test "app undo after insert-mode typing removes whole group" {
    var buffer = try Buffer.initFromText(std.testing.allocator, "");
    defer buffer.deinit();
    var app: App = .{
        .allocator = std.testing.allocator,
        .io = undefined,
        .buffer = &buffer,
        .cursor = Cursor.init(buffer),
        .selection = Selection.init(buffer),
        .vim = nivi.vim.State.init(std.testing.allocator),
        .syntax = try nivi.syntax.Highlighter.init(std.testing.io, std.testing.allocator, null),
        .workspace = try nivi.Workspace.init(std.testing.allocator),
    };
    defer app.deinit();

    try app.handleKey(.{ .char = 'i' });
    try app.handleKey(.{ .char = 'a' });
    try app.handleKey(.{ .char = 'b' });
    try app.handleKey(.{ .char = 'c' });
    try app.handleKey(.escape);
    try app.handleKey(.{ .char = 'u' });

    const text = try buffer.toOwnedSlice(std.testing.allocator);
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("", text);
}

test "undo panel render does not split active insert group" {
    var buffer = try Buffer.initFromText(std.testing.allocator, "");
    defer buffer.deinit();
    var app: App = .{
        .allocator = std.testing.allocator,
        .io = undefined,
        .buffer = &buffer,
        .cursor = Cursor.init(buffer),
        .selection = Selection.init(buffer),
        .vim = nivi.vim.State.init(std.testing.allocator),
        .syntax = try nivi.syntax.Highlighter.init(std.testing.io, std.testing.allocator, null),
        .workspace = try nivi.Workspace.init(std.testing.allocator),
    };
    defer app.deinit();
    var frame = try nivi.render.FrameRenderer.init(std.testing.allocator, 40, 8);
    defer frame.deinit();
    try app.workspace.toggleUndoTree();
    app.workspace.layout(frame.current.rect());

    try app.handleKey(.{ .char = 'i' });
    try app.handleKey(.{ .char = 'a' });
    try app.workspace.refresh(&buffer);
    try app.workspace.renderComponents(&frame, &buffer, 0);
    try app.handleKey(.{ .char = 'b' });
    try app.workspace.refresh(&buffer);
    try app.workspace.renderComponents(&frame, &buffer, 0);
    try app.handleKey(.escape);
    try app.handleKey(.{ .char = 'u' });

    const text = try buffer.toOwnedSlice(std.testing.allocator);
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("", text);
}

test "command mode is available from undo tree focus" {
    var buffer = try Buffer.initFromText(std.testing.allocator, "");
    defer buffer.deinit();
    var app: App = .{
        .allocator = std.testing.allocator,
        .io = undefined,
        .buffer = &buffer,
        .cursor = Cursor.init(buffer),
        .selection = Selection.init(buffer),
        .vim = nivi.vim.State.init(std.testing.allocator),
        .syntax = try nivi.syntax.Highlighter.init(std.testing.io, std.testing.allocator, null),
        .workspace = try nivi.Workspace.init(std.testing.allocator),
    };
    defer app.deinit();
    try app.workspace.toggleUndoTree();

    try app.handleKey(.{ .char = ':' });
    try std.testing.expectEqual(Mode.command, app.mode);
}

test "key mapping toggles undo component" {
    var buffer = try Buffer.initFromText(std.testing.allocator, "");
    defer buffer.deinit();
    var app: App = .{
        .allocator = std.testing.allocator,
        .io = undefined,
        .buffer = &buffer,
        .cursor = Cursor.init(buffer),
        .selection = Selection.init(buffer),
        .vim = nivi.vim.State.init(std.testing.allocator),
        .syntax = try nivi.syntax.Highlighter.init(std.testing.io, std.testing.allocator, null),
        .workspace = try nivi.Workspace.init(std.testing.allocator),
    };
    defer app.deinit();

    for (",ut") |ch| try app.handleKey(.{ .char = ch });
    try std.testing.expect(app.workspace.isOpen(.undo_tree));
    try std.testing.expectEqual(nivi.component.Kind.undo_tree, app.workspace.focusedKind());

    for (",ut") |ch| try app.handleKey(.{ .char = ch });
    try std.testing.expect(!app.workspace.isOpen(.undo_tree));
    try std.testing.expectEqual(nivi.component.Kind.editor, app.workspace.focusedKind());
}

test "workspace focus keys and undo actions update the buffer" {
    var buffer = try Buffer.initFromText(std.testing.allocator, "");
    defer buffer.deinit();
    try buffer.insert(0, "a");
    try buffer.insert(1, "b");
    var app: App = .{
        .allocator = std.testing.allocator,
        .io = undefined,
        .buffer = &buffer,
        .cursor = Cursor.at(buffer, buffer.byteLen()),
        .selection = Selection.init(buffer),
        .vim = nivi.vim.State.init(std.testing.allocator),
        .syntax = try nivi.syntax.Highlighter.init(std.testing.io, std.testing.allocator, null),
        .workspace = try nivi.Workspace.init(std.testing.allocator),
    };
    defer app.deinit();
    try app.workspace.toggleUndoTree();
    try app.workspace.refresh(&buffer);
    app.workspace.layout(.{ .x = 0, .y = 0, .width = 100, .height = 20 });

    try app.handleKey(.{ .ctrl = 'h' });
    try std.testing.expectEqual(nivi.component.Kind.editor, app.workspace.focusedKind());
    try app.handleKey(.{ .ctrl = 'l' });
    try std.testing.expectEqual(nivi.component.Kind.undo_tree, app.workspace.focusedKind());

    try app.handleKey(.{ .char = 'k' });
    try app.handleKey(.enter);
    const text = try buffer.toOwnedSlice(std.testing.allocator);
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("a", text);
    try std.testing.expectEqual(@as(usize, 1), app.cursor.offset);
}

test "retained rendering clears stale editor and command cells" {
    var buffer = try Buffer.initFromText(std.testing.allocator, "long text");
    defer buffer.deinit();
    var app: App = .{
        .allocator = std.testing.allocator,
        .io = undefined,
        .buffer = &buffer,
        .cursor = Cursor.init(buffer),
        .selection = Selection.init(buffer),
        .vim = nivi.vim.State.init(std.testing.allocator),
        .syntax = try nivi.syntax.Highlighter.init(std.testing.io, std.testing.allocator, null),
        .workspace = try nivi.Workspace.init(std.testing.allocator),
    };
    defer app.deinit();
    var frame = try nivi.render.FrameRenderer.init(std.testing.allocator, 20, 5);
    defer frame.deinit();
    try app.setMessage("old message", .{});
    try app.render(&frame, monotonicNowNs());

    try buffer.setText("x");
    app.message.clearRetainingCapacity();
    try app.render(&frame, monotonicNowNs());

    const text_x = nivi.render.gutterWidth(buffer);
    try std.testing.expectEqualStrings("x", frame.current.cellAt(text_x, 0).slice());
    try std.testing.expectEqualStrings(" ", frame.current.cellAt(text_x + 1, 0).slice());
    try std.testing.expectEqualStrings(" ", frame.current.cellAt(0, frame.current.height - 1).slice());
}

test "syntax refresh is immediate until the budget is exceeded" {
    var buffer = try Buffer.initFromText(std.testing.allocator, "");
    defer buffer.deinit();
    var app: App = .{
        .allocator = std.testing.allocator,
        .io = undefined,
        .buffer = &buffer,
        .cursor = Cursor.init(buffer),
        .selection = Selection.init(buffer),
        .vim = nivi.vim.State.init(std.testing.allocator),
        .syntax = try nivi.syntax.Highlighter.init(std.testing.io, std.testing.allocator, "test.zig"),
        .workspace = try nivi.Workspace.init(std.testing.allocator),
    };
    defer app.deinit();
    if (!app.syntax.enabled()) return;
    app.syntax_generation = buffer.generation;

    app.setMode(.insert);
    try app.handleKey(.{ .char = 'a' });
    try std.testing.expectEqual(@as(i128, 0), app.syntax_refresh_after_ns);
    try std.testing.expect(app.syntaxRefreshDue(monotonicNowNs()));

    app.syntax_generation = buffer.generation;
    app.syntax_highlight_generation = buffer.generation;
    app.syntax_scheduler.defer_until_idle = true;
    try app.handleKey(.{ .char = 'b' });
    try std.testing.expect(app.syntax_refresh_after_ns > 0);
    try std.testing.expect(!app.syntaxRefreshDue(app.syntax_refresh_after_ns - 1));
    try std.testing.expect(app.syntaxRefreshDue(app.syntax_refresh_after_ns));
}

test "syntax scheduler records percentiles and recovers" {
    var scheduler: SyntaxScheduler = .{};
    scheduler.record(syntax_budget_ns + 1);
    try std.testing.expect(scheduler.defer_until_idle);
    try std.testing.expectEqual(@as(u64, 1), scheduler.latency.over_budget);

    scheduler.record(1_000);
    scheduler.record(2_000);
    try std.testing.expect(scheduler.defer_until_idle);
    scheduler.record(3_000);
    try std.testing.expect(!scheduler.defer_until_idle);
    try std.testing.expectEqual(@as(usize, 4), scheduler.latency.count);
    try std.testing.expect(scheduler.latency.averageNs() != 0);
    try std.testing.expect(scheduler.latency.percentileNs(99) >= syntax_budget_ns);
}

test "syntax command reports latency counters" {
    var buffer = try Buffer.initFromText(std.testing.allocator, "");
    defer buffer.deinit();
    var app: App = .{
        .allocator = std.testing.allocator,
        .io = undefined,
        .buffer = &buffer,
        .cursor = Cursor.init(buffer),
        .selection = Selection.init(buffer),
        .vim = nivi.vim.State.init(std.testing.allocator),
        .syntax = try nivi.syntax.Highlighter.init(std.testing.io, std.testing.allocator, null),
        .workspace = try nivi.Workspace.init(std.testing.allocator),
    };
    defer app.deinit();
    app.syntax_scheduler.record(1_000);
    try app.command.appendSlice(std.testing.allocator, "syntax");

    try app.executeCommand();

    try std.testing.expect(std.mem.startsWith(u8, app.message.items, "syntax n=1"));
    try std.testing.expect(std.mem.indexOf(u8, app.message.items, "p99=") != null);
    try std.testing.expect(std.mem.indexOf(u8, app.message.items, "mode=immediate") != null);
}

test "syntax highlight buffers swap atomically" {
    var buffer = try Buffer.initFromText(std.testing.allocator, "");
    defer buffer.deinit();
    var app: App = .{
        .allocator = std.testing.allocator,
        .io = undefined,
        .buffer = &buffer,
        .cursor = Cursor.init(buffer),
        .selection = Selection.init(buffer),
        .vim = nivi.vim.State.init(std.testing.allocator),
        .syntax = try nivi.syntax.Highlighter.init(std.testing.io, std.testing.allocator, null),
        .workspace = try nivi.Workspace.init(std.testing.allocator),
    };
    defer app.deinit();
    try app.syntax_highlights.append(std.testing.allocator, .{ .start = 0, .end = 1, .kind = .keyword });
    try app.syntax_highlights_back.append(std.testing.allocator, .{ .start = 2, .end = 3, .kind = .string });

    app.swapSyntaxHighlights();

    try std.testing.expectEqual(nivi.syntax.HighlightKind.string, app.syntax_highlights.items[0].kind);
    try std.testing.expectEqual(nivi.syntax.HighlightKind.keyword, app.syntax_highlights_back.items[0].kind);
}

test "cached syntax spans follow insert edits" {
    var buffer = try Buffer.initFromText(std.testing.allocator, "const x");
    defer buffer.deinit();
    var app: App = .{
        .allocator = std.testing.allocator,
        .io = undefined,
        .buffer = &buffer,
        .cursor = Cursor.init(buffer),
        .selection = Selection.init(buffer),
        .vim = nivi.vim.State.init(std.testing.allocator),
        .syntax = try nivi.syntax.Highlighter.init(std.testing.io, std.testing.allocator, null),
        .workspace = try nivi.Workspace.init(std.testing.allocator),
        .syntax_highlight_generation = buffer.generation,
    };
    defer app.deinit();
    try app.syntax_highlights.append(std.testing.allocator, .{ .start = 0, .end = 5, .kind = .keyword });
    try app.syntax_highlights.append(std.testing.allocator, .{ .start = 6, .end = 7, .kind = .type });

    const previous_generation = buffer.generation;
    try buffer.insert(0, "a");
    app.adjustSyntaxHighlightsForLastEdit(previous_generation);

    try std.testing.expectEqual(@as(usize, 2), app.syntax_highlights.items.len);
    try std.testing.expectEqual(@as(usize, 1), app.syntax_highlights.items[0].start);
    try std.testing.expectEqual(@as(usize, 6), app.syntax_highlights.items[0].end);
    try std.testing.expectEqual(@as(usize, 7), app.syntax_highlights.items[1].start);
    try std.testing.expectEqual(@as(usize, 8), app.syntax_highlights.items[1].end);
}

test "cached syntax drops edited span and shifts later spans" {
    var buffer = try Buffer.initFromText(std.testing.allocator, "const x");
    defer buffer.deinit();
    var app: App = .{
        .allocator = std.testing.allocator,
        .io = undefined,
        .buffer = &buffer,
        .cursor = Cursor.init(buffer),
        .selection = Selection.init(buffer),
        .vim = nivi.vim.State.init(std.testing.allocator),
        .syntax = try nivi.syntax.Highlighter.init(std.testing.io, std.testing.allocator, null),
        .workspace = try nivi.Workspace.init(std.testing.allocator),
        .syntax_highlight_generation = buffer.generation,
    };
    defer app.deinit();
    try app.syntax_highlights.append(std.testing.allocator, .{ .start = 0, .end = 5, .kind = .keyword });
    try app.syntax_highlights.append(std.testing.allocator, .{ .start = 6, .end = 7, .kind = .type });

    const previous_generation = buffer.generation;
    try buffer.insert(2, "z");
    app.adjustSyntaxHighlightsForLastEdit(previous_generation);

    try std.testing.expectEqual(@as(usize, 1), app.syntax_highlights.items.len);
    try std.testing.expectEqual(@as(usize, 7), app.syntax_highlights.items[0].start);
    try std.testing.expectEqual(@as(usize, 8), app.syntax_highlights.items[0].end);
}

test "query indentation applies to open-line and enter" {
    var buffer = try Buffer.initFromText(std.testing.allocator, "fn main() void {\n}\n");
    defer buffer.deinit();
    var app: App = .{
        .allocator = std.testing.allocator,
        .io = undefined,
        .buffer = &buffer,
        .cursor = Cursor.init(buffer),
        .selection = Selection.init(buffer),
        .vim = nivi.vim.State.init(std.testing.allocator),
        .syntax = try nivi.syntax.Highlighter.init(std.testing.io, std.testing.allocator, "test.zig"),
        .workspace = try nivi.Workspace.init(std.testing.allocator),
    };
    defer app.deinit();
    if (!app.syntax.enabled()) return;

    try app.handleKey(.{ .char = 'o' });
    try app.handleKey(.{ .char = 'x' });
    try app.handleKey(.enter);
    try app.handleKey(.escape);

    const text = try buffer.toOwnedSlice(std.testing.allocator);
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("fn main() void {\n    x\n    \n}\n", text);
}

test "query indentation applies to open-line above" {
    var buffer = try Buffer.initFromText(std.testing.allocator, "fn main() void {\n}\n");
    defer buffer.deinit();
    var app: App = .{
        .allocator = std.testing.allocator,
        .io = undefined,
        .buffer = &buffer,
        .cursor = Cursor.at(buffer, buffer.byteOffsetForLine(1)),
        .selection = Selection.init(buffer),
        .vim = nivi.vim.State.init(std.testing.allocator),
        .syntax = try nivi.syntax.Highlighter.init(std.testing.io, std.testing.allocator, "test.zig"),
        .workspace = try nivi.Workspace.init(std.testing.allocator),
    };
    defer app.deinit();
    if (!app.syntax.enabled()) return;

    try app.handleKey(.{ .char = 'O' });
    try app.handleKey(.escape);

    const text = try buffer.toOwnedSlice(std.testing.allocator);
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("fn main() void {\n    \n}\n", text);
}

test "closing delimiter reindents incomplete syntax" {
    var buffer = try Buffer.initFromText(std.testing.allocator, "fn main() void {\n        ");
    defer buffer.deinit();
    var app: App = .{
        .allocator = std.testing.allocator,
        .io = undefined,
        .buffer = &buffer,
        .cursor = Cursor.at(buffer, buffer.byteLen()),
        .selection = Selection.init(buffer),
        .vim = nivi.vim.State.init(std.testing.allocator),
        .syntax = try nivi.syntax.Highlighter.init(std.testing.io, std.testing.allocator, "test.zig"),
        .workspace = try nivi.Workspace.init(std.testing.allocator),
        .mode = .insert,
    };
    defer app.deinit();
    if (!app.syntax.enabled()) return;

    try app.handleKey(.{ .char = '}' });
    try std.testing.expectEqual(@as(i128, 0), app.syntax_refresh_after_ns);

    const text = try buffer.toOwnedSlice(std.testing.allocator);
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("fn main() void {\n}", text);
}

test "indentation falls back without a grammar" {
    var buffer = try Buffer.initFromText(std.testing.allocator, "if condition {\n");
    defer buffer.deinit();
    var app: App = .{
        .allocator = std.testing.allocator,
        .io = undefined,
        .buffer = &buffer,
        .cursor = Cursor.at(buffer, buffer.byteLen()),
        .selection = Selection.init(buffer),
        .vim = nivi.vim.State.init(std.testing.allocator),
        .syntax = try nivi.syntax.Highlighter.init(std.testing.io, std.testing.allocator, null),
        .workspace = try nivi.Workspace.init(std.testing.allocator),
        .mode = .insert,
    };
    defer app.deinit();

    try app.handleKey(.enter);

    const text = try buffer.toOwnedSlice(std.testing.allocator);
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("if condition {\n\n    ", text);
}
