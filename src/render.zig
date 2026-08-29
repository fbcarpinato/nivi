const std = @import("std");
const Buffer = @import("buffer.zig").Buffer;

pub const Color = enum(u8) {
    default,
    gutter,
    status,
    selection,
    accent,
};

pub const Style = struct {
    fg: Color = .default,
    bg: Color = .default,
    bold: bool = false,
    inverse: bool = false,
};

pub const Cell = struct {
    bytes: [4]u8 = .{ ' ', 0, 0, 0 },
    len: u3 = 1,
    style: Style = .{},

    pub fn space(style: Style) Cell {
        return .{ .style = style };
    }

    pub fn ascii(byte: u8, style: Style) Cell {
        return .{ .bytes = .{ byte, 0, 0, 0 }, .len = 1, .style = style };
    }

    pub fn slice(self: Cell) []const u8 {
        return self.bytes[0..self.len];
    }

    pub fn eql(a: Cell, b: Cell) bool {
        return a.len == b.len and std.mem.eql(u8, &a.bytes, &b.bytes) and std.meta.eql(a.style, b.style);
    }
};

pub const Rect = struct {
    x: usize,
    y: usize,
    width: usize,
    height: usize,

    pub fn right(self: Rect) usize {
        return self.x + self.width;
    }

    pub fn bottom(self: Rect) usize {
        return self.y + self.height;
    }

    pub fn contains(self: Rect, x: usize, y: usize) bool {
        return x >= self.x and x < self.right() and y >= self.y and y < self.bottom();
    }

    pub fn splitLeft(self: Rect, width: usize) Split {
        const left_width = @min(width, self.width);
        return .{
            .first = .{ .x = self.x, .y = self.y, .width = left_width, .height = self.height },
            .second = .{ .x = self.x + left_width, .y = self.y, .width = self.width - left_width, .height = self.height },
        };
    }

    pub fn splitRight(self: Rect, width: usize) Split {
        const right_width = @min(width, self.width);
        return .{
            .first = .{ .x = self.x + self.width - right_width, .y = self.y, .width = right_width, .height = self.height },
            .second = .{ .x = self.x, .y = self.y, .width = self.width - right_width, .height = self.height },
        };
    }

    pub fn splitTop(self: Rect, height: usize) Split {
        const top_height = @min(height, self.height);
        return .{
            .first = .{ .x = self.x, .y = self.y, .width = self.width, .height = top_height },
            .second = .{ .x = self.x, .y = self.y + top_height, .width = self.width, .height = self.height - top_height },
        };
    }

    pub fn splitBottom(self: Rect, height: usize) Split {
        const bottom_height = @min(height, self.height);
        return .{
            .first = .{ .x = self.x, .y = self.y + self.height - bottom_height, .width = self.width, .height = bottom_height },
            .second = .{ .x = self.x, .y = self.y, .width = self.width, .height = self.height - bottom_height },
        };
    }

    pub fn centered(self: Rect, width: usize, height: usize) Rect {
        const w = @min(width, self.width);
        const h = @min(height, self.height);
        return .{ .x = self.x + (self.width - w) / 2, .y = self.y + (self.height - h) / 2, .width = w, .height = h };
    }
};

pub const Split = struct {
    first: Rect,
    second: Rect,
};

pub const ViewKind = enum {
    root,
    editor,
    line_bar,
    statusline,
    side_panel,
    picker_overlay,
    custom,
};

pub const View = struct {
    id: u32,
    parent: ?u32,
    rect: Rect,
    kind: ViewKind,
    z_index: i16 = 0,
};

