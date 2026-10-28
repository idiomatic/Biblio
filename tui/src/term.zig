//! The terminal: raw mode, keys and drawing, using only termios and xterm escape sequences
//! (xterm-256color). Each frame is built in memory and written at once, so it doesn't flicker.

const std = @import("std");
const posix = std.posix;

pub const Key = union(enum) {
    char: u21,
    up,
    down,
    left,
    right,
    page_up,
    page_down,
    home,
    end,
    enter,
    tab,
    back_tab,
    backspace,
    delete,
    escape,
    ctrl_c,
};

pub const Size = struct { rows: u16, cols: u16 };

pub const Terminal = struct {
    io: std.Io,
    saved: posix.termios,
    pending: [64]u8 = undefined,
    pending_len: usize = 0,

    pub fn init(io: std.Io) !Terminal {
        const saved = try posix.tcgetattr(posix.STDIN_FILENO);
        var raw = saved;
        raw.lflag.ECHO = false;
        raw.lflag.ICANON = false;
        raw.lflag.ISIG = false;
        raw.lflag.IEXTEN = false;
        raw.iflag.IXON = false;
        raw.iflag.ICRNL = false;
        raw.cc[@backingInt(posix.V.MIN)] = 1;
        raw.cc[@backingInt(posix.V.TIME)] = 0;
        try posix.tcsetattr(posix.STDIN_FILENO, .FLUSH, raw);
        const t: Terminal = .{ .io = io, .saved = saved };
        // Alternate screen, hidden cursor.
        t.write("\x1b[?1049h\x1b[?25l");
        return t;
    }

    pub fn deinit(t: *Terminal) void {
        t.write("\x1b[0m\x1b[?25h\x1b[?1049l");
        posix.tcsetattr(posix.STDIN_FILENO, .FLUSH, t.saved) catch {};
    }

    pub fn write(t: *const Terminal, bytes: []const u8) void {
        std.Io.File.stdout().writeStreamingAll(t.io, bytes) catch {};
    }

    pub fn size(_: *const Terminal) Size {
        var ws: posix.winsize = undefined;
        if (std.c.ioctl(posix.STDOUT_FILENO, std.c.T.IOCGWINSZ, &ws) != 0 or ws.col == 0) return .{ .rows = 24, .cols = 80 };
        return .{ .rows = ws.row, .cols = ws.col };
    }

    /// The next key, or null if none arrives within `timeout_ms`.
    pub fn readKey(t: *Terminal, timeout_ms: i32) ?Key {
        if (t.pending_len == 0) {
            var fds = [_]posix.pollfd{.{ .fd = posix.STDIN_FILENO, .events = posix.POLL.IN, .revents = 0 }};
            if ((posix.poll(&fds, timeout_ms) catch 0) == 0) return null;
            t.pending_len = posix.read(posix.STDIN_FILENO, &t.pending) catch return null;
            if (t.pending_len == 0) return null;
        }
        const key, const used = parseKey(t.pending[0..t.pending_len]);
        std.mem.copyForwards(u8, t.pending[0 .. t.pending_len - used], t.pending[used..t.pending_len]);
        t.pending_len -= used;
        return key;
    }
};

/// The first key in `bytes`, and how many bytes it took.
pub fn parseKey(bytes: []const u8) struct { Key, usize } {
    const b = bytes[0];
    switch (b) {
        3 => return .{ .ctrl_c, 1 },
        9 => return .{ .tab, 1 },
        '\r', '\n' => return .{ .enter, 1 },
        8, 127 => return .{ .backspace, 1 },
        0x1b => {
            if (bytes.len < 3 or (bytes[1] != '[' and bytes[1] != 'O')) return .{ .escape, 1 };
            // CSI or SS3: parameters, then a final byte from '@' to '~'.
            var i: usize = 2;
            while (i < bytes.len and (bytes[i] < 0x40 or bytes[i] > 0x7e)) i += 1;
            if (i == bytes.len) return .{ .escape, bytes.len };
            const params = bytes[2..i];
            const key: Key = switch (bytes[i]) {
                'A' => .up,
                'B' => .down,
                'C' => .right,
                'D' => .left,
                'H' => .home,
                'F' => .end,
                'Z' => .back_tab,
                '~' => if (std.mem.eql(u8, params, "5")) .page_up else if (std.mem.eql(u8, params, "6")) .page_down else if (std.mem.eql(u8, params, "3")) .delete else if (std.mem.eql(u8, params, "1") or std.mem.eql(u8, params, "7")) .home else if (std.mem.eql(u8, params, "4") or std.mem.eql(u8, params, "8")) .end else .escape,
                else => .escape,
            };
            return .{ key, i + 1 };
        },
        else => {
            const len = std.unicode.utf8ByteSequenceLength(b) catch return .{ .{ .char = b }, 1 };
            if (len > bytes.len) return .{ .{ .char = 0xfffd }, bytes.len };
            const c = std.unicode.utf8Decode(bytes[0..len]) catch return .{ .{ .char = 0xfffd }, len };
            return .{ .{ .char = c }, len };
        },
    }
}

/// xterm-256color palette indexes.
pub const Color = u8;
pub const Style = struct {
    fg: ?Color = null,
    bg: ?Color = null,
    bold: bool = false,
    dim: bool = false,
    reverse: bool = false,
    underline: bool = false,
};

