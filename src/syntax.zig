const std = @import("std");
const Buffer = @import("buffer.zig").Buffer;

pub const c = @cImport({
    @cInclude("tree_sitter/api.h");
});

pub const Error = error{
    OutOfMemory,
    IncompatibleLanguage,
    MissingSymbol,
    InvalidState,
    InvalidQuery,
    ParseCancelled,
};

pub const HighlightKind = enum {
    keyword,
    string,
    comment,
    number,
    builtin,
    type,
    function,
    variable,
    constant,
    operator,
    punctuation,
    character,
    boolean,
    label,
    module,
};

pub const HighlightSpan = struct {
    start: usize,
    end: usize,
    kind: HighlightKind,
    priority: u32 = 0,
};

pub const ByteRange = struct {
    start: usize,
    end: usize,
};

pub const TextEdit = struct {
    offset: usize,
    old_end: usize,
    new_end: usize,
    start_point: Point,
    old_end_point: Point,
    new_end_point: Point,
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

pub const LanguageConfig = struct {
    name: []const u8,
    extensions: []const []const u8,
    parser_env: [:0]const u8,
    highlights_env: [:0]const u8,
    indents_env: [:0]const u8,
    parser_symbol: [:0]const u8,
};

const zig_extensions = [_][]const u8{".zig"};
const language_configs = [_]LanguageConfig{.{
    .name = "zig",
    .extensions = &zig_extensions,
    .parser_env = "TREE_SITTER_ZIG_PARSER",
    .highlights_env = "TREE_SITTER_ZIG_HIGHLIGHTS",
    .indents_env = "TREE_SITTER_ZIG_INDENTS",
    .parser_symbol = "tree_sitter_zig",
}};

pub const Highlighter = struct {
    allocator: std.mem.Allocator,
    parser: Parser,
    library: ?std.DynLib = null,
    language: ?Language = null,
    query: ?Query = null,
    indent_query: ?Query = null,
    query_cursor: ?QueryCursor = null,
    tree: ?Tree = null,
    tree_generation: u64 = 0,

    pub fn init(io: std.Io, allocator: std.mem.Allocator, path: ?[]const u8) !Highlighter {
        var highlighter: Highlighter = .{
            .allocator = allocator,
            .parser = try Parser.init(),
        };
        errdefer highlighter.deinit();

        if (path) |file_path| if (configForPath(file_path)) |config| highlighter.loadLanguage(io, config) catch {};

        return highlighter;
    }

    pub fn deinit(self: *Highlighter) void {
        if (self.tree) |*tree| tree.deinit();
        if (self.query_cursor) |*cursor| cursor.deinit();
        if (self.indent_query) |*query| query.deinit();
        if (self.query) |*query| query.deinit();
        if (self.library) |*lib| lib.close();
        self.parser.deinit();
        self.* = undefined;
    }

    pub fn enabled(self: Highlighter) bool {
        return self.language != null;
    }

    pub fn indentColumns(self: *Highlighter, buffer: *const Buffer, offset: usize, indent_width: usize) !?usize {
        const language = self.language orelse return null;
        const query = self.indent_query orelse return null;
        if (self.query_cursor == null) return null;
        try self.parser.setLanguage(language);

        var temporary_tree: ?Tree = null;
        defer if (temporary_tree) |*tree| tree.deinit();
        const root = if (self.tree != null and self.tree_generation == buffer.generation)
            self.tree.?.rootNode()
        else blk: {
            temporary_tree = try self.parser.parseBuffer(null, buffer);
            break :blk temporary_tree.?.rootNode();
        };

        const info = self.query_cursor.?.indentInfo(&query, root, @min(offset, buffer.byteLen()));
        return info.level * indent_width;
    }

    pub fn indentEndColumns(self: *Highlighter, buffer: *const Buffer, offset: usize, indent_width: usize) !?usize {
        const language = self.language orelse return null;
        const query = self.indent_query orelse return null;
        if (self.query_cursor == null) return null;
        try self.parser.setLanguage(language);

        var temporary_tree = try self.parser.parseBuffer(null, buffer);
        defer temporary_tree.deinit();
        const info = self.query_cursor.?.indentInfo(&query, temporary_tree.rootNode(), @min(offset, buffer.byteLen()));
        if (!info.is_end) return null;
        return (info.level -| 1) * indent_width;
    }

    pub fn collectFull(self: *Highlighter, spans: *std.ArrayListUnmanaged(HighlightSpan), buffer: *const Buffer, visible: ?ByteRange) !void {
        return self.collectFullBudgeted(spans, buffer, visible, null);
    }

    pub fn collectFullBudgeted(self: *Highlighter, spans: *std.ArrayListUnmanaged(HighlightSpan), buffer: *const Buffer, visible: ?ByteRange, budget_ns: ?u64) !void {
        const language = self.language orelse return;
        try self.parser.setLanguage(language);
        const tree = try self.parser.parseBufferBudgeted(null, buffer, budget_ns);
        if (self.tree) |*old_tree| old_tree.deinit();
        self.tree = tree;
        self.tree_generation = buffer.generation;

        try self.collectQuery(spans, buffer, self.tree.?.rootNode(), visible);
    }

    pub fn collectEdit(self: *Highlighter, spans: *std.ArrayListUnmanaged(HighlightSpan), buffer: *const Buffer, edit: TextEdit, visible: ?ByteRange) !void {
        return self.collectEditBudgeted(spans, buffer, edit, visible, null);
    }

    pub fn collectEditBudgeted(self: *Highlighter, spans: *std.ArrayListUnmanaged(HighlightSpan), buffer: *const Buffer, edit: TextEdit, visible: ?ByteRange, budget_ns: ?u64) !void {
        const language = self.language orelse return;
        if (self.tree == null) return error.InvalidState;
        try self.parser.setLanguage(language);

        const input_edit = inputEditForTextEdit(edit);
        var edited_tree = try self.tree.?.copy();
        defer edited_tree.deinit();
        edited_tree.edit(input_edit);

        const tree = try self.parser.parseBufferBudgeted(&edited_tree, buffer, budget_ns);
        var range_count: u32 = 0;
        const changed_ranges = c.ts_tree_get_changed_ranges(edited_tree.ptr, tree.ptr, &range_count);
        defer if (changed_ranges != null) std.c.free(changed_ranges);

        if (changed_ranges != null and range_count != 0) {
            removeChangedSpans(spans, changed_ranges, range_count);
            var index: u32 = 0;
            while (index < range_count) : (index += 1) {
                const changed = changed_ranges[index];
                const range = intersectRange(.{
                    .start = changed.start_byte,
                    .end = changed.end_byte,
                }, visible) orelse continue;
                try self.collectQuery(spans, buffer, tree.rootNode(), range);
            }
        }

        self.tree.?.deinit();
        self.tree = tree;
        self.tree_generation = buffer.generation;
        try normalizeSpans(spans, self.allocator);
    }

    pub fn collectVisible(self: *Highlighter, spans: *std.ArrayListUnmanaged(HighlightSpan), buffer: *const Buffer, visible: ?ByteRange) !void {
        if (self.tree == null) return error.InvalidState;
        try self.collectQuery(spans, buffer, self.tree.?.rootNode(), visible);
    }

    fn collectQuery(self: *Highlighter, spans: *std.ArrayListUnmanaged(HighlightSpan), buffer: *const Buffer, root: Node, range: ?ByteRange) !void {
        if (self.query == null or self.query_cursor == null) return;
        try self.query_cursor.?.collect(&self.query.?, buffer, root, range, spans, self.allocator);
        try normalizeSpans(spans, self.allocator);
    }

    fn loadLanguage(self: *Highlighter, io: std.Io, config: LanguageConfig) !void {
        const path = std.c.getenv(config.parser_env) orelse return;
        var lib = std.DynLib.openZ(path) catch return;
        errdefer lib.close();
        const language_fn = lib.lookup(LanguageFn, config.parser_symbol) orelse return error.MissingSymbol;
        const language = language_fn();
        const query_path = std.c.getenv(config.highlights_env) orelse return;
        const query_source = try std.Io.Dir.cwd().readFileAlloc(io, std.mem.span(query_path), self.allocator, .limited(1024 * 1024));
        defer self.allocator.free(query_source);
        const indent_path = std.c.getenv(config.indents_env) orelse return;
        const indent_source = try std.Io.Dir.cwd().readFileAlloc(io, std.mem.span(indent_path), self.allocator, .limited(1024 * 1024));
        defer self.allocator.free(indent_source);

        self.query = try Query.init(language, query_source);
        self.indent_query = try Query.init(language, indent_source);
        self.query_cursor = try QueryCursor.init();
        self.language = language;
        self.library = lib;
    }
};

fn configForPath(path: []const u8) ?LanguageConfig {
    for (language_configs) |config| {
        for (config.extensions) |extension| if (std.mem.endsWith(u8, path, extension)) return config;
    }
    return null;
}

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

    pub fn parseBuffer(self: Parser, old_tree: ?*const Tree, buffer: *const Buffer) Error!Tree {
        return self.parseBufferBudgeted(old_tree, buffer, null);
    }

    pub fn parseBufferBudgeted(self: Parser, old_tree: ?*const Tree, buffer: *const Buffer, budget_ns: ?u64) Error!Tree {
        const old = if (old_tree) |tree| tree.ptr else null;
        const input: c.TSInput = .{
            .payload = @ptrCast(@constCast(buffer)),
            .read = readBuffer,
            .encoding = c.TSInputEncodingUTF8,
            .decode = null,
        };
        const ptr = if (budget_ns) |budget| blk: {
            var deadline: ParseDeadline = .{ .deadline_ns = monotonicNowNs() + budget };
            const options: c.TSParseOptions = .{
                .payload = &deadline,
                .progress_callback = parseProgress,
            };
            const result = c.ts_parser_parse_with_options(self.ptr, old, input, options);
            if (result == null) {
                c.ts_parser_reset(self.ptr);
                if (deadline.cancelled) return error.ParseCancelled;
                return error.OutOfMemory;
            }
            break :blk result;
        } else c.ts_parser_parse(self.ptr, old, input);
        const tree_ptr = ptr orelse return error.OutOfMemory;
        return .{ .ptr = tree_ptr };
    }
};