pub const ViewTree = struct {
    allocator: std.mem.Allocator,
    views: std.ArrayListUnmanaged(View) = .empty,
    next_id: u32 = 1,

    pub fn init(allocator: std.mem.Allocator) ViewTree {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *ViewTree) void {
        self.views.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn clear(self: *ViewTree) void {
        self.views.clearRetainingCapacity();
        self.next_id = 1;
    }

    pub fn addRoot(self: *ViewTree, rect: Rect) !u32 {
        return self.add(null, rect, .root, 0);
    }

    pub fn addChild(self: *ViewTree, parent: u32, rect: Rect, kind: ViewKind) !u32 {
        return self.add(parent, rect, kind, 0);
    }

    pub fn addOverlay(self: *ViewTree, parent: u32, rect: Rect, kind: ViewKind) !u32 {
        return self.add(parent, rect, kind, 1000);
    }

    pub fn byId(self: *ViewTree, id: u32) ?*View {
        for (self.views.items) |*view| if (view.id == id) return view;
        return null;
    }

    fn add(self: *ViewTree, parent: ?u32, rect: Rect, kind: ViewKind, z_index: i16) !u32 {
        const id = self.next_id;
        self.next_id += 1;
        try self.views.append(self.allocator, .{ .id = id, .parent = parent, .rect = rect, .kind = kind, .z_index = z_index });
        return id;
    }
};

pub const Surface = struct {
    allocator: std.mem.Allocator,
    width: usize,
    height: usize,
    cells: []Cell,

    pub fn init(allocator: std.mem.Allocator, width: usize, height: usize) !Surface {
        const cells = try allocator.alloc(Cell, width * height);
        var surface: Surface = .{ .allocator = allocator, .width = width, .height = height, .cells = cells };
        surface.clear(.{});
        return surface;
    }

    pub fn deinit(self: *Surface) void {
        self.allocator.free(self.cells);
        self.* = undefined;
    }

    pub fn rect(self: Surface) Rect {
        return .{ .x = 0, .y = 0, .width = self.width, .height = self.height };
    }

    pub fn clear(self: *Surface, style: Style) void {
        @memset(self.cells, Cell.space(style));
    }

    pub fn cellAt(self: Surface, x: usize, y: usize) *Cell {
        std.debug.assert(x < self.width and y < self.height);
        return &self.cells[y * self.width + x];
    }

    pub fn putCell(self: *Surface, x: usize, y: usize, cell: Cell) void {
        if (x >= self.width or y >= self.height) return;
        self.cells[y * self.width + x] = cell;
    }

    pub fn writeAscii(self: *Surface, x: usize, y: usize, max_width: usize, text: []const u8, style: Style) void {
        if (y >= self.height or x >= self.width) return;
        const end = @min(self.width, x + max_width);
        var col = x;
        for (text) |byte| {
            if (col >= end) break;
            self.putCell(col, y, Cell.ascii(if (std.ascii.isPrint(byte)) byte else '?', style));
            col += 1;
        }
    }

    pub fn fillRect(self: *Surface, area: Rect, cell: Cell) void {
        const right = @min(self.width, area.right());
        const bottom = @min(self.height, area.bottom());
        var y = area.y;
        while (y < bottom) : (y += 1) {
            var x = area.x;
            while (x < right) : (x += 1) self.putCell(x, y, cell);
        }
    }

    pub fn writeTo(self: Surface, writer: *std.Io.Writer) !void {
        for (0..self.height) |y| {
            for (0..self.width) |x| try writer.writeAll(self.cellAt(x, y).slice());
            try writer.writeByte('\n');
        }
    }

    pub fn copyFrom(self: *Surface, other: Surface) void {
        std.debug.assert(self.width == other.width and self.height == other.height);
        @memcpy(self.cells, other.cells);
    }
};

pub const AnsiRenderer = struct {
    pub const CursorShape = enum {
        block,
        bar,
        underline,
    };

    pub fn enterAltScreen(writer: *std.Io.Writer) !void {
        try writer.writeAll("\x1b[?1049h\x1b[?25l");
    }

    pub fn leaveAltScreen(writer: *std.Io.Writer) !void {
        try writer.writeAll("\x1b[0m\x1b[?25h\x1b[?1049l");
    }

    pub fn clear(writer: *std.Io.Writer) !void {
        try writer.writeAll("\x1b[2J");
    }

    pub fn showCursor(writer: *std.Io.Writer) !void {
        try writer.writeAll("\x1b[?25h");
    }

    pub fn hideCursor(writer: *std.Io.Writer) !void {
        try writer.writeAll("\x1b[?25l");
    }

    pub fn setCursorShape(writer: *std.Io.Writer, shape: CursorShape) !void {
        const code: u8 = switch (shape) {
            .block => 2,
            .underline => 4,
            .bar => 6,
        };
        try writer.print("\x1b[{d} q", .{code});
    }

    pub fn cursorTo(writer: *std.Io.Writer, x: usize, y: usize) !void {
        try moveCursor(writer, x, y);
    }

    pub fn renderFull(writer: *std.Io.Writer, current: Surface) !void {
        try moveCursor(writer, 0, 0);
        var active_style: Style = .{};
        try setStyle(writer, active_style);
        for (0..current.height) |y| {
            try moveCursor(writer, 0, y);
            for (0..current.width) |x| {
                const cell = current.cellAt(x, y).*;
                if (!std.meta.eql(cell.style, active_style)) {
                    active_style = cell.style;
                    try setStyle(writer, active_style);
                }
                try writer.writeAll(cell.slice());
            }
        }
        try setStyle(writer, .{});
    }

    pub fn renderDiff(writer: *std.Io.Writer, previous: Surface, current: Surface) !void {
        std.debug.assert(previous.width == current.width and previous.height == current.height);
        var active_style: Style = .{};
        try setStyle(writer, active_style);

        for (0..current.height) |y| {
            active_style = try renderDiffRow(writer, previous, current, y, 0, current.width, active_style);
        }
        try setStyle(writer, .{});
    }

    pub fn renderDiffRects(writer: *std.Io.Writer, previous: Surface, current: Surface, rects: []const Rect) !void {
        std.debug.assert(previous.width == current.width and previous.height == current.height);
        var active_style: Style = .{};
        try setStyle(writer, active_style);
        for (rects) |rect| {
            const right = @min(current.width, rect.right());
            const bottom = @min(current.height, rect.bottom());
            var y = rect.y;
            while (y < bottom) : (y += 1) {
                active_style = try renderDiffRow(writer, previous, current, y, rect.x, right, active_style);
            }
        }
        try setStyle(writer, .{});
    }

    fn renderDiffRow(writer: *std.Io.Writer, previous: Surface, current: Surface, y: usize, start_x: usize, end_x: usize, active_style: Style) !Style {
        var style = active_style;
        var x = start_x;
        while (x < end_x) {
            const current_cell = current.cellAt(x, y).*;
            if (Cell.eql(previous.cellAt(x, y).*, current_cell)) {
                x += 1;
                continue;
            }

            try moveCursor(writer, x, y);
            while (x < end_x) : (x += 1) {
                const cell = current.cellAt(x, y).*;
                if (Cell.eql(previous.cellAt(x, y).*, cell)) break;
                if (!std.meta.eql(cell.style, style)) {
                    style = cell.style;
                    try setStyle(writer, style);
                }
                try writer.writeAll(cell.slice());
            }
        }
        return style;
    }

    fn moveCursor(writer: *std.Io.Writer, x: usize, y: usize) !void {
        try writer.print("\x1b[{d};{d}H", .{ y + 1, x + 1 });
    }

    fn setStyle(writer: *std.Io.Writer, style: Style) !void {
        try writer.writeAll("\x1b[0");
        if (style.bold) try writer.writeAll(";1");
        if (style.inverse) try writer.writeAll(";7");
        try writeColor(writer, 30, style.fg);
        try writeColor(writer, 40, style.bg);
        try writer.writeByte('m');
    }

    fn writeColor(writer: *std.Io.Writer, base: u8, color: Color) !void {
        const code: ?u8 = switch (color) {
            .default => null,
            .gutter => base + 8,
            .status => base + 4,
            .selection => base + 6,
            .accent => base + 2,
        };
        if (code) |value| try writer.print(";{d}", .{value});
    }
};

pub const FrameRenderer = struct {
    previous: Surface,
    current: Surface,
    first_frame: bool = true,
    dirty_rects: std.ArrayListUnmanaged(Rect) = .empty,

    pub fn init(allocator: std.mem.Allocator, width: usize, height: usize) !FrameRenderer {
        return .{
            .previous = try Surface.init(allocator, width, height),
            .current = try Surface.init(allocator, width, height),
        };
    }

    pub fn deinit(self: *FrameRenderer) void {
        self.dirty_rects.deinit(self.current.allocator);
        self.current.deinit();
        self.previous.deinit();
        self.* = undefined;
    }

    pub fn beginFrame(self: *FrameRenderer, style: Style) void {
        self.current.clear(style);
        self.dirty_rects.clearRetainingCapacity();
    }

    pub fn markDirty(self: *FrameRenderer, rect: Rect) !void {
        if (rect.width == 0 or rect.height == 0) return;
        try self.dirty_rects.append(self.current.allocator, rect);
    }

    pub fn present(self: *FrameRenderer, writer: *std.Io.Writer) !void {
        if (self.first_frame) {
            try AnsiRenderer.renderFull(writer, self.current);
            self.first_frame = false;
        } else if (self.dirty_rects.items.len != 0) {
            try AnsiRenderer.renderDiffRects(writer, self.previous, self.current, self.dirty_rects.items);
        } else {
            try AnsiRenderer.renderDiff(writer, self.previous, self.current);
        }
        self.previous.copyFrom(self.current);
        self.dirty_rects.clearRetainingCapacity();
    }
};

pub const ViewportOptions = struct {
    first_line: usize = 0,
    cursor_line: usize = 0,
    line_numbers: bool = true,
    relative_line_numbers: bool = false,
    gutter_width: usize = 0,
    tab_width: usize = 4,
};

pub fn gutterWidth(buffer: Buffer) usize {
    return decimalWidth(@max(buffer.lineCount(), 1)) + 1;
}

pub fn renderBufferViewport(
    allocator: std.mem.Allocator,
    surface: *Surface,
    area: Rect,
    buffer: Buffer,
    options: ViewportOptions,
) !void {
    var scratch: std.ArrayListUnmanaged(u8) = .empty;
    defer scratch.deinit(allocator);
    try renderBufferViewportScratch(allocator, &scratch, surface, area, buffer, options);
}

pub fn renderBufferViewportScratch(
    allocator: std.mem.Allocator,
    scratch: *std.ArrayListUnmanaged(u8),
    surface: *Surface,
    area: Rect,
    buffer: Buffer,
    options: ViewportOptions,
) !void {
    if (area.width == 0 or area.height == 0) return;

    const gutter_width = if (options.line_numbers)
        @min(area.width, if (options.gutter_width == 0) gutterWidth(buffer) else options.gutter_width)
    else
        0;
    const text_x = area.x + gutter_width;
    const text_width = area.width - gutter_width;

    for (0..area.height) |row| {
        const y = area.y + row;
        if (y >= surface.height) break;
        const line = options.first_line + row;
        if (line >= buffer.lineCount()) break;

        if (gutter_width != 0) {
            const number = if (options.relative_line_numbers and line != options.cursor_line)
                distance(line, options.cursor_line)
            else
                line + 1;
            renderLineNumber(surface, area.x, y, gutter_width, number, line == options.cursor_line);
        }
        if (text_width == 0) continue;

        const range = buffer.lineContentRange(line);
        const line_len = range.end - range.start;
        const copy_len = @min(line_len, text_width * 4 + 16);
        try scratch.resize(allocator, copy_len);
        buffer.copyRange(scratch.items, range.start);
        renderLineText(surface, text_x, y, text_width, scratch.items, options.tab_width);
    }
}

fn renderLineNumber(surface: *Surface, x: usize, y: usize, width: usize, number: usize, active: bool) void {
    var buf: [32]u8 = undefined;
    const digits = std.fmt.bufPrint(&buf, "{d}", .{number}) catch unreachable;
    const padding = width - @min(width, digits.len + 1);
    const style: Style = if (active) .{ .fg = .accent, .bold = true } else .{ .fg = .gutter };
    var col = x;
    for (0..padding) |_| {
        surface.putCell(col, y, Cell.ascii(' ', style));
        col += 1;
    }
    surface.writeAscii(col, y, width - padding, digits, style);
    surface.putCell(x + width - 1, y, Cell.ascii(' ', style));
}

fn distance(a: usize, b: usize) usize {
    return if (a > b) a - b else b - a;
}

fn renderLineText(surface: *Surface, x: usize, y: usize, width: usize, text: []const u8, tab_width: usize) void {
    var col: usize = 0;
    var index: usize = 0;
    while (index < text.len and col < width) {
        const byte = text[index];
        if (byte == '\t') {
            const spaces = @max(@as(usize, 1), tab_width - (col % tab_width));
            var n: usize = 0;
            while (n < spaces and col < width) : (n += 1) {
                surface.putCell(x + col, y, Cell.ascii(' ', .{}));
                col += 1;
            }
            index += 1;
            continue;
        }
        if (byte < 0x80) {
            surface.putCell(x + col, y, Cell.ascii(if (std.ascii.isPrint(byte)) byte else '?', .{}));
            col += 1;
            index += 1;
            continue;
        }

        const len = utf8Len(byte) orelse {
            surface.putCell(x + col, y, Cell.ascii('?', .{}));
            col += 1;
            index += 1;
            continue;
        };
        if (index + len > text.len) break;
        var cell = Cell.space(.{});
        @memcpy(cell.bytes[0..len], text[index .. index + len]);
        cell.len = @intCast(len);
        surface.putCell(x + col, y, cell);
        col += 1;
        index += len;
    }
}

fn utf8Len(first: u8) ?usize {
    if ((first & 0b1110_0000) == 0b1100_0000) return 2;
    if ((first & 0b1111_0000) == 0b1110_0000) return 3;
    if ((first & 0b1111_1000) == 0b1111_0000) return 4;
    return null;
}

fn decimalWidth(value: usize) usize {
    var width: usize = 1;
    var n = value;
    while (n >= 10) : (n /= 10) width += 1;
    return width;
}

test "surface writes clipped ascii" {
    var surface = try Surface.init(std.testing.allocator, 4, 2);
    defer surface.deinit();

    surface.writeAscii(1, 0, 2, "abcd", .{});
    try std.testing.expectEqualStrings(" ", surface.cellAt(0, 0).slice());
    try std.testing.expectEqualStrings("a", surface.cellAt(1, 0).slice());
    try std.testing.expectEqualStrings("b", surface.cellAt(2, 0).slice());
    try std.testing.expectEqualStrings(" ", surface.cellAt(3, 0).slice());
}

test "surface fills rect with style" {
    var surface = try Surface.init(std.testing.allocator, 4, 2);
    defer surface.deinit();

    const style: Style = .{ .fg = .status, .inverse = true };
    surface.fillRect(.{ .x = 1, .y = 0, .width = 3, .height = 1 }, Cell.ascii(' ', style));

    try std.testing.expect(!surface.cellAt(0, 0).style.inverse);
    try std.testing.expect(surface.cellAt(1, 0).style.inverse);
    try std.testing.expect(surface.cellAt(3, 0).style.inverse);
    try std.testing.expect(!surface.cellAt(1, 1).style.inverse);
}

test "ansi cursor shape and visibility controls" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    try AnsiRenderer.hideCursor(&out.writer);
    try AnsiRenderer.setCursorShape(&out.writer, .bar);
    try AnsiRenderer.showCursor(&out.writer);
    try out.writer.flush();

    const written = out.written();
    try std.testing.expect(std.mem.indexOf(u8, written, "\x1b[?25l") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "\x1b[6 q") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "\x1b[?25h") != null);
}