/// One screen's worth of output.
pub const Frame = struct {
    out: std.ArrayList(u8) = .empty,
    a: std.mem.Allocator,
    size: Size,

    pub fn begin(a: std.mem.Allocator, size: Size) Frame {
        var f: Frame = .{ .a = a, .size = size };
        f.raw("\x1b[0m\x1b[H\x1b[2J");
        return f;
    }

    pub fn raw(f: *Frame, bytes: []const u8) void {
        f.out.appendSlice(f.a, bytes) catch {};
    }

    pub fn print(f: *Frame, comptime fmt: []const u8, args: anytype) void {
        f.out.print(f.a, fmt, args) catch {};
    }

    /// Moves to a 0-based row and column.
    pub fn at(f: *Frame, row: usize, col: usize) void {
        f.print("\x1b[{d};{d}H", .{ row + 1, col + 1 });
    }

    pub fn style(f: *Frame, s: Style) void {
        f.raw("\x1b[0");
        if (s.bold) f.raw(";1");
        if (s.dim) f.raw(";2");
        if (s.underline) f.raw(";4");
        if (s.reverse) f.raw(";7");
        if (s.fg) |c| f.print(";38;5;{d}", .{c});
        if (s.bg) |c| f.print(";48;5;{d}", .{c});
        f.raw("m");
    }

    /// Writes `text` in `width` columns: cut with "…" if longer, padded with spaces if `pad`.
    /// Returns the columns used.
    pub fn text(f: *Frame, s: []const u8, width: usize, pad: bool) usize {
        const fitted = fit(s, width);
        f.raw(fitted.bytes);
        var used = fitted.cols;
        if (fitted.cut) {
            f.raw("…");
            used += 1;
        }
        if (pad) while (used < width) : (used += 1) f.raw(" ");
        return used;
    }

    /// Fills the rest of the row from `col` in the current style.
    pub fn fill(f: *Frame, col: usize) void {
        var c = col;
        while (c < f.size.cols) : (c += 1) f.raw(" ");
    }
};

/// The longest prefix of `s` that fits in `width` columns (one per code point; control
/// characters dropped by the caller), leaving room for "…" if it had to be cut.
pub fn fit(s: []const u8, width: usize) struct { bytes: []const u8, cols: usize, cut: bool } {
    if (width == 0) return .{ .bytes = "", .cols = 0, .cut = false };
    if (columns(s) <= width) return .{ .bytes = s, .cols = columns(s), .cut = false };
    var i: usize = 0;
    var cols: usize = 0;
    while (i < s.len and cols < width - 1) {
        i += std.unicode.utf8ByteSequenceLength(s[i]) catch 1;
        cols += 1;
    }
    return .{ .bytes = s[0..@min(i, s.len)], .cols = cols, .cut = true };
}

pub fn columns(s: []const u8) usize {
    return std.unicode.utf8CountCodepoints(s) catch s.len;
}

/// Splits `s` into lines of at most `width` columns, at spaces where possible.
pub fn wrap(a: std.mem.Allocator, s: []const u8, width: usize) []const []const u8 {
    var lines: std.ArrayList([]const u8) = .empty;
    var paragraphs = std.mem.splitScalar(u8, s, '\n');
    while (paragraphs.next()) |paragraph| {
        var rest = std.mem.trim(u8, paragraph, " \r\t");
        if (rest.len == 0) lines.append(a, "") catch {};
        while (rest.len > 0) {
            const f = fit(rest, width + 1);
            if (!f.cut) {
                lines.append(a, rest) catch {};
                break;
            }
            const cut = std.mem.lastIndexOfScalar(u8, f.bytes, ' ') orelse f.bytes.len;
            const end = if (cut == 0) f.bytes.len else cut;
            lines.append(a, rest[0..end]) catch {};
            rest = std.mem.trimStart(u8, rest[end..], " ");
        }
    }
    return lines.items;
}

/// The nearest xterm-256color cube color to "#RRGGBB".
pub fn color256(hex: []const u8) ?Color {
    const h = if (std.mem.startsWith(u8, hex, "#")) hex[1..] else hex;
    if (h.len != 6) return null;
    const v = std.fmt.parseInt(u24, h, 16) catch return null;
    const level = struct {
        fn of(c: u8) u8 {
            // The cube's channel levels are 0, 95, 135, 175, 215 and 255.
            return if (c < 48) 0 else if (c < 115) 1 else (c - 35) / 40;
        }
    }.of;
    return 16 + 36 * level(@intCast(v >> 16)) + 6 * level(@intCast((v >> 8) & 0xff)) + level(@intCast(v & 0xff));
}

test parseKey {
    try std.testing.expectEqual(Key.up, parseKey("\x1b[A")[0]);
    try std.testing.expectEqual(Key.page_down, parseKey("\x1b[6~")[0]);
    try std.testing.expectEqual(Key.back_tab, parseKey("\x1b[Z")[0]);
    try std.testing.expectEqual(Key.escape, parseKey("\x1b")[0]);
    try std.testing.expectEqual(@as(usize, 3), parseKey("\x1b[Bxyz")[1]);
    try std.testing.expectEqual(Key{ .char = 'é' }, parseKey("é")[0]);
    try std.testing.expectEqual(Key.enter, parseKey("\r")[0]);
}

test fit {
    try std.testing.expectEqualStrings("Dune", fit("Dune", 10).bytes);
    const f = fit("Messiah of Dune", 8);
    try std.testing.expectEqualStrings("Messiah", f.bytes);
    try std.testing.expect(f.cut);
    try std.testing.expectEqualStrings("Café", fit("Café au lait", 5).bytes);
}

test wrap {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const lines = wrap(arena.allocator(), "the quick brown fox", 10);
    try std.testing.expectEqualStrings("the quick", lines[0]);
    try std.testing.expectEqualStrings("brown fox", lines[1]);
}

test color256 {
    try std.testing.expectEqual(@as(?Color, 16), color256("#000000"));
    try std.testing.expectEqual(@as(?Color, 231), color256("#ffffff"));
    try std.testing.expectEqual(@as(?Color, 23), color256("#0a3f58"));
}
