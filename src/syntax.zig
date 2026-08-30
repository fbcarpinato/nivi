const std = @import("std");

pub const c = @cImport({
    @cInclude("tree_sitter/api.h");
});

pub const Error = error{
    OutOfMemory,
    IncompatibleLanguage,
    MissingSymbol,
    InvalidState,
};

pub const HighlightKind = enum {
    keyword,
    string,
    comment,
    number,
    builtin,
    type,
};

pub const HighlightSpan = struct {
    start: usize,
    end: usize,
    kind: HighlightKind,
};

pub const ByteRange = struct {
    start: usize,
    end: usize,
};

pub const TextEdit = struct {
    offset: usize,
    old_end: usize,
    new_end: usize,
    inserted: []const u8,
};

pub const Point = struct {
    row: u32,
    column: u32,

    fn fromC(point: c.TSPoint) Point {
        return .{ .row = point.row, .column = point.column };
    }
};

pub const Language = *const c.TSLanguage;

const LanguageFn = *const fn () callconv(.c) Language;

pub const Highlighter = struct {
    allocator: std.mem.Allocator,
    parser: Parser,
    zig_lib: ?std.DynLib = null,
    language: ?Language = null,
    tree: ?Tree = null,
    source: std.ArrayListUnmanaged(u8) = .empty,

    pub fn init(allocator: std.mem.Allocator, path: ?[]const u8) Error!Highlighter {
        var highlighter: Highlighter = .{
            .allocator = allocator,
            .parser = try Parser.init(),
        };
        errdefer highlighter.deinit();

        if (path) |file_path| {
            if (std.mem.endsWith(u8, file_path, ".zig")) highlighter.loadZig() catch {};
        }

        return highlighter;
    }

    pub fn deinit(self: *Highlighter) void {
        if (self.tree) |*tree| tree.deinit();
        self.source.deinit(self.allocator);
        if (self.zig_lib) |*lib| lib.close();
        self.parser.deinit();
        self.* = undefined;
    }

    pub fn enabled(self: Highlighter) bool {
        return self.language != null;
    }

    pub fn collectFull(self: *Highlighter, spans: *std.ArrayListUnmanaged(HighlightSpan), source: []const u8, visible: ?ByteRange) !void {
        const language = self.language orelse return;
        try self.parser.setLanguage(language);
        const tree = try self.parser.parseString(null, source);
        if (self.tree) |*old_tree| old_tree.deinit();
        self.tree = tree;

        self.source.clearRetainingCapacity();
        try self.source.appendSlice(self.allocator, source);

        try collectNode(spans, self.allocator, self.tree.?.rootNode(), source.len, visible);
        std.mem.sort(HighlightSpan, spans.items, {}, spanLessThan);
    }

    pub fn collectEdit(self: *Highlighter, spans: *std.ArrayListUnmanaged(HighlightSpan), edit: TextEdit, visible: ?ByteRange) !void {
        const language = self.language orelse return;
        if (self.tree == null) return error.InvalidState;
        try self.parser.setLanguage(language);

        const input_edit = inputEditForTextEdit(self.source.items, edit);
        self.tree.?.edit(input_edit);
        try self.source.replaceRange(self.allocator, edit.offset, edit.old_end - edit.offset, edit.inserted);

        const tree = try self.parser.parseString(&self.tree.?, self.source.items);
        self.tree.?.deinit();
        self.tree = tree;

        try collectNode(spans, self.allocator, self.tree.?.rootNode(), self.source.items.len, visible);
        std.mem.sort(HighlightSpan, spans.items, {}, spanLessThan);
    }

    pub fn collectVisible(self: *Highlighter, spans: *std.ArrayListUnmanaged(HighlightSpan), visible: ?ByteRange) !void {
        if (self.tree == null) return error.InvalidState;
        try collectNode(spans, self.allocator, self.tree.?.rootNode(), self.source.items.len, visible);
        std.mem.sort(HighlightSpan, spans.items, {}, spanLessThan);
    }

    fn loadZig(self: *Highlighter) !void {
        const path = std.c.getenv("TREE_SITTER_ZIG_PARSER") orelse return;
        var lib = std.DynLib.openZ(path) catch return;
        errdefer lib.close();
        const language_fn = lib.lookup(LanguageFn, "tree_sitter_zig") orelse return error.MissingSymbol;
        self.language = language_fn();
        self.zig_lib = lib;
    }
};

pub const Parser = struct {
    ptr: *c.TSParser,

    pub fn init() Error!Parser {
        const ptr = c.ts_parser_new() orelse return error.OutOfMemory;
        return .{ .ptr = ptr };
    }

    pub fn deinit(self: *Parser) void {
        c.ts_parser_delete(self.ptr);
        self.* = undefined;
    }

    pub fn setLanguage(self: Parser, language: Language) Error!void {
        if (!c.ts_parser_set_language(self.ptr, language)) return error.IncompatibleLanguage;
    }

    pub fn parseString(self: Parser, old_tree: ?*const Tree, source: []const u8) Error!Tree {
        const old = if (old_tree) |tree| tree.ptr else null;
        const ptr = c.ts_parser_parse_string(self.ptr, old, source.ptr, @intCast(source.len)) orelse return error.OutOfMemory;
        return .{ .ptr = ptr };
    }
};

pub const Tree = struct {
    ptr: *c.TSTree,

    pub fn deinit(self: *Tree) void {
        c.ts_tree_delete(self.ptr);
        self.* = undefined;
    }

    pub fn rootNode(self: Tree) Node {
        return .{ .raw = c.ts_tree_root_node(self.ptr) };
    }

    pub fn edit(self: *Tree, input_edit: c.TSInputEdit) void {
        c.ts_tree_edit(self.ptr, &input_edit);
    }
};

