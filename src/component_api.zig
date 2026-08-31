pub const ComponentId = u32;

pub const Kind = enum {
    editor,
    undo_tree,
};

pub const Direction = enum {
    left,
    down,
    up,
    right,
};

pub const CursorPosition = struct {
    x: usize,
    y: usize,
};

pub const Action = union(enum) {
    none,
    focus: Direction,
    close_self,
    jump_undo_state: u64,
};