const ParseDeadline = struct {
    deadline_ns: u64,
    cancelled: bool = false,
};

fn parseProgress(state: [*c]c.TSParseState) callconv(.c) bool {
    if (state == null or state[0].payload == null) return false;
    const deadline: *ParseDeadline = @ptrCast(@alignCast(state[0].payload.?));
    if (monotonicNowNs() < deadline.deadline_ns) return false;
    deadline.cancelled = true;
    return true;
}

fn monotonicNowNs() u64 {
    var ts: std.c.timespec = undefined;
    if (std.c.clock_gettime(.MONOTONIC, &ts) != 0) return 0;
    return @intCast(@as(i128, ts.sec) * std.time.ns_per_s + ts.nsec);
}

pub const Query = struct {
    ptr: *c.TSQuery,

    pub fn init(language: Language, source: []const u8) Error!Query {
        var error_offset: u32 = 0;
        var error_type: c.TSQueryError = c.TSQueryErrorNone;
        const ptr = c.ts_query_new(language, source.ptr, @intCast(source.len), &error_offset, &error_type) orelse return error.InvalidQuery;
        return .{ .ptr = ptr };
    }

    pub fn deinit(self: *Query) void {
        c.ts_query_delete(self.ptr);
        self.* = undefined;
    }

    fn captureName(self: Query, id: u32) []const u8 {
        var len: u32 = 0;
        const ptr = c.ts_query_capture_name_for_id(self.ptr, id, &len);
        return ptr[0..len];
    }

    fn stringValue(self: Query, id: u32) []const u8 {
        var len: u32 = 0;
        const ptr = c.ts_query_string_value_for_id(self.ptr, id, &len);
        return ptr[0..len];
    }

    fn patternPriority(self: Query, pattern_index: u16) u32 {
        var base: u32 = 100;
        var count: u32 = 0;
        const ptr = c.ts_query_predicates_for_pattern(self.ptr, pattern_index, &count);
        if (ptr != null) {
            const steps = ptr[0..count];
            var start: usize = 0;
            for (steps, 0..) |step, index| {
                if (step.type != c.TSQueryPredicateStepTypeDone) continue;
                const predicate = steps[start..index];
                if (predicate.len >= 3 and predicate[0].type == c.TSQueryPredicateStepTypeString and std.mem.eql(u8, self.stringValue(predicate[0].value_id), "set!")) {
                    const key_index: usize = if (predicate.len >= 4) 2 else 1;
                    const value_index = key_index + 1;
                    if (value_index < predicate.len and predicate[key_index].type == c.TSQueryPredicateStepTypeString and predicate[value_index].type == c.TSQueryPredicateStepTypeString and std.mem.eql(u8, self.stringValue(predicate[key_index].value_id), "priority")) {
                        base = std.fmt.parseUnsigned(u32, self.stringValue(predicate[value_index].value_id), 10) catch base;
                    }
                }
                start = index + 1;
            }
        }
        return base * 1000 + pattern_index;
    }
};

