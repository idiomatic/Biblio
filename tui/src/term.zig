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
    suspend_app,
    /// The screen needs redrawing (after the app was suspended and resumed).
    redraw,
};

pub const Size = struct { rows: u16, cols: u16 };

/// The terminal's original settings while the app owns it, for `restore` (called also from signal and panic handlers).
var saved_termios: ?posix.termios = null;

/// Puts the screen and termios back; safe to call more than once, and from signal handlers.
pub fn restore() void {
    const saved = saved_termios orelse return;
    saved_termios = null;
    const reset = "\x1b[0m\x1b[?25h\x1b[?1049l";
    _ = std.c.write(posix.STDOUT_FILENO, reset, reset.len);
    posix.tcsetattr(posix.STDIN_FILENO, .FLUSH, saved) catch {};
}

fn onFatalSignal(sig: posix.SIG) callconv(.c) void {
    restore();
    // The handler was reset to the default on entry; raising again ends the process as usual.
    posix.raise(sig) catch {};
}

/// Restores the terminal when the process is killed by a signal (the handlers reset themselves, then re-raise).
fn installSignalHandlers() void {
    const act: posix.Sigaction = .{
        .handler = .{ .handler = onFatalSignal },
        .mask = posix.sigemptyset(),
        .flags = posix.SA.RESETHAND,
    };
    for ([_]posix.SIG{ .TERM, .HUP, .INT, .QUIT }) |sig| posix.sigaction(sig, &act, null);
}

