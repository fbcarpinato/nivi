const std = @import("std");

pub const Key = union(enum) {
    char: u21,
    ctrl: u8,
    enter,
    escape,
    backspace,
    delete,
    arrow_up,
    arrow_down,
    arrow_left,
    arrow_right,
    home,
    end,
    page_up,
    page_down,
    unknown: []const u8,
};

pub const DecodeResult = struct {
    key: Key,
    used: usize,
};

pub fn decode(bytes: []const u8) ?DecodeResult {
    if (bytes.len == 0) return null;
    const first = bytes[0];
    if (first >= 0x01 and first <= 0x1a and first != '\n' and first != '\r') {
        return .{ .key = .{ .ctrl = first + 'a' - 1 }, .used = 1 };
    }
    return switch (first) {
        '\r', '\n' => .{ .key = .enter, .used = 1 },
        0x7f, 0x08 => .{ .key = .backspace, .used = 1 },
        0x1b => decodeEscape(bytes),
        0x20...0x7e => .{ .key = .{ .char = first }, .used = 1 },
        else => decodeUtf8(bytes),
    };
}

fn decodeEscape(bytes: []const u8) DecodeResult {
    if (bytes.len == 1) return .{ .key = .escape, .used = 1 };
    if (bytes.len >= 3 and bytes[1] == '[') {
        return switch (bytes[2]) {
            'A' => .{ .key = .arrow_up, .used = 3 },
            'B' => .{ .key = .arrow_down, .used = 3 },
            'C' => .{ .key = .arrow_right, .used = 3 },
            'D' => .{ .key = .arrow_left, .used = 3 },
            'H' => .{ .key = .home, .used = 3 },
            'F' => .{ .key = .end, .used = 3 },
            '1', '7' => tildeKey(bytes, .home),
            '3' => tildeKey(bytes, .delete),
            '4', '8' => tildeKey(bytes, .end),
            '5' => tildeKey(bytes, .page_up),
            '6' => tildeKey(bytes, .page_down),
            else => .{ .key = .{ .unknown = bytes[0..3] }, .used = 3 },
        };
    }
    return .{ .key = .escape, .used = 1 };
}

fn tildeKey(bytes: []const u8, key: Key) DecodeResult {
    if (bytes.len >= 4 and bytes[3] == '~') return .{ .key = key, .used = 4 };
    return .{ .key = .{ .unknown = bytes[0..@min(bytes.len, 3)] }, .used = @min(bytes.len, 3) };
}

fn decodeUtf8(bytes: []const u8) ?DecodeResult {
    const len: usize = if ((bytes[0] & 0b1110_0000) == 0b1100_0000)
        2
    else if ((bytes[0] & 0b1111_0000) == 0b1110_0000)
        3
    else if ((bytes[0] & 0b1111_1000) == 0b1111_0000)
        4
    else
        return .{ .key = .{ .unknown = bytes[0..1] }, .used = 1 };
    if (bytes.len < len) return null;
    const view = std.unicode.Utf8View.init(bytes[0..len]) catch return .{ .key = .{ .unknown = bytes[0..len] }, .used = len };
    var iterator = view.iterator();
    return .{ .key = .{ .char = iterator.nextCodepoint().? }, .used = len };
}

test "decode ascii and control keys" {
    try std.testing.expectEqual(@as(u21, 'x'), decode("x").?.key.char);
    try std.testing.expectEqual(Key.enter, decode("\n").?.key);
    try std.testing.expectEqual(@as(u8, 'c'), decode("\x03").?.key.ctrl);
}

test "decode arrows and delete" {
    try std.testing.expectEqual(Key.arrow_up, decode("\x1b[A").?.key);
    try std.testing.expectEqual(Key.arrow_down, decode("\x1b[B").?.key);
    try std.testing.expectEqual(Key.arrow_right, decode("\x1b[C").?.key);
    try std.testing.expectEqual(Key.arrow_left, decode("\x1b[D").?.key);
    try std.testing.expectEqual(Key.delete, decode("\x1b[3~").?.key);
}

test "decode utf8 character" {
    const result = decode("🌊").?;
    try std.testing.expectEqual(@as(u21, 0x1f30a), result.key.char);
    try std.testing.expectEqual(@as(usize, 4), result.used);
}
