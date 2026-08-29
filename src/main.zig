const std = @import("std");
const nivi = @import("nivi");

const Io = std.Io;
const Buffer = nivi.Buffer;
const Cursor = nivi.Cursor;
const Key = nivi.input.Key;
const Rect = nivi.render.Rect;

const Mode = enum { normal, insert, command };

const App = struct {
    allocator: std.mem.Allocator,
    io: Io,
    buffer: *Buffer,
    cursor: Cursor,
    mode: Mode = .normal,
    first_line: usize = 0,
    first_column: usize = 0,
    editor_area: Rect = .{ .x = 0, .y = 0, .width = 0, .height = 1 },
    cursor_line: usize = 0,
    cursor_visual_column: usize = 0,
    command: std.ArrayListUnmanaged(u8) = .empty,
    message: std.ArrayListUnmanaged(u8) = .empty,
    render_scratch: std.ArrayListUnmanaged(u8) = .empty,
    should_quit: bool = false,

    fn deinit(self: *App) void {
        self.command.deinit(self.allocator);
        self.message.deinit(self.allocator);
        self.render_scratch.deinit(self.allocator);
    }

    fn setMessage(self: *App, comptime fmt: []const u8, args: anytype) !void {
        self.message.clearRetainingCapacity();
        var buf: [256]u8 = undefined;
        const text = std.fmt.bufPrint(&buf, fmt, args) catch "message too long";
        try self.message.appendSlice(self.allocator, text);
    }

    fn handleKey(self: *App, key: Key) !void {
        switch (self.mode) {
            .normal => try self.handleNormal(key),
            .insert => try self.handleInsert(key),
            .command => try self.handleCommand(key),
        }
        try self.keepCursorVisible();
    }

    fn refreshCursorMetrics(self: *App) !void {
        self.cursor_line = try self.cursor.line(self.buffer.*);
        self.cursor_visual_column = try self.cursor.visualColumn(self.buffer.*);
    }

    fn handleNormal(self: *App, key: Key) !void {
        switch (key) {
            .char => |ch| switch (ch) {
                'i' => self.mode = .insert,
                ':' => {
                    self.command.clearRetainingCapacity();
                    self.mode = .command;
                },
                'h' => try self.cursor.moveLeft(self.buffer.*),
                'j' => try self.cursor.moveDown(self.buffer.*),
                'k' => try self.cursor.moveUp(self.buffer.*),
                'l' => try self.cursor.moveRight(self.buffer.*),
                '0' => try self.cursor.moveToLineStart(self.buffer.*),
                '$' => try self.cursor.moveToLineEnd(self.buffer.*),
                'x' => try self.cursor.deleteForward(self.buffer),
                'u' => if (try self.buffer.undo()) |offset| try self.cursor.setOffset(self.buffer.*, offset),
                'r' => if (try self.buffer.redo()) |offset| try self.cursor.setOffset(self.buffer.*, offset),
                else => {},
            },
            .arrow_left => try self.cursor.moveLeft(self.buffer.*),
            .arrow_right => try self.cursor.moveRight(self.buffer.*),
            .arrow_up => try self.cursor.moveUp(self.buffer.*),
            .arrow_down => try self.cursor.moveDown(self.buffer.*),
            .home => try self.cursor.moveToLineStart(self.buffer.*),
            .end => try self.cursor.moveToLineEnd(self.buffer.*),
            else => {},
        }
    }

    fn handleInsert(self: *App, key: Key) !void {
        switch (key) {
            .escape => self.mode = .normal,
            .enter => try self.cursor.insertText(self.buffer, "\n"),
            .backspace => try self.cursor.deleteBackward(self.buffer),
            .delete => try self.cursor.deleteForward(self.buffer),
            .arrow_left => try self.cursor.moveLeft(self.buffer.*),
            .arrow_right => try self.cursor.moveRight(self.buffer.*),
            .arrow_up => try self.cursor.moveUp(self.buffer.*),
            .arrow_down => try self.cursor.moveDown(self.buffer.*),
            .char => |ch| {
                var bytes: [4]u8 = undefined;
                const len = try std.unicode.utf8Encode(ch, &bytes);
                try self.cursor.insertText(self.buffer, bytes[0..len]);
            },
            else => {},
        }
    }

    fn handleCommand(self: *App, key: Key) !void {
        switch (key) {
            .escape => self.mode = .normal,
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
        self.mode = .normal;

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

    fn render(self: *App, frame: *nivi.render.FrameRenderer) !void {
        try self.refreshCursorMetrics();
        frame.beginFrame(.{});
        const screen = frame.current.rect();
        const command_split = screen.splitBottom(1);
        const status_split = command_split.second.splitBottom(1);
        const editor_area = status_split.second;
        const status_area = status_split.first;
        const command_area = command_split.first;
        self.editor_area = editor_area;

        try nivi.render.renderBufferViewportScratch(self.allocator, &self.render_scratch, &frame.current, editor_area, self.buffer.*, .{
            .first_line = self.first_line,
            .first_column = self.first_column,
            .cursor_line = self.cursor_line,
            .relative_line_numbers = true,
        });
        try frame.markDirty(editor_area);
        self.renderStatus(&frame.current, status_area);
        try frame.markDirty(status_area);
        self.renderCommand(&frame.current, command_area);
        try frame.markDirty(command_area);
    }

    fn placeTerminalCursor(self: *App, writer: *Io.Writer, screen: Rect) !void {
        const shape: nivi.render.AnsiRenderer.CursorShape = switch (self.mode) {
            .insert => .bar,
            .normal, .command => .block,
        };
        try nivi.render.AnsiRenderer.setCursorShape(writer, shape);

        const command_area = screen.splitBottom(1).first;
        if (self.mode == .command) {
            const x = @min(command_area.x + 1 + self.command.items.len, command_area.right() -| 1);
            try nivi.render.AnsiRenderer.cursorTo(writer, x, command_area.y);
            try nivi.render.AnsiRenderer.showCursor(writer);
            return;
        }

        const editor_area = screen.splitBottom(1).second.splitBottom(1).second;
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
        };
        const line = self.cursor_line + 1;
        const col = self.cursor_visual_column + 1;
        const text = std.fmt.bufPrint(&buf, " {s} {s}{s}  {d}:{d}  {d} bytes", .{ mode, name, if (self.buffer.dirty) " [+]" else "", line, col, self.buffer.byteLen() }) catch " status error";
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

    var app: App = .{ .allocator = allocator, .io = io, .buffer = buffer, .cursor = Cursor.init(buffer.*) };
    defer app.deinit();

    // Bytes read but not yet consumed (an escape/UTF-8 sequence split across
    // reads). Retained across iterations so partial sequences never leak as
    // literal input.
    var pending: [256]u8 = undefined;
    var pending_len: usize = 0;
    var read_buf: [256]u8 = undefined;
    while (!app.should_quit) {
        try app.render(&frame);
        try nivi.render.AnsiRenderer.hideCursor(stdout);
        try frame.present(stdout);
        try app.placeTerminalCursor(stdout, frame.current.rect());
        try stdout.flush();

        const n = try std.posix.read(std.posix.STDIN_FILENO, &read_buf);
        if (n == 0) {
            // Timeout with a lone pending ESC resolves to an Escape keypress;
            // any other stale partial sequence is dropped.
            if (pending_len == 1 and pending[0] == 0x1b) try app.handleKey(.escape);
            pending_len = 0;
            continue;
        }

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
