pub const Rope = @import("rope.zig").Rope;
pub const Buffer = @import("buffer.zig").Buffer;
pub const Cursor = @import("buffer.zig").Cursor;
pub const Selection = @import("buffer.zig").Selection;
pub const UndoTree = @import("undotree.zig").UndoTree;
pub const UndoNode = @import("undotree.zig").Node;
pub const render = @import("render.zig");
pub const input = @import("input.zig");
pub const terminal = @import("terminal.zig");
pub const vim = @import("vim.zig");
pub const syntax = @import("syntax.zig");

test {
    _ = @import("rope.zig");
    _ = @import("buffer.zig");
    _ = @import("undotree.zig");
    _ = @import("render.zig");
    _ = @import("input.zig");
    _ = @import("terminal.zig");
    _ = @import("vim.zig");
    _ = @import("syntax.zig");
}
