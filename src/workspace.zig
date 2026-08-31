const std = @import("std");
const api = @import("component_api.zig");
const Buffer = @import("buffer.zig").Buffer;
const Key = @import("input.zig").Key;
const Render = @import("render.zig");
const UndoTreePanel = @import("undo_tree_panel.zig").UndoTreePanel;

pub const Component = union(api.Kind) {
    editor: void,
    undo_tree: UndoTreePanel,

    fn deinit(self: *Component) void {
        switch (self.*) {
            .editor => {},
            .undo_tree => |*panel| panel.deinit(),
        }
    }

    fn handleKey(self: *Component, key: Key) api.Action {
        return switch (self.*) {
            .editor => .none,
            .undo_tree => |*panel| panel.handleKey(key),
        };
    }

    fn refresh(self: *Component, buffer: *const Buffer) !bool {
        return switch (self.*) {
            .editor => false,
            .undo_tree => |*panel| try panel.refresh(&buffer.undo_tree),
        };
    }

    fn render(self: *Component, surface: *Render.Surface, area: Render.Rect, buffer: *const Buffer, focused: bool, now: i64) void {
        switch (self.*) {
            .editor => {},
            .undo_tree => |*panel| panel.render(surface, area, &buffer.undo_tree, focused, now),
        }
    }

    fn cursorPosition(self: Component, area: Render.Rect) ?api.CursorPosition {
        return switch (self) {
            .editor => null,
            .undo_tree => |panel| panel.cursorPosition(area),
        };
    }
};

const Slot = struct {
    id: api.ComponentId,
    active: bool = true,
    dirty: bool = true,
    rect: Render.Rect = .{ .x = 0, .y = 0, .width = 0, .height = 0 },
    component: Component,
};

const SplitDirection = enum { horizontal, vertical };

const LayoutNode = union(enum) {
    leaf: api.ComponentId,
    split: struct {
        direction: SplitDirection,
        second_size: usize,
        first: *LayoutNode,
        second: *LayoutNode,
    },
};

