const std = @import("std");
const api = @import("component_api.zig");
const Key = @import("input.zig").Key;
const Render = @import("render.zig");
const UndoTree = @import("undotree.zig").UndoTree;
const Node = @import("undotree.zig").Node;

pub const UndoTreePanel = struct {
    pub const preferred_width = 32;

    const Row = struct {
        seq: u64,
        depth: usize,
        timestamp: i64,
        has_children: bool,
        is_root: bool,
    };

    allocator: std.mem.Allocator,
    rows: std.ArrayListUnmanaged(Row) = .empty,
    stack: std.ArrayListUnmanaged(*Node) = .empty,
    selected_index: usize = 0,
    selected_seq: u64 = 0,
    first_row: usize = 0,
    viewport_rows: usize = 0,
    cached_structure_generation: u64 = 0,
    cached_state_generation: u64 = 0,
    cached_epoch: u64 = 0,

    pub fn init(allocator: std.mem.Allocator) UndoTreePanel {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *UndoTreePanel) void {
        self.rows.deinit(self.allocator);
        self.stack.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn refresh(self: *UndoTreePanel, tree: *const UndoTree) !bool {
        if (self.cached_epoch == tree.epoch and self.cached_structure_generation == tree.structure_generation) {
            if (self.cached_state_generation == tree.state_generation) return false;
            self.cached_state_generation = tree.state_generation;
            return true;
        }
        const preserve_seq = if (self.cached_epoch == tree.epoch) self.selected_seq else tree.current.seq;
        self.rows.clearRetainingCapacity();
        self.stack.clearRetainingCapacity();
        try self.stack.append(self.allocator, tree.root);
        while (self.stack.pop()) |node| {
            try self.rows.append(self.allocator, .{
                .seq = node.seq,
                .depth = node.depth,
                .timestamp = node.timestamp,
                .has_children = node.children.items.len != 0,
                .is_root = node.parent == null,
            });
            var index = node.children.items.len;
            while (index > 0) {
                index -= 1;
                try self.stack.append(self.allocator, node.children.items[index]);
            }
        }
        self.cached_epoch = tree.epoch;
        self.cached_structure_generation = tree.structure_generation;
        self.cached_state_generation = tree.state_generation;
        self.selectSeq(if (self.indexForSeq(preserve_seq) != null) preserve_seq else tree.current.seq);
        return true;
    }

    pub fn selectCurrent(self: *UndoTreePanel, tree: *const UndoTree) void {
        self.selectSeq(tree.current.seq);
    }

    pub fn setArea(self: *UndoTreePanel, area: Render.Rect) void {
        self.viewport_rows = area.height -| 1;
        self.keepSelectionVisible();
    }

    pub fn handleKey(self: *UndoTreePanel, key: Key) api.Action {
        return switch (key) {
            .escape => .{ .focus = .left },
            .enter => self.jumpAction(),
            .arrow_up => self.move(.up),
            .arrow_down => self.move(.down),
            .char => |ch| switch (ch) {
                'h' => .{ .focus = .left },
                'j' => self.move(.down),
                'k' => self.move(.up),
                'o' => self.jumpAction(),
                else => .none,
            },
            else => .none,
        };
    }

    pub fn render(self: *UndoTreePanel, surface: *Render.Surface, area: Render.Rect, tree: *const UndoTree, focused: bool, now: i64) void {
        if (area.width == 0 or area.height == 0) return;
        self.setArea(area);
        const panel_style: Render.Style = .{ .fg = .gutter };
        surface.fillRect(area, .space(panel_style));
        for (0..area.height) |row| surface.putCell(area.x, area.y + row, .ascii('|', .{ .fg = .gutter }));
        if (area.width <= 1) return;
        const content_x = area.x + 1;
        const content_width = area.width - 1;
        surface.writeAscii(content_x, area.y, content_width, " UNDO TREE", .{ .fg = .accent, .bold = focused });

        var visible_row: usize = 0;
        var index = self.first_row;
        while (visible_row < self.viewport_rows and index < self.rows.items.len) : ({
            visible_row += 1;
            index += 1;
        }) {
            const row = self.rows.items[index];
            const current = row.seq == tree.current.seq;
            const style: Render.Style = .{
                .fg = if (current) .accent else .default,
                .bg = if (index == self.selected_index and focused) .selection else .default,
                .bold = current,
            };
            var buf: [128]u8 = undefined;
            var time_buf: [24]u8 = undefined;
            var age_buf: [24]u8 = undefined;
            const indent = @min(row.depth, @as(usize, 8)) * 2;
            const marker: u8 = if (current) '@' else if (row.has_children) '*' else 'o';
            const clock = if (row.is_root) "root" else formatClock(&time_buf, row.timestamp);
            const age = if (row.is_root) "" else formatAge(&age_buf, now - row.timestamp);
            const text = std.fmt.bufPrint(&buf, " {s}{c} {d}  {s} {s}", .{ spaces(indent), marker, row.seq, clock, age }) catch "undo row";
            surface.writeAscii(content_x, area.y + 1 + visible_row, content_width, text, style);
        }
    }

    pub fn cursorPosition(self: UndoTreePanel, area: Render.Rect) ?api.CursorPosition {
        if (area.width <= 1 or area.height <= 1 or self.rows.items.len == 0) return null;
        const row = self.selected_index -| self.first_row;
        if (row >= area.height - 1) return null;
        return .{ .x = area.x + 1, .y = area.y + 1 + row };
    }

    pub fn selectedSeq(self: UndoTreePanel) ?u64 {
        return if (self.rows.items.len == 0) null else self.selected_seq;
    }

    pub fn rowCount(self: UndoTreePanel) usize {
        return self.rows.items.len;
    }

    fn move(self: *UndoTreePanel, direction: api.Direction) api.Action {
        if (self.rows.items.len == 0) return .none;
        switch (direction) {
            .up => self.selected_index -|= 1,
            .down => if (self.selected_index + 1 < self.rows.items.len) {
                self.selected_index += 1;
            },
            else => {},
        }
        self.selected_seq = self.rows.items[self.selected_index].seq;
        self.keepSelectionVisible();
        return .none;
    }

    fn jumpAction(self: UndoTreePanel) api.Action {
        return if (self.selectedSeq()) |seq| .{ .jump_undo_state = seq } else .none;
    }

    fn selectSeq(self: *UndoTreePanel, seq: u64) void {
        const index = self.indexForSeq(seq) orelse return;
        self.selected_index = index;
        self.selected_seq = seq;
        self.keepSelectionVisible();
    }

    fn indexForSeq(self: UndoTreePanel, seq: u64) ?usize {
        for (self.rows.items, 0..) |row, index| if (row.seq == seq) return index;
        return null;
    }

    fn keepSelectionVisible(self: *UndoTreePanel) void {
        if (self.viewport_rows == 0) {
            self.first_row = 0;
            return;
        }
        if (self.selected_index < self.first_row) self.first_row = self.selected_index;
        if (self.selected_index >= self.first_row + self.viewport_rows) self.first_row = self.selected_index - self.viewport_rows + 1;
    }
};

fn spaces(count: usize) []const u8 {
    const all = "                ";
    return all[0..@min(count, all.len)];
}

fn formatClock(buf: []u8, timestamp: i64) []const u8 {
    if (timestamp <= 0) return "--:--";
    const seconds: u64 = @intCast(timestamp);
    const day = (std.time.epoch.EpochSeconds{ .secs = seconds }).getDaySeconds();
    return std.fmt.bufPrint(buf, "{d:0>2}:{d:0>2}", .{ day.getHoursIntoDay(), day.getMinutesIntoHour() }) catch "--:--";
}

fn formatAge(buf: []u8, age_seconds: i64) []const u8 {
    const seconds = @max(age_seconds, 0);
    if (seconds < 60) return std.fmt.bufPrint(buf, "{d}s ago", .{seconds}) catch "? ago";
    const minutes = @divTrunc(seconds, 60);
    if (minutes < 60) return std.fmt.bufPrint(buf, "{d}m ago", .{minutes}) catch "? ago";
    const hours = @divTrunc(minutes, 60);
    if (hours < 24) return std.fmt.bufPrint(buf, "{d}h ago", .{hours}) catch "? ago";
    return std.fmt.bufPrint(buf, "{d}d ago", .{@divTrunc(hours, 24)}) catch "? ago";
}

test "caches rows by structure generation and survives reset" {
    var tree = try UndoTree.init(std.testing.allocator);
    defer tree.deinit();
    var panel = UndoTreePanel.init(std.testing.allocator);
    defer panel.deinit();

    try tree.recordInsertion(0, "a");
    _ = try panel.refresh(&tree);
    try std.testing.expectEqual(@as(usize, 2), panel.rowCount());
    panel.selectCurrent(&tree);
    try std.testing.expectEqual(tree.current.seq, panel.selectedSeq().?);

    const rows_ptr = panel.rows.items.ptr;
    try std.testing.expect(!try panel.refresh(&tree));
    try std.testing.expectEqual(rows_ptr, panel.rows.items.ptr);

    try tree.reset();
    _ = try panel.refresh(&tree);
    try std.testing.expectEqual(@as(usize, 1), panel.rowCount());
    try std.testing.expectEqual(@as(u64, 0), panel.selectedSeq().?);
}

test "selection scrolling accounts for title row" {
    var tree = try UndoTree.init(std.testing.allocator);
    defer tree.deinit();
    for (0..5) |index| try tree.recordInsertion(index, "x");
    var panel = UndoTreePanel.init(std.testing.allocator);
    defer panel.deinit();
    _ = try panel.refresh(&tree);
    panel.setArea(.{ .x = 10, .y = 2, .width = 20, .height = 3 });
    for (0..5) |_| _ = panel.handleKey(.{ .char = 'j' });

    try std.testing.expectEqual(@as(usize, 2), panel.viewport_rows);
    try std.testing.expectEqual(@as(usize, 4), panel.first_row);
    const cursor = panel.cursorPosition(.{ .x = 10, .y = 2, .width = 20, .height = 3 }).?;
    try std.testing.expectEqual(@as(usize, 11), cursor.x);
    try std.testing.expectEqual(@as(usize, 4), cursor.y);
}

test "formats undo clock and relative age" {
    var clock_buf: [16]u8 = undefined;
    var age_buf: [16]u8 = undefined;

    try std.testing.expectEqualStrings("--:--", formatClock(&clock_buf, 0));
    try std.testing.expectEqualStrings("5s ago", formatAge(&age_buf, 5));
    try std.testing.expectEqualStrings("2m ago", formatAge(&age_buf, 125));
    try std.testing.expectEqualStrings("3h ago", formatAge(&age_buf, 3 * 60 * 60));
}

test "projects deep undo history without recursive traversal" {
    var tree = try UndoTree.init(std.testing.allocator);
    defer tree.deinit();
    for (0..2000) |index| try tree.recordInsertion(index, "x");
    var panel = UndoTreePanel.init(std.testing.allocator);
    defer panel.deinit();

    _ = try panel.refresh(&tree);

    try std.testing.expectEqual(@as(usize, 2001), panel.rowCount());
    try std.testing.expectEqual(tree.current.seq, panel.selectedSeq().?);
}

test "state changes dirty the panel without rebuilding rows" {
    var tree = try UndoTree.init(std.testing.allocator);
    defer tree.deinit();
    try tree.recordInsertion(0, "x");
    var panel = UndoTreePanel.init(std.testing.allocator);
    defer panel.deinit();
    _ = try panel.refresh(&tree);
    const rows_ptr = panel.rows.items.ptr;

    tree.setCurrent(tree.root);

    try std.testing.expect(try panel.refresh(&tree));
    try std.testing.expectEqual(rows_ptr, panel.rows.items.ptr);
    try std.testing.expect(!try panel.refresh(&tree));
}
