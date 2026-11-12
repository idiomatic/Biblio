//! What the signed-in login borrowed before: libbiblio's index of its borrowing history
//! (`biblio_borrowed_*`), kept in a private file, synced in the background, and asked by
//! list rows, item detail, and the "Not Borrowed" filter.

const std = @import("std");
const biblio = @import("biblio");
const gtk = @import("gtk.zig");
const c = gtk.c;
const core = @import("core.zig");
const capi = core.capi;
const store = @import("store.zig");
const Window = @import("window.zig").Window;

pub const Index = biblio.borrowed.Index;

pub const Borrowed = struct {
    window: *Window,
    index: *Index,
    /// Set once the patron is known: the saved index was imported, or history was found off.
    started: bool = false,
    /// The library's borrowing history is off, so nothing is kept.
    off: bool = false,
    /// A sync waits for the sidebar badges to load.
    waiting: bool = false,
    /// The history page being fetched; one at a time, so a sync begun meanwhile carries on
    /// from its response.
    page: i64 = 0,
    in_flight: bool = false,

    pub fn create(w: *Window) *Borrowed {
        const b = core.gpa.create(Borrowed) catch unreachable;
        b.* = .{ .window = w, .index = capi.biblio_borrowed_index_new().? };
        return b;
    }

    pub fn free(b: *Borrowed) void {
        capi.biblio_borrowed_index_free(b.index);
        core.gpa.destroy(b);
    }

    /// After signing in or reloading the patron: keep nothing while borrowing history is off;
    /// otherwise load the saved index and sync once the badges load (or now, if it was off).
    pub fn patronChanged(b: *Borrowed, patron: *const capi.Patron) void {
        if (patron.has_borrowing_history_enabled and !patron.borrowing_history_enabled) {
            if (b.started and b.off) return;
            b.started = true;
            b.off = true;
            b.waiting = false;
            return b.forget();
        }
        const was_off = b.off;
        b.off = false;
        if (!b.started) {
            b.started = true;
            if (store.loadBorrowed(b.window.subdomain, b.window.username)) |bytes| {
                defer c.g_free(bytes.ptr);
                _ = capi.biblio_borrowed_index_import(b.index, bytes.ptr, bytes.len);
            }
            b.waiting = true;
            b.changed();
            return b.badgesLoaded();
        }
        if (was_off) b.sync();
    }

    /// Starts the first sync once the holds and checkouts badges have loaded.
    pub fn badgesLoaded(b: *Borrowed) void {
        if (!b.waiting) return;
        const w = b.window;
        for ([_]@import("window.zig").Section{ .holds, .checkouts }) |s| {
            if (w.list(s)) |l| if (capi.biblio_list_state(l.list).loading) return;
        }
        b.waiting = false;
        b.sync();
    }

    /// Catches up with new history (after sign-in and refreshes).
    pub fn sync(b: *Borrowed) void {
        if (b.off or !b.started or b.waiting) return;
        b.fetch(capi.biblio_borrowed_index_begin_sync(b.index));
    }

    /// Refresh Borrowing History: forgets the index and reads it all again.
    pub fn rebuild(b: *Borrowed) void {
        if (b.off or !b.started) return;
        b.waiting = false;
        b.fetch(capi.biblio_borrowed_index_rebuild(b.index));
        b.save();
    }

    /// Clears the index and deletes its file.
    fn forget(b: *Borrowed) void {
        capi.biblio_borrowed_index_clear(b.index);
        store.deleteBorrowed(b.window.subdomain, b.window.username);
        b.changed();
    }

    fn fetch(b: *Borrowed, page: i64) void {
        defer b.changed();
        if (page <= 0 or b.in_flight) return;
        const w = b.window;
        const j = w.job(&onPage, b) orelse return capi.biblio_borrowed_index_fail(b.index);
        b.page = page;
        b.in_flight = true;
        j.start(capi.biblio_history, .{ w.client, page, @as(?[*:0]const u8, null) });
    }

    fn onPage(data: ?*anyopaque, r: *core.Result) void {
        const b: *Borrowed = @ptrCast(@alignCast(data.?));
        if (b.window.finishPending()) return;
        b.in_flight = false;
        if (b.off) return;
        if (!r.ok) {
            capi.biblio_borrowed_index_fail(b.index);
            return b.changed();
        }
        const result = r.get(capi.ListPage) orelse {
            capi.biblio_borrowed_index_fail(b.index);
            return b.changed();
        };
        const next = capi.biblio_borrowed_index_apply_page(b.index, b.page, result);
        b.save();
        b.fetch(next);
    }

    fn save(b: *Borrowed) void {
        const w = b.window;
        // A login removed while its window is open keeps nothing.
        if (b.off or !store.hasUser(w.subdomain, w.username)) return;
        var len: usize = 0;
        const bytes = capi.biblio_borrowed_index_export(b.index, &len) orelse return;
        defer biblio.biblio_free(bytes);
        store.saveBorrowed(w.subdomain, w.username, bytes[0..len]);
    }

    fn changed(b: *Borrowed) void {
        b.window.borrowedChanged();
    }

    // MARK: Asking

    pub fn generation(b: *const Borrowed) u64 {
        return capi.biblio_borrowed_index_generation(b.index);
    }

    pub fn progress(b: *const Borrowed) capi.BorrowedProgress {
        return capi.biblio_borrowed_index_progress(b.index);
    }

    /// Whether the "Not Borrowed" filter may be offered.
    pub fn complete(b: *const Borrowed) bool {
        return !b.off and b.progress().complete;
    }

    pub fn lookup(b: *const Borrowed, bib: capi.Bib) capi.BorrowedResult {
        if (b.off) return .{ .match = .none, .format = null, .count = 0, .last_checkout = null, .last_returned = null };
        const author: ?[*:0]const u8 = if (bib.authors_count > 0) bib.authors[0] else null;
        return capi.biblio_borrowed(b.index, bib.id, bib.format, bib.title, author);
    }
};