pub const Workspace = struct {
    allocator: std.mem.Allocator,
    slots: std.ArrayListUnmanaged(Slot) = .empty,
    root: *LayoutNode,
    focused: api.ComponentId,
    editor_id: api.ComponentId,
    next_id: api.ComponentId = 1,

    pub fn init(allocator: std.mem.Allocator) !Workspace {
        const root = try allocator.create(LayoutNode);
        errdefer allocator.destroy(root);
        var workspace: Workspace = .{
            .allocator = allocator,
            .root = root,
            .focused = 0,
            .editor_id = 0,
        };
        const editor_id = try workspace.addComponent(.{ .editor = {} });
        workspace.editor_id = editor_id;
        workspace.focused = editor_id;
        root.* = .{ .leaf = editor_id };
        return workspace;
    }

    pub fn deinit(self: *Workspace) void {
        for (self.slots.items) |*slot| if (slot.active) slot.component.deinit();
        self.slots.deinit(self.allocator);
        self.destroyLayout(self.root);
        self.* = undefined;
    }

    pub fn toggleUndoTree(self: *Workspace) !void {
        if (self.idForKind(.undo_tree)) |id| {
            self.close(id);
            return;
        }
        const id = try self.addComponent(.{ .undo_tree = UndoTreePanel.init(self.allocator) });
        errdefer self.deactivate(id);
        try self.dockAfter(self.editor_id, id, .vertical, UndoTreePanel.preferred_width);
        self.focused = id;
    }

    pub fn refresh(self: *Workspace, buffer: *const Buffer) !void {
        for (self.slots.items) |*slot| {
            if (slot.active and try slot.component.refresh(buffer)) slot.dirty = true;
        }
    }

    pub fn layout(self: *Workspace, area: Render.Rect) void {
        self.layoutNode(self.root, area);
    }

    pub fn renderComponents(self: *Workspace, frame: *Render.FrameRenderer, buffer: *const Buffer, now: i64) !void {
        for (self.slots.items) |*slot| {
            if (!slot.active or slot.id == self.editor_id or !slot.dirty) continue;
            slot.component.render(&frame.current, slot.rect, buffer, slot.id == self.focused, now);
            try frame.markDirty(slot.rect);
            slot.dirty = false;
        }
    }

    pub fn handleFocusedKey(self: *Workspace, key: Key) api.Action {
        const slot = self.slotById(self.focused) orelse return .none;
        slot.dirty = true;
        return slot.component.handleKey(key);
    }

    pub fn applyAction(self: *Workspace, action: api.Action) ?u64 {
        switch (action) {
            .none => {},
            .focus => |direction| self.focusDirection(direction),
            .close_self => self.close(self.focused),
            .jump_undo_state => |seq| return seq,
        }
        return null;
    }

    pub fn focusDirection(self: *Workspace, direction: api.Direction) void {
        const current = self.slotById(self.focused) orelse return;
        var best_id: ?api.ComponentId = null;
        var best_score: u128 = std.math.maxInt(u128);
        const current_x = current.rect.x + current.rect.width / 2;
        const current_y = current.rect.y + current.rect.height / 2;
        for (self.slots.items) |slot| {
            if (!slot.active or slot.id == current.id or slot.rect.width == 0 or slot.rect.height == 0) continue;
            const x = slot.rect.x + slot.rect.width / 2;
            const y = slot.rect.y + slot.rect.height / 2;
            const primary: usize = switch (direction) {
                .left => if (x < current_x) current_x - x else continue,
                .right => if (x > current_x) x - current_x else continue,
                .up => if (y < current_y) current_y - y else continue,
                .down => if (y > current_y) y - current_y else continue,
            };
            const secondary = switch (direction) {
                .left, .right => distance(y, current_y),
                .up, .down => distance(x, current_x),
            };
            const score = @as(u128, primary) * 1_000_000 + secondary;
            if (score < best_score) {
                best_score = score;
                best_id = slot.id;
            }
        }
        if (best_id) |id| {
            current.dirty = true;
            self.focused = id;
            if (self.slotById(id)) |slot| slot.dirty = true;
        }
    }

    pub fn focusedKind(self: *const Workspace) api.Kind {
        return if (self.slotByIdConst(self.focused)) |slot| std.meta.activeTag(slot.component) else .editor;
    }

    pub fn editorRect(self: *const Workspace) Render.Rect {
        return if (self.slotByIdConst(self.editor_id)) |slot| slot.rect else .{ .x = 0, .y = 0, .width = 0, .height = 0 };
    }

    pub fn componentRect(self: *const Workspace, kind: api.Kind) ?Render.Rect {
        const id = self.idForKind(kind) orelse return null;
        return self.slotByIdConst(id).?.rect;
    }

    pub fn isOpen(self: *const Workspace, kind: api.Kind) bool {
        return self.idForKind(kind) != null;
    }

    pub fn focusEditor(self: *Workspace) void {
        if (self.slotById(self.focused)) |slot| slot.dirty = true;
        self.focused = self.editor_id;
    }

    pub fn selectCurrentUndo(self: *Workspace, buffer: *const Buffer) void {
        const slot = self.slotByKind(.undo_tree) orelse return;
        slot.component.undo_tree.selectCurrent(&buffer.undo_tree);
        slot.dirty = true;
    }

    pub fn focusedCursorPosition(self: *const Workspace) ?api.CursorPosition {
        const slot = self.slotByIdConst(self.focused) orelse return null;
        return slot.component.cursorPosition(slot.rect);
    }

    fn addComponent(self: *Workspace, component: Component) !api.ComponentId {
        const id = self.next_id;
        self.next_id +%= 1;
        try self.slots.append(self.allocator, .{ .id = id, .component = component });
        return id;
    }

    fn dockAfter(self: *Workspace, target: api.ComponentId, id: api.ComponentId, direction: SplitDirection, second_size: usize) !void {
        const node = findLeaf(self.root, target) orelse return error.ComponentNotFound;
        const first = try self.allocator.create(LayoutNode);
        errdefer self.allocator.destroy(first);
        const second = try self.allocator.create(LayoutNode);
        errdefer self.allocator.destroy(second);
        first.* = node.*;
        second.* = .{ .leaf = id };
        node.* = .{ .split = .{
            .direction = direction,
            .second_size = second_size,
            .first = first,
            .second = second,
        } };
    }

    fn close(self: *Workspace, id: api.ComponentId) void {
        if (id == self.editor_id or !removeLeaf(self.allocator, self.root, id)) return;
        self.deactivate(id);
        if (self.focused == id) self.focused = self.editor_id;
    }

    fn deactivate(self: *Workspace, id: api.ComponentId) void {
        const slot = self.slotById(id) orelse return;
        if (!slot.active) return;
        slot.component.deinit();
        slot.active = false;
    }

    fn layoutNode(self: *Workspace, node: *LayoutNode, area: Render.Rect) void {
        switch (node.*) {
            .leaf => |id| {
                if (self.slotById(id)) |slot| {
                    if (!std.meta.eql(slot.rect, area)) slot.dirty = true;
                    slot.rect = area;
                }
            },
            .split => |split| {
                const parts = switch (split.direction) {
                    .vertical => area.splitRight(@min(split.second_size, area.width / 2)),
                    .horizontal => area.splitBottom(@min(split.second_size, area.height / 2)),
                };
                self.layoutNode(split.first, parts.second);
                self.layoutNode(split.second, parts.first);
            },
        }
    }

    fn destroyLayout(self: *Workspace, node: *LayoutNode) void {
        switch (node.*) {
            .leaf => {},
            .split => |split| {
                self.destroyLayout(split.first);
                self.destroyLayout(split.second);
            },
        }
        self.allocator.destroy(node);
    }

    fn slotById(self: *Workspace, id: api.ComponentId) ?*Slot {
        for (self.slots.items) |*slot| if (slot.id == id and slot.active) return slot;
        return null;
    }

    fn slotByIdConst(self: *const Workspace, id: api.ComponentId) ?*const Slot {
        for (self.slots.items) |*slot| if (slot.id == id and slot.active) return slot;
        return null;
    }

    fn slotByKind(self: *Workspace, kind: api.Kind) ?*Slot {
        for (self.slots.items) |*slot| if (slot.active and std.meta.activeTag(slot.component) == kind) return slot;
        return null;
    }

    fn idForKind(self: *const Workspace, kind: api.Kind) ?api.ComponentId {
        for (self.slots.items) |slot| if (slot.active and std.meta.activeTag(slot.component) == kind) return slot.id;
        return null;
    }
};

