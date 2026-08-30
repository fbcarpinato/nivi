const std = @import("std");
const builtin = @import("builtin");

pub const Size = struct {
    width: usize,
    height: usize,
};

pub const RawMode = struct {
    original: std.posix.termios,
    enabled: bool = false,

    pub fn enable(stdin_fd: std.posix.fd_t) !RawMode {
        if (!supportsRawMode()) return error.UnsupportedTerminal;
        const original = try std.posix.tcgetattr(stdin_fd);
        var raw = original;

        raw.iflag.BRKINT = false;
        raw.iflag.ICRNL = false;
        raw.iflag.INPCK = false;
        raw.iflag.ISTRIP = false;
        raw.iflag.IXON = false;
        raw.oflag.OPOST = false;
        raw.lflag.ECHO = false;
        raw.lflag.ICANON = false;
        raw.lflag.IEXTEN = false;
        raw.lflag.ISIG = false;
        raw.cflag.CSIZE = .CS8;
        raw.cc[@intFromEnum(std.posix.V.MIN)] = 0;
        raw.cc[@intFromEnum(std.posix.V.TIME)] = 0;

        try std.posix.tcsetattr(stdin_fd, .FLUSH, raw);
        return .{ .original = original, .enabled = true };
    }

    pub fn disable(self: *RawMode, stdin_fd: std.posix.fd_t) void {
        if (!self.enabled) return;
        std.posix.tcsetattr(stdin_fd, .FLUSH, self.original) catch {};
        self.enabled = false;
    }
};

pub fn supportsRawMode() bool {
    return switch (builtin.os.tag) {
        .linux, .macos, .freebsd, .netbsd, .openbsd, .dragonfly => true,
        else => false,
    };
}

pub fn size(stdout_fd: std.posix.fd_t, environ: std.process.Environ.Map) Size {
    if (sizeFromIoctl(stdout_fd)) |detected| return detected;
    return .{ .width = envInt(environ, "COLUMNS", 80), .height = envInt(environ, "LINES", 24) };
}

fn sizeFromIoctl(stdout_fd: std.posix.fd_t) ?Size {
    switch (builtin.os.tag) {
        .linux => {
            var ws: std.posix.winsize = .{ .row = 0, .col = 0, .xpixel = 0, .ypixel = 0 };
            const rc = std.os.linux.ioctl(stdout_fd, std.os.linux.T.IOCGWINSZ, @intFromPtr(&ws));
            if (std.posix.errno(rc) != .SUCCESS or ws.row == 0 or ws.col == 0) return null;
            return .{ .width = ws.col, .height = ws.row };
        },
        else => return null,
    }
}

fn envInt(environ: std.process.Environ.Map, name: []const u8, default: usize) usize {
    const value = environ.get(name) orelse return default;
    return std.fmt.parseUnsigned(usize, value, 10) catch default;
}

pub const Screen = struct {
    pub fn enter(writer: *std.Io.Writer) !void {
        try writer.writeAll("\x1b[?1049h\x1b[?25l\x1b[2J");
    }

    pub fn leave(writer: *std.Io.Writer) !void {
        try writer.writeAll("\x1b[0m\x1b[?25h\x1b[?1049l");
    }
};

test "screen lifecycle emits alternate screen sequences" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    try Screen.enter(&out.writer);
    try Screen.leave(&out.writer);
    try out.writer.flush();

    const written = out.written();
    try std.testing.expect(std.mem.indexOf(u8, written, "\x1b[?1049h") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "\x1b[?1049l") != null);
}