// MARK: Wording

const months = [_][]const u8{ "January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December" };

/// "Mar 2024" (`short`) or "March 2024" from "2024-03-15"; null if it isn't such a date.
fn monthYear(a: std.mem.Allocator, date: ?[*:0]const u8, short: bool) ?[]const u8 {
    const d = core.str(date) orelse return null;
    if (d.len < 7 or d[4] != '-') return null;
    const m = std.fmt.parseInt(usize, d[5..7], 10) catch return null;
    if (m < 1 or m > 12) return null;
    const name = if (short) months[m - 1][0..3] else months[m - 1];
    return std.fmt.allocPrint(a, "{s} {s}", .{ name, d[0..4] }) catch null;
}

/// How another format reads after "Borrowed": "the audiobook", "on DVD", "the book", "as Kit".
fn phrase(a: std.mem.Allocator, code: []const u8, labels: []const capi.Pair) []const u8 {
    const in = struct {
        fn f(s: []const u8, set: []const []const u8) bool {
            for (set) |x| if (std.mem.eql(u8, s, x)) return true;
            return false;
        }
    }.f;
    if (in(code, &.{ "AB", "BOOK_CD", "PLAYAWAY_AUDIOBOOK" })) return "the audiobook";
    const name = core.formatName(a, code, labels);
    if (in(code, &.{ "DVD", "BLURAY", "UK", "DVD_PBLURAY", "VIDEO_ONLINE" })) return std.fmt.allocPrint(a, "on {s}", .{name}) catch name;
    if (in(code, &.{ "BK", "LPRINT", "EBOOK" })) {
        const lower = a.alloc(u8, name.len) catch return name;
        return std.fmt.allocPrint(a, "the {s}", .{std.ascii.lowerString(lower, name)}) catch name;
    }
    return std.fmt.allocPrint(a, "as {s}", .{name}) catch name;
}

/// A row's tooltip: "Borrowed before · returned Mar 2024", "Borrowed the audiobook · Mar 2024".
pub fn markText(a: std.mem.Allocator, r: capi.BorrowedResult, labels: []const capi.Pair) []const u8 {
    if (r.match == .same) {
        if (monthYear(a, r.last_returned, true)) |d| return std.fmt.allocPrint(a, "Borrowed before · returned {s}", .{d}) catch "Borrowed before";
        if (monthYear(a, r.last_checkout, true)) |d| return std.fmt.allocPrint(a, "Borrowed before · borrowed {s}", .{d}) catch "Borrowed before";
        return "Borrowed before";
    }
    const p = phrase(a, core.str(r.format) orelse "", labels);
    const date = monthYear(a, r.last_returned, true) orelse monthYear(a, r.last_checkout, true);
    if (date) |d| return std.fmt.allocPrint(a, "Borrowed {s} · {s}", .{ p, d }) catch p;
    return std.fmt.allocPrint(a, "Borrowed {s}", .{p}) catch p;
}

/// Item detail's line: "You borrowed this in March 2024 · 3 times", "You borrowed on DVD in March 2024".
pub fn detailText(a: std.mem.Allocator, r: capi.BorrowedResult, labels: []const capi.Pair) []const u8 {
    const what = if (r.match == .same) "this" else phrase(a, core.str(r.format) orelse "", labels);
    const date = monthYear(a, r.last_checkout, false) orelse monthYear(a, r.last_returned, false);
    var text = if (date) |d|
        std.fmt.allocPrint(a, "You borrowed {s} in {s}", .{ what, d }) catch ""
    else
        std.fmt.allocPrint(a, "You borrowed {s} before", .{what}) catch "";
    if (r.match == .same and r.count > 1) text = std.fmt.allocPrint(a, "{s} · {d} times", .{ text, r.count }) catch text;
    return text;
}

/// "1,200". Allocates just the result, since callers use small fixed buffers (growing lists
/// and allocPrint reserve far more).
pub fn grouped(a: std.mem.Allocator, n: i64) []const u8 {
    var buf: [20]u8 = undefined;
    const digits = std.fmt.bufPrint(&buf, "{d}", .{@abs(n)}) catch unreachable;
    const sign: usize = @intFromBool(n < 0);
    const out = a.alloc(u8, sign + digits.len + (digits.len - 1) / 3) catch return "";
    var o: usize = 0;
    if (n < 0) {
        out[0] = '-';
        o = 1;
    }
    for (digits, 0..) |d, i| {
        if (i > 0 and (digits.len - i) % 3 == 0) {
            out[o] = ',';
            o += 1;
        }
        out[o] = d;
        o += 1;
    }
    return out;
}

test grouped {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqualStrings("1,200", grouped(arena.allocator(), 1200));
    try std.testing.expectEqualStrings("340", grouped(arena.allocator(), 340));
    try std.testing.expectEqualStrings("1,234,567", grouped(arena.allocator(), 1234567));
    try std.testing.expectEqualStrings("-1,200", grouped(arena.allocator(), -1200));
    try std.testing.expectEqualStrings("0", grouped(arena.allocator(), 0));
    // Two in a small fixed buffer, as the account page does.
    var buf: [32]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buf);
    try std.testing.expectEqualStrings("340", grouped(fba.allocator(), 340));
    try std.testing.expectEqualStrings("1,200", grouped(fba.allocator(), 1200));
}