pub const QueryCursor = struct {
    ptr: *c.TSQueryCursor,

    pub fn init() Error!QueryCursor {
        return .{ .ptr = c.ts_query_cursor_new() orelse return error.OutOfMemory };
    }

    pub fn deinit(self: *QueryCursor) void {
        c.ts_query_cursor_delete(self.ptr);
        self.* = undefined;
    }

    fn collect(self: QueryCursor, query: *const Query, buffer: *const Buffer, root: Node, range: ?ByteRange, spans: *std.ArrayListUnmanaged(HighlightSpan), allocator: std.mem.Allocator) !void {
        if (range) |bounds| {
            _ = c.ts_query_cursor_set_byte_range(self.ptr, @intCast(bounds.start), @intCast(bounds.end));
        } else {
            _ = c.ts_query_cursor_set_byte_range(self.ptr, 0, 0);
        }
        c.ts_query_cursor_exec(self.ptr, query.ptr, root.raw);

        var match: c.TSQueryMatch = undefined;
        while (c.ts_query_cursor_next_match(self.ptr, &match)) {
            if (!predicatesMatch(query.*, buffer, match)) continue;
            var index: usize = 0;
            while (index < match.capture_count) : (index += 1) {
                const capture = match.captures[index];
                const kind = kindForCapture(query.captureName(capture.index)) orelse continue;
                const node: Node = .{ .raw = capture.node };
                const start = node.startByte();
                const end = node.endByte();
                if (end <= start) continue;
                if (range) |bounds| {
                    if (end <= bounds.start or start >= bounds.end) continue;
                }
                try spans.append(allocator, .{
                    .start = start,
                    .end = end,
                    .kind = kind,
                    .priority = query.patternPriority(match.pattern_index),
                });
            }
        }
    }

    const IndentInfo = struct {
        level: usize,
        is_end: bool,
    };

    fn indentInfo(self: QueryCursor, query: *const Query, root: Node, offset: usize) IndentInfo {
        const tree_end = root.endByte();
        if (tree_end == 0) return .{ .level = 0, .is_end = false };
        const probe = @min(offset, tree_end - 1);
        _ = c.ts_query_cursor_set_byte_range(self.ptr, @intCast(probe), @intCast(probe + 1));
        c.ts_query_cursor_exec(self.ptr, query.ptr, root.raw);

        const Range = struct { start: usize, end: usize };
        var seen: [128]Range = undefined;
        var seen_len: usize = 0;
        var is_end = false;
        var match: c.TSQueryMatch = undefined;
        while (c.ts_query_cursor_next_match(self.ptr, &match)) {
            var index: usize = 0;
            while (index < match.capture_count) : (index += 1) {
                const capture = match.captures[index];
                const node: Node = .{ .raw = capture.node };
                const capture_name = query.captureName(capture.index);
                if (std.mem.eql(u8, capture_name, "indent.end")) {
                    if (node.startByte() == offset) is_end = true;
                    continue;
                }
                if (!std.mem.eql(u8, capture_name, "indent.begin")) continue;
                const start = node.startByte();
                const end = node.endByte();
                if (start >= offset or end < offset) continue;
                var duplicate = false;
                for (seen[0..seen_len]) |range| {
                    if (range.start == start and range.end == end) {
                        duplicate = true;
                        break;
                    }
                }
                if (!duplicate and seen_len < seen.len) {
                    seen[seen_len] = .{ .start = start, .end = end };
                    seen_len += 1;
                }
            }
        }
        return .{ .level = seen_len, .is_end = is_end };
    }
};