fn findLeaf(node: *LayoutNode, id: api.ComponentId) ?*LayoutNode {
    return switch (node.*) {
        .leaf => |leaf_id| if (leaf_id == id) node else null,
        .split => |split| findLeaf(split.first, id) orelse findLeaf(split.second, id),
    };
}

fn removeLeaf(allocator: std.mem.Allocator, node: *LayoutNode, id: api.ComponentId) bool {
    switch (node.*) {
        .leaf => return false,
        .split => |split| {
            if (isLeaf(split.first, id)) {
                const replacement = split.second.*;
                allocator.destroy(split.first);
                allocator.destroy(split.second);
                node.* = replacement;
                return true;
            }
            if (isLeaf(split.second, id)) {
                const replacement = split.first.*;
                allocator.destroy(split.first);
                allocator.destroy(split.second);
                node.* = replacement;
                return true;
            }
            return removeLeaf(allocator, split.first, id) or removeLeaf(allocator, split.second, id);
        },
    }
}

fn isLeaf(node: *LayoutNode, id: api.ComponentId) bool {
    return switch (node.*) {
        .leaf => |leaf_id| leaf_id == id,
        .split => false,
    };
}

fn distance(a: usize, b: usize) usize {
    return if (a > b) a - b else b - a;
}

test "toggles docked undo panel and moves focus spatially" {
    var workspace = try Workspace.init(std.testing.allocator);
    defer workspace.deinit();
    try workspace.toggleUndoTree();
    workspace.layout(.{ .x = 0, .y = 0, .width = 100, .height = 20 });

    try std.testing.expect(workspace.isOpen(.undo_tree));
    try std.testing.expectEqual(api.Kind.undo_tree, workspace.focusedKind());
    try std.testing.expectEqual(@as(usize, 32), workspace.componentRect(.undo_tree).?.width);
    try std.testing.expectEqual(@as(usize, 68), workspace.editorRect().width);

    workspace.focusDirection(.left);
    try std.testing.expectEqual(api.Kind.editor, workspace.focusedKind());
    workspace.focusDirection(.right);
    try std.testing.expectEqual(api.Kind.undo_tree, workspace.focusedKind());

    try workspace.toggleUndoTree();
    workspace.layout(.{ .x = 0, .y = 0, .width = 100, .height = 20 });
    try std.testing.expect(!workspace.isOpen(.undo_tree));
    try std.testing.expectEqual(api.Kind.editor, workspace.focusedKind());
    try std.testing.expectEqual(@as(usize, 100), workspace.editorRect().width);
}

test "unchanged components skip retained-frame rendering" {
    var workspace = try Workspace.init(std.testing.allocator);
    defer workspace.deinit();
    var buffer = try Buffer.initFromText(std.testing.allocator, "");
    defer buffer.deinit();
    var frame = try Render.FrameRenderer.init(std.testing.allocator, 80, 20);
    defer frame.deinit();
    try workspace.toggleUndoTree();
    try workspace.refresh(&buffer);
    workspace.layout(frame.current.rect());

    frame.beginRetainedFrame();
    try workspace.renderComponents(&frame, &buffer, 0);
    try std.testing.expectEqual(@as(usize, 1), frame.dirty_rects.items.len);

    frame.beginRetainedFrame();
    try workspace.refresh(&buffer);
    try workspace.renderComponents(&frame, &buffer, 0);
    try std.testing.expectEqual(@as(usize, 0), frame.dirty_rects.items.len);
}