pub const Node = struct {
    raw: c.TSNode,

    pub fn kind(self: Node) []const u8 {
        return std.mem.span(c.ts_node_type(self.raw));
    }

    pub fn startByte(self: Node) usize {
        return c.ts_node_start_byte(self.raw);
    }

    pub fn endByte(self: Node) usize {
        return c.ts_node_end_byte(self.raw);
    }

    pub fn startPoint(self: Node) Point {
        return Point.fromC(c.ts_node_start_point(self.raw));
    }

    pub fn endPoint(self: Node) Point {
        return Point.fromC(c.ts_node_end_point(self.raw));
    }

    pub fn childCount(self: Node) u32 {
        return c.ts_node_child_count(self.raw);
    }

    pub fn namedChildCount(self: Node) u32 {
        return c.ts_node_named_child_count(self.raw);
    }

    pub fn child(self: Node, index: u32) ?Node {
        const raw = c.ts_node_child(self.raw, index);
        if (c.ts_node_is_null(raw)) return null;
        return .{ .raw = raw };
    }

    pub fn namedChild(self: Node, index: u32) ?Node {
        const raw = c.ts_node_named_child(self.raw, index);
        if (c.ts_node_is_null(raw)) return null;
        return .{ .raw = raw };
    }
};

fn collectNode(spans: *std.ArrayListUnmanaged(HighlightSpan), allocator: std.mem.Allocator, node: Node, source_len: usize, visible: ?ByteRange) !void {
    const node_start = @min(node.startByte(), source_len);
    const node_end = @min(node.endByte(), source_len);
    if (visible) |range| {
        if (node_end <= range.start or node_start >= range.end) return;
    }

    const child_count = node.childCount();
    if (highlightKindFor(node)) |kind| {
        const start = node_start;
        const end = node_end;
        if (end > start) try spans.append(allocator, .{ .start = start, .end = end, .kind = kind });
    }

    var index: u32 = 0;
    while (index < child_count) : (index += 1) {
        if (node.child(index)) |next| try collectNode(spans, allocator, next, source_len, visible);
    }
}

fn highlightKindFor(node: Node) ?HighlightKind {
    const kind = node.kind();
    if (std.mem.eql(u8, kind, "line_comment") or std.mem.eql(u8, kind, "doc_comment") or std.mem.eql(u8, kind, "container_doc_comment")) return .comment;
    if (std.mem.indexOf(u8, kind, "string") != null or std.mem.eql(u8, kind, "char_literal")) return .string;
    if (std.mem.eql(u8, kind, "integer_literal") or std.mem.eql(u8, kind, "float_literal")) return .number;
    if (std.mem.eql(u8, kind, "builtin_identifier")) return .builtin;
    if (std.mem.eql(u8, kind, "builtin_type")) return .type;
    if (isZigKeyword(kind)) return .keyword;
    return null;
}

fn isZigKeyword(kind: []const u8) bool {
    inline for (.{
        "addrspace", "align", "allowzero", "and", "anyframe", "asm", "async", "await", "break", "callconv",
        "catch", "comptime", "const", "continue", "defer", "else", "enum", "errdefer", "error", "export",
        "extern", "fn", "for", "if", "inline", "noalias", "noinline", "nosuspend", "opaque", "or", "orelse",
        "packed", "pub", "resume", "return", "struct", "suspend", "switch", "test", "threadlocal", "try", "union",
        "unreachable", "usingnamespace", "var", "volatile", "while",
    }) |keyword| {
        if (std.mem.eql(u8, kind, keyword)) return true;
    }
    return false;
}

fn spanLessThan(_: void, a: HighlightSpan, b: HighlightSpan) bool {
    return a.start < b.start or (a.start == b.start and a.end < b.end);
}

fn inputEditForTextEdit(old_source: []const u8, edit: TextEdit) c.TSInputEdit {
    return .{
        .start_byte = @intCast(edit.offset),
        .old_end_byte = @intCast(edit.old_end),
        .new_end_byte = @intCast(edit.new_end),
        .start_point = pointForByte(old_source, edit.offset),
        .old_end_point = pointForByte(old_source, edit.old_end),
        .new_end_point = pointAfterInsert(old_source, edit.offset, edit.inserted),
    };
}

fn pointAfterInsert(old_source: []const u8, offset: usize, inserted: []const u8) c.TSPoint {
    var point = pointForByte(old_source, offset);
    for (inserted) |byte| {
        if (byte == '\n') {
            point.row += 1;
            point.column = 0;
        } else {
            point.column += 1;
        }
    }
    return point;
}

fn pointForByte(source: []const u8, target: usize) c.TSPoint {
    var row: u32 = 0;
    var column: u32 = 0;
    var index: usize = 0;
    const end = @min(target, source.len);
    while (index < end) : (index += 1) {
        if (source[index] == '\n') {
            row += 1;
            column = 0;
        } else {
            column += 1;
        }
    }
    return .{ .row = row, .column = column };
}

test "tree-sitter parser lifecycle" {
    var parser = try Parser.init();
    parser.deinit();
}

test "zig highlighter collects keyword spans when grammar is available" {
    var highlighter = try Highlighter.init(std.testing.allocator, "test.zig");
    defer highlighter.deinit();
    if (!highlighter.enabled()) return;

    var spans: std.ArrayListUnmanaged(HighlightSpan) = .empty;
    defer spans.deinit(std.testing.allocator);
    try highlighter.collectFull(&spans, "const x = @as(i32, 1); // hi\n", null);

    for (spans.items) |span| {
        if (span.kind == .keyword and span.start == 0 and span.end == 5) return;
    }
    return error.TestExpectedEqual;
}