test "viewport renders line numbers and text without flattening whole buffer" {
    var buffer = try Buffer.initFromText(std.testing.allocator, "one\ntwo\nthree");
    defer buffer.deinit();
    var surface = try Surface.init(std.testing.allocator, 8, 2);
    defer surface.deinit();

    try renderBufferViewport(std.testing.allocator, &surface, surface.rect(), buffer, .{ .first_line = 1 });

    try std.testing.expectEqualStrings("2", surface.cellAt(0, 0).slice());
    try std.testing.expectEqualStrings(" ", surface.cellAt(1, 0).slice());
    try std.testing.expectEqualStrings("t", surface.cellAt(2, 0).slice());
    try std.testing.expectEqualStrings("w", surface.cellAt(3, 0).slice());
    try std.testing.expectEqualStrings("o", surface.cellAt(4, 0).slice());
    try std.testing.expectEqualStrings("3", surface.cellAt(0, 1).slice());
    try std.testing.expectEqualStrings("t", surface.cellAt(2, 1).slice());
}

test "viewport renders relative line numbers around cursor" {
    var buffer = try Buffer.initFromText(std.testing.allocator, "one\ntwo\nthree\nfour");
    defer buffer.deinit();
    var surface = try Surface.init(std.testing.allocator, 8, 4);
    defer surface.deinit();

    try renderBufferViewport(std.testing.allocator, &surface, surface.rect(), buffer, .{ .cursor_line = 2, .relative_line_numbers = true });

    try std.testing.expectEqualStrings("2", surface.cellAt(0, 0).slice());
    try std.testing.expectEqualStrings("1", surface.cellAt(0, 1).slice());
    try std.testing.expectEqualStrings("3", surface.cellAt(0, 2).slice());
    try std.testing.expectEqualStrings("1", surface.cellAt(0, 3).slice());
    try std.testing.expect(surface.cellAt(0, 2).style.bold);
}

