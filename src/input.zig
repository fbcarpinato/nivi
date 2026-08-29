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

/// Decode the next key from `bytes`. Returns null when `bytes` is only a prefix
/// of a possibly-valid sequence (incomplete escape/CSI or truncated UTF-8), so
/// the caller can retain the bytes and retry once more input arrives. A lone
/// ESC also returns null; the caller resolves it as an Escape key on timeout.
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

fn decodeEscape(bytes: []const u8) ?DecodeResult {
    // A lone ESC (or `ESC` alone so far) is ambiguous with the start of a
    // sequence; defer to the caller's timeout flush.
    if (bytes.len == 1) return null;
    return switch (bytes[1]) {
        '[', 'O' => decodeCsi(bytes),
        else => .{ .key = .escape, .used = 1 },
    };
}

fn decodeCsi(bytes: []const u8) ?DecodeResult {
    // bytes[0] = ESC, bytes[1] = '[' or 'O'. Parameter/intermediate bytes run
    // until a final byte in 0x40..0x7e. Consume the whole sequence at once.
    var i: usize = 2;
    while (i < bytes.len) : (i += 1) {
        if (bytes[i] >= 0x40 and bytes[i] <= 0x7e) break;
    }
    if (i >= bytes.len) return null; // final byte not received yet
    const final = bytes[i];
    const params = bytes[2..i];
    const used = i + 1;
    const key: Key = switch (final) {
        'A' => .arrow_up,
        'B' => .arrow_down,
        'C' => .arrow_right,
        'D' => .arrow_left,
        'H' => .home,
        'F' => .end,
        '~' => tildeKey(params),
        else => .{ .unknown = bytes[0..used] },
    };
    return .{ .key = key, .used = used };
}

fn tildeKey(params: []const u8) Key {
    if (std.mem.eql(u8, params, "1") or std.mem.eql(u8, params, "7")) return .home;
    if (std.mem.eql(u8, params, "3")) return .delete;
    if (std.mem.eql(u8, params, "4") or std.mem.eql(u8, params, "8")) return .end;
    if (std.mem.eql(u8, params, "5")) return .page_up;
    if (std.mem.eql(u8, params, "6")) return .page_down;
    return .{ .unknown = params };
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

test "incomplete escape sequences return null instead of leaking bytes" {
    // A split arrow key must not decode the leftover '[' / 'O' as a literal char.
    try std.testing.expect(decode("\x1b") == null);
    try std.testing.expect(decode("\x1b[") == null);
    try std.testing.expect(decode("\x1b[3") == null);
    try std.testing.expect(decode("\x1bO") == null);
}

test "application-cursor arrows and full CSI consume the whole sequence" {
    try std.testing.expectEqual(Key.arrow_up, decode("\x1bOA").?.key);
    try std.testing.expectEqual(@as(usize, 3), decode("\x1bOA").?.used);
    try std.testing.expectEqual(Key.page_up, decode("\x1b[5~").?.key);
    try std.testing.expectEqual(@as(usize, 4), decode("\x1b[5~").?.used);
}

test "truncated utf8 returns null" {
    try std.testing.expect(decode("\xf0\x9f") == null);
}