fn readBuffer(payload: ?*anyopaque, byte_index: u32, _: c.TSPoint, bytes_read: [*c]u32) callconv(.c) [*c]const u8 {
    if (bytes_read == null) return null;
    const buffer: *const Buffer = @ptrCast(@alignCast(payload orelse {
        bytes_read[0] = 0;
        return null;
    }));
    if (byte_index >= buffer.byteLen()) {
        bytes_read[0] = 0;
        return null;
    }
    const chunk = buffer.chunkAt(byte_index);
    bytes_read[0] = @intCast(chunk.len);
    return chunk.ptr;
}

pub const Tree = struct {
    ptr: *c.TSTree,

    pub fn deinit(self: *Tree) void {
        c.ts_tree_delete(self.ptr);
        self.* = undefined;
    }

    pub fn copy(self: Tree) Error!Tree {
        return .{ .ptr = c.ts_tree_copy(self.ptr) orelse return error.OutOfMemory };
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

fn kindForCapture(name: []const u8) ?HighlightKind {
    if (std.mem.eql(u8, name, "variable.builtin") or std.mem.eql(u8, name, "function.builtin")) return .builtin;
    if (captureIs(name, "keyword")) return .keyword;
    if (captureIs(name, "string")) return .string;
    if (captureIs(name, "comment")) return .comment;
    if (captureIs(name, "number")) return .number;
    if (captureIs(name, "type")) return .type;
    if (captureIs(name, "function")) return .function;
    if (captureIs(name, "constant")) return .constant;
    if (captureIs(name, "operator")) return .operator;
    if (captureIs(name, "punctuation")) return .punctuation;
    if (captureIs(name, "character")) return .character;
    if (captureIs(name, "boolean")) return .boolean;
    if (captureIs(name, "label")) return .label;
    if (captureIs(name, "module")) return .module;
    if (captureIs(name, "variable")) return .variable;
    return null;
}

fn captureIs(name: []const u8, base: []const u8) bool {
    return std.mem.eql(u8, name, base) or (std.mem.startsWith(u8, name, base) and name.len > base.len and name[base.len] == '.');
}

fn predicatesMatch(query: Query, buffer: *const Buffer, match: c.TSQueryMatch) bool {
    var count: u32 = 0;
    const ptr = c.ts_query_predicates_for_pattern(query.ptr, match.pattern_index, &count);
    if (ptr == null or count == 0) return true;
    const steps = ptr[0..count];
    var start: usize = 0;
    for (steps, 0..) |step, index| {
        if (step.type != c.TSQueryPredicateStepTypeDone) continue;
        if (!predicateMatches(query, buffer, match, steps[start..index])) return false;
        start = index + 1;
    }
    return true;
}

fn predicateMatches(query: Query, buffer: *const Buffer, match: c.TSQueryMatch, steps: []const c.TSQueryPredicateStep) bool {
    if (steps.len == 0 or steps[0].type != c.TSQueryPredicateStepTypeString) return true;
    const operator = query.stringValue(steps[0].value_id);
    if (std.mem.eql(u8, operator, "set!")) return true;
    if (steps.len < 3 or steps[1].type != c.TSQueryPredicateStepTypeCapture) return false;
    const node = captureNode(match, steps[1].value_id) orelse return false;

    if (std.mem.eql(u8, operator, "eq?")) {
        return steps[2].type == c.TSQueryPredicateStepTypeString and nodeTextEql(buffer, node, query.stringValue(steps[2].value_id));
    }
    if (std.mem.eql(u8, operator, "any-of?")) {
        for (steps[2..]) |step| {
            if (step.type == c.TSQueryPredicateStepTypeString and nodeTextEql(buffer, node, query.stringValue(step.value_id))) return true;
        }
        return false;
    }
    if (std.mem.eql(u8, operator, "lua-match?")) {
        return steps[2].type == c.TSQueryPredicateStepTypeString and luaMatch(buffer, node, query.stringValue(steps[2].value_id));
    }
    return true;
}

fn captureNode(match: c.TSQueryMatch, capture_id: u32) ?Node {
    var index: usize = 0;
    while (index < match.capture_count) : (index += 1) {
        const capture = match.captures[index];
        if (capture.index == capture_id) return .{ .raw = capture.node };
    }
    return null;
}

fn nodeTextEql(buffer: *const Buffer, node: Node, expected: []const u8) bool {
    const start = node.startByte();
    const end = node.endByte();
    if (end - start != expected.len) return false;
    for (expected, 0..) |byte, index| if (buffer.byteAt(start + index) != byte) return false;
    return true;
}

fn luaMatch(buffer: *const Buffer, node: Node, pattern: []const u8) bool {
    const start = node.startByte();
    const end = node.endByte();
    if (std.mem.eql(u8, pattern, "^[A-Z_][a-zA-Z0-9_]*")) {
        if (start >= end) return false;
        const first = buffer.byteAt(start);
        return std.ascii.isUpper(first) or first == '_';
    }
    if (std.mem.eql(u8, pattern, "^[A-Z][A-Z_0-9]+$")) {
        if (end - start < 2 or !std.ascii.isUpper(buffer.byteAt(start))) return false;
        var offset = start + 1;
        while (offset < end) : (offset += 1) {
            const byte = buffer.byteAt(offset);
            if (!std.ascii.isUpper(byte) and !std.ascii.isDigit(byte) and byte != '_') return false;
        }
        return true;
    }
    if (std.mem.eql(u8, pattern, "^//!")) {
        return end - start >= 3 and buffer.byteAt(start) == '/' and buffer.byteAt(start + 1) == '/' and buffer.byteAt(start + 2) == '!';
    }
    return false;
}

fn normalizeSpans(spans: *std.ArrayListUnmanaged(HighlightSpan), allocator: std.mem.Allocator) !void {
    if (spans.items.len < 2) return;
    var boundaries: std.ArrayListUnmanaged(usize) = .empty;
    defer boundaries.deinit(allocator);
    try boundaries.ensureTotalCapacity(allocator, spans.items.len * 2);
    for (spans.items) |span| {
        boundaries.appendAssumeCapacity(span.start);
        boundaries.appendAssumeCapacity(span.end);
    }
    std.mem.sort(usize, boundaries.items, {}, lessThanUsize);

    var normalized: std.ArrayListUnmanaged(HighlightSpan) = .empty;
    defer normalized.deinit(allocator);
    var index: usize = 0;
    while (index + 1 < boundaries.items.len) : (index += 1) {
        const start = boundaries.items[index];
        const end = boundaries.items[index + 1];
        if (end <= start) continue;
        var best: ?HighlightSpan = null;
        for (spans.items) |span| {
            if (span.start <= start and span.end >= end and (best == null or span.priority >= best.?.priority)) best = span;
        }
        const winner = best orelse continue;
        if (normalized.items.len != 0) {
            const last = &normalized.items[normalized.items.len - 1];
            if (last.end == start and last.kind == winner.kind and last.priority == winner.priority) {
                last.end = end;
                continue;
            }
        }
        try normalized.append(allocator, .{ .start = start, .end = end, .kind = winner.kind, .priority = winner.priority });
    }

    spans.clearRetainingCapacity();
    try spans.appendSlice(allocator, normalized.items);
}

fn lessThanUsize(_: void, a: usize, b: usize) bool {
    return a < b;
}

fn removeChangedSpans(spans: *std.ArrayListUnmanaged(HighlightSpan), ranges: [*c]c.TSRange, range_count: u32) void {
    var out: usize = 0;
    for (spans.items) |span| {
        var changed = false;
        var index: u32 = 0;
        while (index < range_count) : (index += 1) {
            const range = ranges[index];
            if (span.end > range.start_byte and span.start < range.end_byte) {
                changed = true;
                break;
            }
        }
        if (changed) continue;
        spans.items[out] = span;
        out += 1;
    }
    spans.shrinkRetainingCapacity(out);
}

fn intersectRange(range: ByteRange, visible: ?ByteRange) ?ByteRange {
    const bounds = visible orelse return range;
    const start = @max(range.start, bounds.start);
    const end = @min(range.end, bounds.end);
    return if (end > start) .{ .start = start, .end = end } else null;
}

fn inputEditForTextEdit(edit: TextEdit) c.TSInputEdit {
    return .{
        .start_byte = @intCast(edit.offset),
        .old_end_byte = @intCast(edit.old_end),
        .new_end_byte = @intCast(edit.new_end),
        .start_point = .{ .row = edit.start_point.row, .column = edit.start_point.column },
        .old_end_point = .{ .row = edit.old_end_point.row, .column = edit.old_end_point.column },
        .new_end_point = .{ .row = edit.new_end_point.row, .column = edit.new_end_point.column },
    };
}

test "tree-sitter parser lifecycle" {
    var parser = try Parser.init();
    parser.deinit();
}

test "zig highlighter collects keyword spans when grammar is available" {
    var highlighter = try Highlighter.init(std.testing.io, std.testing.allocator, "test.zig");
    defer highlighter.deinit();
    if (std.c.getenv("TREE_SITTER_ZIG_PARSER") != null and std.c.getenv("TREE_SITTER_ZIG_HIGHLIGHTS") != null) try std.testing.expect(highlighter.enabled());
    if (!highlighter.enabled()) return;
    var buffer = try Buffer.initFromText(std.testing.allocator, "const x = @as(i32, 1); // hi\n");
    defer buffer.deinit();

    var spans: std.ArrayListUnmanaged(HighlightSpan) = .empty;
    defer spans.deinit(std.testing.allocator);
    try highlighter.collectFull(&spans, &buffer, null);

    for (spans.items) |span| {
        if (span.kind == .keyword and span.start == 0 and span.end == 5) return;
    }
    return error.TestExpectedEqual;
}

test "incremental highlighting patches only changed syntax ranges" {
    var highlighter = try Highlighter.init(std.testing.io, std.testing.allocator, "test.zig");
    defer highlighter.deinit();
    if (std.c.getenv("TREE_SITTER_ZIG_PARSER") != null and std.c.getenv("TREE_SITTER_ZIG_HIGHLIGHTS") != null) try std.testing.expect(highlighter.enabled());
    if (!highlighter.enabled()) return;
    var buffer = try Buffer.initFromText(std.testing.allocator, "const a = 1;\nconst b = 2;\n");
    defer buffer.deinit();

    var spans: std.ArrayListUnmanaged(HighlightSpan) = .empty;
    defer spans.deinit(std.testing.allocator);
    try highlighter.collectFull(&spans, &buffer, null);

    try buffer.replace(10, 1, "x");
    const edit = buffer.last_edit.?;
    try highlighter.collectEdit(&spans, &buffer, .{
        .offset = edit.offset,
        .old_end = edit.old_end,
        .new_end = edit.new_end,
        .start_point = .{ .row = edit.start_point.row, .column = edit.start_point.column },
        .old_end_point = .{ .row = edit.old_end_point.row, .column = edit.old_end_point.column },
        .new_end_point = .{ .row = edit.new_end_point.row, .column = edit.new_end_point.column },
    }, null);

    var changed_number_present = false;
    var unaffected_number_present = false;
    var unaffected_keyword_present = false;
    for (spans.items) |span| {
        if (span.kind == .number and span.start == 10) changed_number_present = true;
        if (span.kind == .number and span.start == 23) unaffected_number_present = true;
        if (span.kind == .keyword and span.start == 13) unaffected_keyword_present = true;
    }
    try std.testing.expect(!changed_number_present);
    try std.testing.expect(unaffected_number_present);
    try std.testing.expect(unaffected_keyword_present);
}

test "zig highlight query applies semantic captures and predicates" {
    var highlighter = try Highlighter.init(std.testing.io, std.testing.allocator, "test.zig");
    defer highlighter.deinit();
    if (!highlighter.enabled()) return;
    const source =
        \\const TypeName = struct {};
        \\const CONSTANT = 1;
        \\fn foo(value: i32) void { _ = value; }
        \\const text = "hello";
        \\const flag = true;
        \\const ch = 'x';
        \\const std = @import("std");
        \\// hello
    ;
    var buffer = try Buffer.initFromText(std.testing.allocator, source);
    defer buffer.deinit();
    var spans: std.ArrayListUnmanaged(HighlightSpan) = .empty;
    defer spans.deinit(std.testing.allocator);
    try highlighter.collectFull(&spans, &buffer, null);

    try std.testing.expectEqual(HighlightKind.type, kindAt(spans.items, std.mem.indexOf(u8, source, "TypeName").?));
    try std.testing.expectEqual(HighlightKind.constant, kindAt(spans.items, std.mem.indexOf(u8, source, "CONSTANT").?));
    try std.testing.expectEqual(HighlightKind.function, kindAt(spans.items, std.mem.indexOf(u8, source, "foo").?));
    try std.testing.expectEqual(HighlightKind.builtin, kindAt(spans.items, std.mem.indexOf(u8, source, "_").?));
    try std.testing.expectEqual(HighlightKind.string, kindAt(spans.items, std.mem.indexOf(u8, source, "\"hello\"").?));
    try std.testing.expectEqual(HighlightKind.comment, kindAt(spans.items, std.mem.indexOf(u8, source, "// hello").?));
    try std.testing.expectEqual(HighlightKind.number, kindAt(spans.items, std.mem.indexOf(u8, source, "1").?));
    try std.testing.expectEqual(HighlightKind.operator, kindAt(spans.items, std.mem.indexOf(u8, source, "=").?));
    try std.testing.expectEqual(HighlightKind.punctuation, kindAt(spans.items, std.mem.indexOf(u8, source, "{").?));
    try std.testing.expectEqual(HighlightKind.boolean, kindAt(spans.items, std.mem.indexOf(u8, source, "true").?));
    try std.testing.expectEqual(HighlightKind.character, kindAt(spans.items, std.mem.indexOf(u8, source, "'x'").?));
    try std.testing.expectEqual(HighlightKind.module, kindAt(spans.items, std.mem.indexOf(u8, source, "std =").?));
    try std.testing.expectEqual(HighlightKind.keyword, kindAt(spans.items, std.mem.indexOf(u8, source, "@import").?));
}

test "zig indentation query computes structural depth" {
    var highlighter = try Highlighter.init(std.testing.io, std.testing.allocator, "test.zig");
    defer highlighter.deinit();
    if (!highlighter.enabled()) return;
    var buffer = try Buffer.initFromText(std.testing.allocator,
        \\fn main() void {
        \\    const value = .{
        \\        .field = 1,
        \\    };
        \\}
    );
    defer buffer.deinit();

    try std.testing.expectEqual(@as(?usize, 4), try highlighter.indentColumns(&buffer, buffer.byteOffsetForLine(1), 4));
    try std.testing.expectEqual(@as(?usize, 8), try highlighter.indentColumns(&buffer, buffer.byteOffsetForLine(2), 4));
    try std.testing.expectEqual(@as(?usize, 0), try highlighter.indentColumns(&buffer, 0, 4));
    try std.testing.expectEqual(@as(?usize, 4), try highlighter.indentEndColumns(&buffer, buffer.byteOffsetForLine(3) + 4, 4));
    try std.testing.expectEqual(@as(?usize, 0), try highlighter.indentEndColumns(&buffer, buffer.byteOffsetForLine(4), 4));
    try std.testing.expectEqual(@as(?usize, null), try highlighter.indentEndColumns(&buffer, buffer.byteOffsetForLine(2), 4));
}

test "cancelled incremental parse preserves tree and spans for idle retry" {
    var highlighter = try Highlighter.init(std.testing.io, std.testing.allocator, "test.zig");
    defer highlighter.deinit();
    if (!highlighter.enabled()) return;

    var source: std.ArrayList(u8) = .empty;
    defer source.deinit(std.testing.allocator);
    try source.appendSlice(std.testing.allocator, "const marker = 0;\n");
    for (0..5000) |index| {
        var buf: [80]u8 = undefined;
        const line = try std.fmt.bufPrint(&buf, "const value_{d} = {d};\n", .{ index, index });
        try source.appendSlice(std.testing.allocator, line);
    }

    var buffer = try Buffer.initFromText(std.testing.allocator, source.items);
    defer buffer.deinit();
    var spans: std.ArrayListUnmanaged(HighlightSpan) = .empty;
    defer spans.deinit(std.testing.allocator);
    const visible: ByteRange = .{ .start = 0, .end = @min(buffer.byteLen(), 4096) };
    try highlighter.collectFull(&spans, &buffer, visible);
    const span_count = spans.items.len;
    const tree_generation = highlighter.tree_generation;

    try buffer.replace(6, 1, "n");
    const edit = buffer.last_edit.?;
    const text_edit: TextEdit = .{
        .offset = edit.offset,
        .old_end = edit.old_end,
        .new_end = edit.new_end,
        .start_point = .{ .row = edit.start_point.row, .column = edit.start_point.column },
        .old_end_point = .{ .row = edit.old_end_point.row, .column = edit.old_end_point.column },
        .new_end_point = .{ .row = edit.new_end_point.row, .column = edit.new_end_point.column },
    };
    try std.testing.expectError(error.ParseCancelled, highlighter.collectEditBudgeted(&spans, &buffer, text_edit, visible, 1));
    try std.testing.expectEqual(span_count, spans.items.len);
    try std.testing.expectEqual(tree_generation, highlighter.tree_generation);

    try highlighter.collectEdit(&spans, &buffer, text_edit, visible);
    try std.testing.expectEqual(buffer.generation, highlighter.tree_generation);
}

fn kindAt(spans: []const HighlightSpan, offset: usize) ?HighlightKind {
    for (spans) |span| if (offset >= span.start and offset < span.end) return span.kind;
    return null;
}