test "viewport relative numbers respect scrolled first line" {
    var buffer = try Buffer.initFromText(std.testing.allocator, "one\ntwo\nthree\nfour\nfive");
    defer buffer.deinit();
    var surface = try Surface.init(std.testing.allocator, 8, 2);
    defer surface.deinit();

    try renderBufferViewport(std.testing.allocator, &surface, surface.rect(), buffer, .{ .first_line = 2, .cursor_line = 3, .relative_line_numbers = true });

    try std.testing.expectEqualStrings("1", surface.cellAt(0, 0).slice());
    try std.testing.expectEqualStrings("4", surface.cellAt(0, 1).slice());
    try std.testing.expect(surface.cellAt(0, 1).style.bold);
}

test "viewport expands tabs" {
    var buffer = try Buffer.initFromText(std.testing.allocator, "a\tb");
    defer buffer.deinit();
    var surface = try Surface.init(std.testing.allocator, 8, 1);
    defer surface.deinit();

    try renderBufferViewport(std.testing.allocator, &surface, surface.rect(), buffer, .{ .line_numbers = false, .tab_width = 4 });

    try std.testing.expectEqualStrings("a", surface.cellAt(0, 0).slice());
    try std.testing.expectEqualStrings(" ", surface.cellAt(1, 0).slice());
    try std.testing.expectEqualStrings(" ", surface.cellAt(2, 0).slice());
    try std.testing.expectEqualStrings(" ", surface.cellAt(3, 0).slice());
    try std.testing.expectEqualStrings("b", surface.cellAt(4, 0).slice());
}