pub const Terminal = struct {
    io: std.Io,
    saved: posix.termios,
    pending: [64]u8 = undefined,
    pending_len: usize = 0,

    pub fn init(io: std.Io) !Terminal {
        const saved = try posix.tcgetattr(posix.STDIN_FILENO);
        saved_termios = saved;
        errdefer saved_termios = null;
        installSignalHandlers();
        return enter(io, saved);
    }

    fn enter(io: std.Io, saved: posix.termios) !Terminal {
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

    pub fn deinit(_: *Terminal) void {
        restore();
    }

    /// Ctrl+Z (raw mode swallows it): hands the terminal back, stops until continued, then takes it again.
    fn suspendSelf(t: *Terminal) void {
        restore();
        posix.raise(.STOP) catch {};
        saved_termios = t.saved;
        const again = enter(t.io, t.saved) catch return;
        t.* = again;
    }

    pub fn write(t: *const Terminal, bytes: []const u8) void {
        std.Io.File.stdout().writeStreamingAll(t.io, bytes) catch {};
    }

    pub fn size(_: *const Terminal) Size {
        var ws: posix.winsize = undefined;
        if (std.c.ioctl(posix.STDOUT_FILENO, std.c.T.IOCGWINSZ, &ws) != 0 or ws.col == 0) return .{ .rows = 24, .cols = 80 };
        return .{ .rows = ws.row, .cols = ws.col };
    }

    /// Appends what stdin has within `timeout_ms`; false if nothing came.
    fn fill(t: *Terminal, timeout_ms: i32) bool {
        if (t.pending_len == t.pending.len) return false;
        var fds = [_]posix.pollfd{.{ .fd = posix.STDIN_FILENO, .events = posix.POLL.IN, .revents = 0 }};
        if ((posix.poll(&fds, timeout_ms) catch 0) == 0) return false;
        const n = posix.read(posix.STDIN_FILENO, t.pending[t.pending_len..]) catch return false;
        t.pending_len += n;
        return n > 0;
    }

    /// The next key, or null if none arrives within `timeout_ms`.
    pub fn readKey(t: *Terminal, timeout_ms: i32) ?Key {
        if (t.pending_len == 0 and !t.fill(timeout_ms)) return null;
        // A sequence split across reads: wait briefly for the rest (a lone Esc waits too).
        while (parseKey(t.pending[0..t.pending_len], false) == null) {
            if (!t.fill(escape_wait_ms)) break;
        }
        const key, const used = parseKey(t.pending[0..t.pending_len], true).?;
        std.mem.copyForwards(u8, t.pending[0 .. t.pending_len - used], t.pending[used..t.pending_len]);
        t.pending_len -= used;
        if (key == .suspend_app) {
            t.suspendSelf();
            return .redraw;
        }
        return key;
    }
};

/// How long to wait for the rest of a key's bytes once its start has arrived.
const escape_wait_ms = 30;

/// The first key in `bytes`, and how many bytes it took; null if `bytes` may be the start of
/// a longer sequence, unless `final` (nothing more is coming), when it's decoded as it is.
pub fn parseKey(bytes: []const u8, final: bool) ?struct { Key, usize } {
    const b = bytes[0];
    switch (b) {
        3 => return .{ .ctrl_c, 1 },
        26 => return .{ .suspend_app, 1 },
        9 => return .{ .tab, 1 },
        '\r', '\n' => return .{ .enter, 1 },
        8, 127 => return .{ .backspace, 1 },
        0x1b => {
            if (bytes.len == 1) return if (final) .{ .escape, 1 } else null;
            if (bytes[1] != '[' and bytes[1] != 'O') return .{ .escape, 1 };
            // CSI or SS3: parameters, then a final byte from '@' to '~'.
            var i: usize = 2;
            while (i < bytes.len and (bytes[i] < 0x40 or bytes[i] > 0x7e)) i += 1;
            if (i == bytes.len) return if (final) .{ .escape, bytes.len } else null;
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
            const len = std.unicode.utf8ByteSequenceLength(b) catch return .{ .{ .char = 0xfffd }, 1 };
            if (len > bytes.len) return if (final) .{ .{ .char = 0xfffd }, bytes.len } else null;
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
    /// Control characters show as spaces. Returns the columns used.
    pub fn text(f: *Frame, s: []const u8, width: usize, pad: bool) usize {
        const fitted = fit(clean(f.a, s), width);
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

/// The longest prefix of `s` that fits in `width` columns, leaving room for "…" if it had to
/// be cut.
pub fn fit(s: []const u8, width: usize) struct { bytes: []const u8, cols: usize, cut: bool } {
    if (width == 0) return .{ .bytes = "", .cols = 0, .cut = false };
    const all = columns(s);
    if (all <= width) return .{ .bytes = s, .cols = all, .cut = false };
    const p = prefix(s, width - 1);
    return .{ .bytes = s[0..p.len], .cols = p.cols, .cut = true };
}

/// The longest prefix of `s` within `width` columns: its length in bytes, and its columns.
pub fn prefix(s: []const u8, width: usize) struct { len: usize, cols: usize } {
    var i: usize = 0;
    var cols: usize = 0;
    while (i < s.len) {
        const c = decode(s, i);
        const w = charWidth(c.cp);
        if (cols + w > width) break;
        cols += w;
        i += c.len;
    }
    return .{ .len = i, .cols = cols };
}

/// The columns `s` takes in a terminal.
pub fn columns(s: []const u8) usize {
    var i: usize = 0;
    var cols: usize = 0;
    while (i < s.len) {
        const c = decode(s, i);
        cols += charWidth(c.cp);
        i += c.len;
    }
    return cols;
}

/// The code point at `s[i]` and its length in bytes; U+FFFD for one byte of invalid UTF-8.
pub fn decode(s: []const u8, i: usize) struct { cp: u21, len: usize } {
    const len = std.unicode.utf8ByteSequenceLength(s[i]) catch return .{ .cp = 0xfffd, .len = 1 };
    if (i + len > s.len) return .{ .cp = 0xfffd, .len = 1 };
    const cp = std.unicode.utf8Decode(s[i .. i + len]) catch return .{ .cp = 0xfffd, .len = 1 };
    return .{ .cp = cp, .len = len };
}

/// `s` with control characters as spaces and invalid UTF-8 as U+FFFD, so it can't move the
/// cursor or restyle the screen; `s` itself if it's clean already.
pub fn clean(a: std.mem.Allocator, s: []const u8) []const u8 {
    var i: usize = 0;
    while (i < s.len) {
        const c = decode(s, i);
        if (isControl(c.cp) or (c.cp == 0xfffd and c.len == 1)) break;
        i += c.len;
    } else return s;
    var out: std.ArrayList(u8) = .empty;
    out.appendSlice(a, s[0..i]) catch return "";
    while (i < s.len) {
        const c = decode(s, i);
        if (isControl(c.cp)) {
            out.append(a, ' ') catch return "";
        } else if (c.cp == 0xfffd and c.len == 1) {
            out.appendSlice(a, "\u{fffd}") catch return "";
        } else {
            out.appendSlice(a, s[i .. i + c.len]) catch return "";
        }
        i += c.len;
    }
    return out.items;
}

fn isControl(cp: u21) bool {
    return cp < 0x20 or (cp >= 0x7f and cp < 0xa0);
}

/// Columns a code point takes: 0 for combining marks and other zero-width characters, 2 for
/// East Asian wide characters and emoji, else 1. A small table of the common ranges, not all
/// of Unicode's.
pub fn charWidth(cp: u21) usize {
    const Range = struct { u21, u21 };
    const zero = [_]Range{
        .{ 0x0300, 0x036f }, .{ 0x0483, 0x0489 },   .{ 0x0591, 0x05bd },   .{ 0x05bf, 0x05c7 },
        .{ 0x0610, 0x061a }, .{ 0x064b, 0x065f },   .{ 0x0670, 0x0670 },   .{ 0x06d6, 0x06ed },
        .{ 0x0900, 0x0903 }, .{ 0x093a, 0x094f },   .{ 0x0e31, 0x0e31 },   .{ 0x0e34, 0x0e3a },
        .{ 0x0e47, 0x0e4e }, .{ 0x1160, 0x11ff },   .{ 0x1ab0, 0x1aff },   .{ 0x1dc0, 0x1dff },
        .{ 0x200b, 0x200f }, .{ 0x202a, 0x202e },   .{ 0x2060, 0x2064 },   .{ 0x20d0, 0x20ff },
        .{ 0x302a, 0x302f }, .{ 0x3099, 0x309a },   .{ 0xfe00, 0xfe0f },   .{ 0xfe20, 0xfe2f },
        .{ 0xfeff, 0xfeff }, .{ 0x1f3fb, 0x1f3ff }, .{ 0xe0000, 0xe0fff },
    };
    const wide = [_]Range{
        .{ 0x1100, 0x115f },   .{ 0x231a, 0x231b },   .{ 0x2329, 0x232a },   .{ 0x23e9, 0x23ec },
        .{ 0x23f0, 0x23f0 },   .{ 0x23f3, 0x23f3 },   .{ 0x25fd, 0x25fe },   .{ 0x2614, 0x2615 },
        .{ 0x2648, 0x2653 },   .{ 0x267f, 0x267f },   .{ 0x2693, 0x2693 },   .{ 0x26a1, 0x26a1 },
        .{ 0x26aa, 0x26ab },   .{ 0x26bd, 0x26be },   .{ 0x26c4, 0x26c5 },   .{ 0x26ce, 0x26ce },
        .{ 0x26d4, 0x26d4 },   .{ 0x26ea, 0x26ea },   .{ 0x26f2, 0x26f5 },   .{ 0x26fa, 0x26fa },
        .{ 0x26fd, 0x26fd },   .{ 0x2705, 0x2705 },   .{ 0x270a, 0x270b },   .{ 0x2728, 0x2728 },
        .{ 0x274c, 0x274c },   .{ 0x274e, 0x274e },   .{ 0x2753, 0x2755 },   .{ 0x2757, 0x2757 },
        .{ 0x2795, 0x2797 },   .{ 0x27b0, 0x27b0 },   .{ 0x27bf, 0x27bf },   .{ 0x2b1b, 0x2b1c },
        .{ 0x2b50, 0x2b50 },   .{ 0x2b55, 0x2b55 },   .{ 0x2e80, 0x303e },   .{ 0x3041, 0x33ff },
        .{ 0x3400, 0x4dbf },   .{ 0x4e00, 0x9fff },   .{ 0xa000, 0xa4cf },   .{ 0xa960, 0xa97f },
        .{ 0xac00, 0xd7a3 },   .{ 0xf900, 0xfaff },   .{ 0xfe10, 0xfe19 },   .{ 0xfe30, 0xfe6f },
        .{ 0xff00, 0xff60 },   .{ 0xffe0, 0xffe6 },   .{ 0x16fe0, 0x18cff }, .{ 0x1b000, 0x1b2ff },
        .{ 0x1f004, 0x1f004 }, .{ 0x1f0cf, 0x1f0cf }, .{ 0x1f18e, 0x1f18e }, .{ 0x1f191, 0x1f19a },
        .{ 0x1f200, 0x1f2ff }, .{ 0x1f300, 0x1f320 }, .{ 0x1f32d, 0x1f335 }, .{ 0x1f337, 0x1f37c },
        .{ 0x1f37e, 0x1f393 }, .{ 0x1f3a0, 0x1f3ca }, .{ 0x1f3cf, 0x1f3d3 }, .{ 0x1f3e0, 0x1f3f0 },
        .{ 0x1f3f4, 0x1f3f4 }, .{ 0x1f3f8, 0x1f43e }, .{ 0x1f440, 0x1f440 }, .{ 0x1f442, 0x1f4fc },
        .{ 0x1f4ff, 0x1f53d }, .{ 0x1f54b, 0x1f54e }, .{ 0x1f550, 0x1f567 }, .{ 0x1f57a, 0x1f57a },
        .{ 0x1f595, 0x1f596 }, .{ 0x1f5a4, 0x1f5a4 }, .{ 0x1f5fb, 0x1f64f }, .{ 0x1f680, 0x1f6c5 },
        .{ 0x1f6cc, 0x1f6cc }, .{ 0x1f6d0, 0x1f6d2 }, .{ 0x1f6d5, 0x1f6d7 }, .{ 0x1f6dc, 0x1f6df },
        .{ 0x1f6eb, 0x1f6ec }, .{ 0x1f6f4, 0x1f6fc }, .{ 0x1f7e0, 0x1f7eb }, .{ 0x1f7f0, 0x1f7f0 },
        .{ 0x1f90c, 0x1f93a }, .{ 0x1f93c, 0x1f945 }, .{ 0x1f947, 0x1f9ff }, .{ 0x1fa70, 0x1faff },
        .{ 0x20000, 0x2fffd }, .{ 0x30000, 0x3fffd },
    };
    if (cp < 0x300) return 1;
    for (zero) |r| if (cp >= r[0] and cp <= r[1]) return 0;
    for (wide) |r| if (cp >= r[0] and cp <= r[1]) return 2;
    return 1;
}

/// Splits `s` into lines of at most `width` columns, at spaces where possible.
pub fn wrap(a: std.mem.Allocator, s: []const u8, width: usize) []const []const u8 {
    const w = @max(width, 1);
    var lines: std.ArrayList([]const u8) = .empty;
    var paragraphs = std.mem.splitScalar(u8, s, '\n');
    while (paragraphs.next()) |paragraph| {
        var rest = std.mem.trim(u8, paragraph, " \r\t");
        if (rest.len == 0) lines.append(a, "") catch {};
        while (rest.len > 0) {
            if (columns(rest) <= w) {
                lines.append(a, rest) catch {};
                break;
            }
            const p = prefix(rest, w);
            // Break at a space just past the edge, else after the last space that fits, else
            // mid-word; a character wider than the line still takes one.
            var end = if (p.len < rest.len and rest[p.len] == ' ') p.len else std.mem.lastIndexOfScalar(u8, rest[0..p.len], ' ') orelse p.len;
            if (end == 0) end = if (p.len > 0) p.len else decode(rest, 0).len;
            lines.append(a, std.mem.trimEnd(u8, rest[0..end], " ")) catch {};
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
    try std.testing.expectEqual(Key.up, parseKey("\x1b[A", false).?[0]);
    try std.testing.expectEqual(Key.page_down, parseKey("\x1b[6~", false).?[0]);
    try std.testing.expectEqual(Key.back_tab, parseKey("\x1b[Z", false).?[0]);
    try std.testing.expectEqual(Key.escape, parseKey("\x1b", true).?[0]);
    try std.testing.expectEqual(@as(usize, 3), parseKey("\x1b[Bxyz", false).?[1]);
    try std.testing.expectEqual(Key{ .char = 'é' }, parseKey("é", false).?[0]);
    try std.testing.expectEqual(Key.enter, parseKey("\r", false).?[0]);
    try std.testing.expectEqual(Key{ .char = 0xfffd }, parseKey("\x80", false).?[0]);
}

test "parseKey across reads" {
    // The start of a sequence waits for the rest, unless nothing more is coming.
    try std.testing.expectEqual(null, parseKey("\x1b", false));
    try std.testing.expectEqual(null, parseKey("\x1b[", false));
    try std.testing.expectEqual(null, parseKey("\x1b[6", false));
    try std.testing.expectEqual(null, parseKey("\xc3", false));
    try std.testing.expectEqual(null, parseKey("\xe6\x97", false));
    try std.testing.expectEqual(Key.escape, parseKey("\x1b[", true).?[0]);
    try std.testing.expectEqual(@as(usize, 2), parseKey("\x1b[", true).?[1]);
    try std.testing.expectEqual(Key{ .char = 0xfffd }, parseKey("\xc3", true).?[0]);
    // Once the rest arrives, it's one key.
    try std.testing.expectEqual(Key.page_up, parseKey("\x1b[5~", false).?[0]);
    try std.testing.expectEqual(Key{ .char = '日' }, parseKey("\xe6\x97\xa5", false).?[0]);
    // Alt+key is Esc, then the key.
    try std.testing.expectEqual(Key.escape, parseKey("\x1bx", false).?[0]);
}

test columns {
    try std.testing.expectEqual(@as(usize, 4), columns("Dune"));
    try std.testing.expectEqual(@as(usize, 4), columns("日本"));
    try std.testing.expectEqual(@as(usize, 4), columns("Cafe\u{301}"));
    try std.testing.expectEqual(@as(usize, 2), columns("📚"));
    try std.testing.expectEqual(@as(usize, 2), columns("한"));
}

test fit {
    try std.testing.expectEqualStrings("Dune", fit("Dune", 10).bytes);
    const f = fit("Messiah of Dune", 8);
    try std.testing.expectEqualStrings("Messiah", f.bytes);
    try std.testing.expect(f.cut);
    try std.testing.expectEqualStrings("Café", fit("Café au lait", 5).bytes);
    // A wide character that doesn't fit before "…" is left out whole.
    const g = fit("日本語", 4);
    try std.testing.expectEqualStrings("日", g.bytes);
    try std.testing.expectEqual(@as(usize, 2), g.cols);
    try std.testing.expectEqual(@as(usize, 4), fit("日本", 4).cols);
}

test clean {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const s = "Dune";
    try std.testing.expectEqual(s.ptr, clean(a, s).ptr);
    try std.testing.expectEqualStrings("a b [2J c", clean(a, "a\tb\x1b[2J\u{9b}c"));
    try std.testing.expectEqualStrings("x\u{fffd}y", clean(a, "x\xffy"));
}

test wrap {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const lines = wrap(a, "the quick brown fox", 10);
    try std.testing.expectEqualStrings("the quick", lines[0]);
    try std.testing.expectEqualStrings("brown fox", lines[1]);
    // A word one column too long is cut, not let through.
    const long = wrap(a, "abcde", 4);
    try std.testing.expectEqual(@as(usize, 2), long.len);
    try std.testing.expectEqualStrings("abcd", long[0]);
    try std.testing.expectEqualStrings("e", long[1]);
    // A word ending exactly at the edge stays on its line.
    const edge = wrap(a, "abcd efgh", 4);
    try std.testing.expectEqualStrings("abcd", edge[0]);
    try std.testing.expectEqualStrings("efgh", edge[1]);
    const wide = wrap(a, "日本語です", 4);
    try std.testing.expectEqual(@as(usize, 3), wide.len);
    try std.testing.expectEqualStrings("日本", wide[0]);
    try std.testing.expectEqualStrings("す", wide[2]);
    for (wrap(a, "a b c d e f g h i j k l m n o p q r s t u v w x y z", 5)) |line| try std.testing.expect(columns(line) <= 5);
}

test color256 {
    try std.testing.expectEqual(@as(?Color, 16), color256("#000000"));
    try std.testing.expectEqual(@as(?Color, 231), color256("#ffffff"));
    try std.testing.expectEqual(@as(?Color, 23), color256("#0a3f58"));
}