test "viewport clips very long lines to visible byte budget" {
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(std.testing.allocator);
    try text.appendNTimes(std.testing.allocator, 'x', 4096);

    var buffer = try Buffer.initFromText(std.testing.allocator, text.items);
    defer buffer.deinit();
    var surface = try Surface.init(std.testing.allocator, 10, 1);
    defer surface.deinit();

    try renderBufferViewport(std.testing.allocator, &surface, surface.rect(), buffer, .{ .line_numbers = false });

    for (0..10) |x| try std.testing.expectEqualStrings("x", surface.cellAt(x, 0).slice());
}

test "rect splits and centered overlay" {
    const root: Rect = .{ .x = 0, .y = 0, .width = 100, .height = 40 };
    const status = root.splitBottom(1);
    try std.testing.expectEqual(@as(usize, 39), status.first.y);
    try std.testing.expectEqual(@as(usize, 39), status.second.height);

    const side = status.second.splitLeft(24);
    try std.testing.expectEqual(@as(usize, 24), side.first.width);
    try std.testing.expectEqual(@as(usize, 76), side.second.width);

    const picker = root.centered(60, 20);
    try std.testing.expectEqual(@as(usize, 20), picker.x);
    try std.testing.expectEqual(@as(usize, 10), picker.y);
}

test "view tree records component regions" {
    var tree = ViewTree.init(std.testing.allocator);
    defer tree.deinit();

    const root = try tree.addRoot(.{ .x = 0, .y = 0, .width = 120, .height = 50 });
    const root_view = tree.byId(root).?;
    const status_split = root_view.rect.splitBottom(1);
    const status = try tree.addChild(root, status_split.first, .statusline);
    const editor = try tree.addChild(root, status_split.second, .editor);
    const picker = try tree.addOverlay(root, root_view.rect.centered(80, 20), .picker_overlay);

    try std.testing.expectEqual(ViewKind.statusline, tree.byId(status).?.kind);
    try std.testing.expectEqual(ViewKind.editor, tree.byId(editor).?.kind);
    try std.testing.expectEqual(@as(i16, 1000), tree.byId(picker).?.z_index);
}

test "ansi diff only emits changed cells" {
    var previous = try Surface.init(std.testing.allocator, 3, 1);
    defer previous.deinit();
    var current = try Surface.init(std.testing.allocator, 3, 1);
    defer current.deinit();
    previous.writeAscii(0, 0, 3, "abc", .{});
    current.writeAscii(0, 0, 3, "axc", .{});
    try std.testing.expect(!Cell.eql(previous.cellAt(1, 0).*, current.cellAt(1, 0).*));

    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try AnsiRenderer.renderDiff(&out.writer, previous, current);
    try out.writer.flush();

    const written = out.written();
    try std.testing.expect(std.mem.indexOfScalar(u8, written, 'x') != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "abc") == null);
}

test "frame renderer swaps current into previous after present" {
    var renderer = try FrameRenderer.init(std.testing.allocator, 4, 1);
    defer renderer.deinit();

    renderer.beginFrame(.{});
    renderer.current.writeAscii(0, 0, 4, "abcd", .{});

    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try renderer.present(&out.writer);

    try std.testing.expect(!renderer.first_frame);
    try std.testing.expect(Cell.eql(renderer.previous.cellAt(2, 0).*, renderer.current.cellAt(2, 0).*));
}
