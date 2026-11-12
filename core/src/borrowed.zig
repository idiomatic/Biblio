//! One login's borrowing history as an index of what the patron borrowed: by catalog record,
//! and by work (formats.workKey) in each format. It does no I/O: the app fetches the history
//! pages it asks for and persists `exportJson` wherever it keeps private data.
//!
//! The first sync fetches every page, resuming where it stopped. Later syncs assume history is
//! newest first and fetch from page 1 until an entry already known. They check that assumption
//! (checkout dates on a page never increase; new entries equal the growth of the total) and,
//! when it fails or history shrank, note it among the incidents and refetch everything.

const std = @import("std");
const Allocator = std.mem.Allocator;
const formats = @import("formats.zig");
const item_list = @import("list.zig");
const http = @import("http.zig");

/// Bumped when stored keys or format rules change, so older caches refetch once.
pub const version = 3;

pub const Match = enum(c_int) { none = 0, same, other_format };

/// One history entry, as stored. Strings are null-terminated.
pub const Entry = struct {
    id: [:0]const u8,
    metadata_id: [:0]const u8,
    /// "" when unknown.
    checkout_date: [:0]const u8,
    returned_date: [:0]const u8,
    /// The effective format (formats.zig) and the library's own code.
    format: [:0]const u8,
    library_format: [:0]const u8,
    work_key: [:0]const u8,
    next_same_record: u32 = none,
    next_same_title: u32 = none,
};

const none = std.math.maxInt(u32);

/// What a page entry contributes.
pub const Source = struct {
    id: []const u8,
    metadata_id: []const u8,
    checkout_date: []const u8 = "",
    returned_date: []const u8 = "",
    format: []const u8,
    library_format: []const u8,
    title: []const u8,
    author: []const u8 = "",
};

pub const Borrowed = struct {
    match: Match = .none,
    /// The borrowed format: the item's own for `same`, the other one for `other_format`.
    format: ?[*:0]const u8 = null,
    count: i64 = 0,
    last_checkout: ?[*:0]const u8 = null,
    last_returned: ?[*:0]const u8 = null,
};

pub const Index = struct {
    gpa: Allocator,
    arena: std.heap.ArenaAllocator,
    entries: std.ArrayList(Entry) = .empty,
    ids: std.StringHashMapUnmanaged(void) = .empty,
    /// Heads of the chains through `next_same_record` and `next_same_title` (by the work key's
    /// title; `formats.sameWork` then compares authors).
    by_record: std.StringHashMapUnmanaged(u32) = .empty,
    by_title: std.StringHashMapUnmanaged(u32) = .empty,

    /// The history's size as the library last reported it.
    total: i64 = 0,
    page_size: i64 = 25,
    complete: bool = false,
    /// The next page of the first (full) fetch.
    next_full: i64 = 1,
    mode: enum { idle, full, incremental } = .idle,
    inc_page: i64 = 0,
    inc_new: i64 = 0,
    inc_prev_total: i64 = 0,
    /// Bumped whenever matches may have changed.
    generation: u64 = 0,

    pub fn init(gpa: Allocator) Index {
        return .{ .gpa = gpa, .arena = .init(gpa) };
    }

    pub fn deinit(ix: *Index) void {
        ix.dropMaps();
        ix.arena.deinit();
    }

    fn dropMaps(ix: *Index) void {
        ix.entries.deinit(ix.gpa);
        ix.ids.deinit(ix.gpa);
        ix.by_record.deinit(ix.gpa);
        ix.by_title.deinit(ix.gpa);
        ix.entries = .empty;
        ix.ids = .empty;
        ix.by_record = .empty;
        ix.by_title = .empty;
    }

    /// Forgets everything (history turned off, or signed out); a sync then starts afresh.
    pub fn clear(ix: *Index) void {
        ix.dropMaps();
        _ = ix.arena.reset(.retain_capacity);
        ix.total = 0;
        ix.page_size = 25;
        ix.complete = false;
        ix.next_full = 1;
        ix.mode = .idle;
        ix.generation +%= 1;
    }

    pub fn isSyncing(ix: *const Index) bool {
        return ix.mode != .idle;
    }

    // MARK: Syncing

    fn pagesFor(ix: *const Index, count: i64) i64 {
        return @max(1, @divFloor(count + ix.page_size - 1, ix.page_size));
    }

    /// Starts a sync: the page to fetch, or 0 if one is already running.
    pub fn beginSync(ix: *Index) i64 {
        if (ix.mode != .idle) return 0;
        if (!ix.complete) {
            ix.mode = .full;
            return ix.next_full;
        }
        ix.mode = .incremental;
        ix.inc_page = 1;
        ix.inc_new = 0;
        ix.inc_prev_total = ix.total;
        return 1;
    }

    /// Forgets the index and fetches it all again: page 1, or 0 when a running sync carries on
    /// from page 1 instead.
    pub fn rebuild(ix: *Index) i64 {
        const running = ix.mode != .idle;
        ix.clear();
        ix.mode = .full;
        return if (running) 0 else 1;
    }

    /// A fetch failed: the sync stops, and the next one resumes.
    pub fn fail(ix: *Index) void {
        ix.mode = .idle;
    }

    /// A fetched history page. Returns the next page to fetch, or 0 when the sync is done.
    pub fn apply(ix: *Index, page: i64, items: []const Source, count: i64, page_size: i64) Allocator.Error!i64 {
        switch (ix.mode) {
            .idle => return 0,
            .full => {
                // A page from before a rebuild: fetch the one wanted now.
                if (page != ix.next_full) return ix.next_full;
                ix.page_size = @max(1, page_size);
                for (items) |s| _ = try ix.add(s);
                ix.total = count;
                ix.next_full = page + 1;
                if (items.len == 0 or ix.next_full > ix.pagesFor(count)) {
                    ix.complete = true;
                    ix.mode = .idle;
                    return 0;
                }
                return ix.next_full;
            },
            .incremental => {
                if (page != ix.inc_page) return ix.inc_page;
                ix.page_size = @max(1, page_size);
                var latest: i64 = std.math.maxInt(i64);
                for (items) |s| {
                    const day = item_list.dayNumber(s.checkout_date);
                    if (day == 0) continue;
                    if (day > latest) return ix.restart("/borrowinghistory (order)");
                    latest = day;
                }
                var known = false;
                for (items) |s| {
                    if (ix.ids.contains(s.id)) {
                        known = true;
                        break;
                    }
                    if (try ix.add(s)) ix.inc_new += 1;
                }
                const at_end = items.len == 0 or page >= ix.pagesFor(count);
                if (known or at_end) {
                    if (count - ix.inc_prev_total != ix.inc_new) return ix.restart("/borrowinghistory (count)");
                    ix.total = count;
                    ix.mode = .idle;
                    return 0;
                }
                ix.inc_page = page + 1;
                return ix.inc_page;
            },
        }
    }

    fn restart(ix: *Index, why: []const u8) i64 {
        http.incidents.note("SYNC", why);
        ix.clear();
        ix.mode = .full;
        return 1;
    }

    /// Adds an entry unless its id is known; true if added.
    fn add(ix: *Index, s: Source) Allocator.Error!bool {
        if (ix.ids.contains(s.id)) return false;
        const a = ix.arena.allocator();
        const key = try formats.workKey(ix.gpa, s.title, s.author);
        defer ix.gpa.free(key);
        try ix.insert(.{
            .id = try a.dupeSentinel(u8, s.id, 0),
            .metadata_id = try a.dupeSentinel(u8, s.metadata_id, 0),
            .checkout_date = try a.dupeSentinel(u8, s.checkout_date, 0),
            .returned_date = try a.dupeSentinel(u8, s.returned_date, 0),
            .format = try a.dupeSentinel(u8, s.format, 0),
            .library_format = try a.dupeSentinel(u8, s.library_format, 0),
            .work_key = try a.dupeSentinel(u8, key, 0),
        });
        return true;
    }

    fn insert(ix: *Index, entry: Entry) Allocator.Error!void {
        var e = entry;
        const i: u32 = @intCast(ix.entries.items.len);
        try ix.ids.put(ix.gpa, e.id, {});
        const rec = try ix.by_record.getOrPut(ix.gpa, e.metadata_id);
        e.next_same_record = if (rec.found_existing) rec.value_ptr.* else none;
        rec.value_ptr.* = i;
        if (e.work_key.len > 0) {
            const title = try ix.by_title.getOrPut(ix.gpa, formats.titleOf(e.work_key));
            e.next_same_title = if (title.found_existing) title.value_ptr.* else none;
            title.value_ptr.* = i;
        }
        try ix.entries.append(ix.gpa, e);
        ix.generation +%= 1;
    }

    // MARK: Matching

    /// Whether the patron borrowed this item, or the same work in another format. Strings stay
    /// valid until the index is cleared, rebuilt, or imported.
    pub fn lookup(ix: *const Index, metadata_id: []const u8, format: []const u8, title: []const u8, author: []const u8) Borrowed {
        const key = formats.workKey(ix.gpa, title, author) catch return .{};
        defer ix.gpa.free(key);
        var same: Tally = .{};
        var other: Tally = .{};
        var i = ix.by_record.get(metadata_id) orelse none;
        while (i != none) : (i = ix.entries.items[i].next_same_record) same.add(&ix.entries.items[i]);
        if (key.len > 0) {
            i = ix.by_title.get(formats.titleOf(key)) orelse none;
            while (i != none) : (i = ix.entries.items[i].next_same_title) {
                const e = &ix.entries.items[i];
                if (std.mem.eql(u8, e.metadata_id, metadata_id) or !formats.sameWork(key, format, e.work_key, e.format)) continue;
                if (std.mem.eql(u8, e.format, format)) same.add(e) else other.add(e);
            }
        }
        if (same.latest) |e| return .{ .match = .same, .format = e.format.ptr, .count = same.count, .last_checkout = opt(e.checkout_date), .last_returned = opt(e.returned_date) };
        const e = other.latest orelse return .{};
        // Count the borrowings of the format named.
        var n: i64 = 0;
        i = ix.by_title.get(formats.titleOf(key)) orelse none;
        while (i != none) : (i = ix.entries.items[i].next_same_title) {
            const x = &ix.entries.items[i];
            if (formats.sameWork(key, format, x.work_key, x.format) and std.mem.eql(u8, x.format, e.format)) n += 1;
        }
        return .{ .match = .other_format, .format = e.format.ptr, .count = n, .last_checkout = opt(e.checkout_date), .last_returned = opt(e.returned_date) };
    }

    /// Whether the work was borrowed in this format (the "Not Borrowed" filter's test).
    pub fn hasWorkInFormat(ix: *const Index, work_key: []const u8, format: []const u8) bool {
        if (work_key.len == 0) return false;
        var i = ix.by_title.get(formats.titleOf(work_key)) orelse none;
        while (i != none) : (i = ix.entries.items[i].next_same_title) {
            const e = &ix.entries.items[i];
            if (std.mem.eql(u8, e.format, format) and formats.sameWork(work_key, format, e.work_key, e.format)) return true;
        }
        return false;
    }

    const Tally = struct {
        count: i64 = 0,
        latest: ?*const Entry = null,

        fn add(t: *Tally, e: *const Entry) void {
            t.count += 1;
            const l = t.latest orelse {
                t.latest = e;
                return;
            };
            if (std.mem.order(u8, e.checkout_date, l.checkout_date) == .gt) t.latest = e;
        }
    };

    fn opt(s: [:0]const u8) ?[*:0]const u8 {
        return if (s.len == 0) null else s.ptr;
    }

    // MARK: Storage

    /// The index as JSON, for the app to keep (it is private: store it protected).
    pub fn exportJson(ix: *const Index, a: Allocator) ![]u8 {
        var w: std.Io.Writer.Allocating = .init(a);
        var s: std.json.Stringify = .{ .writer = &w.writer };
        try s.beginObject();
        try s.objectField("v");
        try s.write(version);
        try s.objectField("total");
        try s.write(ix.total);
        try s.objectField("pageSize");
        try s.write(ix.page_size);
        try s.objectField("complete");
        try s.write(ix.complete);
        try s.objectField("nextPage");
        try s.write(ix.next_full);
        try s.objectField("entries");
        try s.beginArray();
        for (ix.entries.items) |e| {
            try s.write([_][]const u8{ e.id, e.metadata_id, e.checkout_date, e.returned_date, e.format, e.library_format, e.work_key });
        }
        try s.endArray();
        try s.endObject();
        return w.toOwnedSlice();
    }

    /// Replaces the index with an exported one; false (leaving it empty) if it is unreadable or
    /// from another version.
    pub fn importJson(ix: *Index, text: []const u8) Allocator.Error!bool {
        ix.clear();
        var scratch = std.heap.ArenaAllocator.init(ix.gpa);
        defer scratch.deinit();
        const Stored = struct {
            v: i64,
            total: i64 = 0,
            pageSize: i64 = 25,
            complete: bool = false,
            nextPage: i64 = 1,
            entries: []const [7][]const u8 = &.{},
        };
        const stored = std.json.parseFromSliceLeaky(Stored, scratch.allocator(), text, .{ .ignore_unknown_fields = true }) catch return false;
        if (stored.v != version) return false;
        const a = ix.arena.allocator();
        for (stored.entries) |f| {
            if (ix.ids.contains(f[0])) continue;
            try ix.insert(.{
                .id = try a.dupeSentinel(u8, f[0], 0),
                .metadata_id = try a.dupeSentinel(u8, f[1], 0),
                .checkout_date = try a.dupeSentinel(u8, f[2], 0),
                .returned_date = try a.dupeSentinel(u8, f[3], 0),
                .format = try a.dupeSentinel(u8, f[4], 0),
                .library_format = try a.dupeSentinel(u8, f[5], 0),
                .work_key = try a.dupeSentinel(u8, f[6], 0),
            });
        }
        ix.total = stored.total;
        ix.page_size = @max(1, stored.pageSize);
        ix.complete = stored.complete;
        ix.next_full = @max(1, stored.nextPage);
        return true;
    }
};

// MARK: Tests

const testing = std.testing;

fn src(id: []const u8, meta: []const u8, out: []const u8, format: []const u8, title: []const u8) Source {
    return .{ .id = id, .metadata_id = meta, .checkout_date = out, .format = format, .library_format = format, .title = title };
}

test "full fetch resumes, then incremental syncs stop at a known entry" {
    var ix = Index.init(testing.allocator);
    defer ix.deinit();
    try testing.expectEqual(@as(i64, 1), ix.beginSync());
    try testing.expectEqual(@as(i64, 0), ix.beginSync());
    const p1 = [_]Source{ src("B3", "S3", "2026-03-01", "DVD", "Moana"), src("B2", "S2", "2026-02-01", "BK", "Dune") };
    try testing.expectEqual(@as(i64, 2), try ix.apply(1, &p1, 3, 2));
    ix.fail();
    try testing.expect(!ix.complete);
    // Resumes at page 2.
    try testing.expectEqual(@as(i64, 2), ix.beginSync());
    const p2 = [_]Source{src("B1", "S1", "2026-01-01", "BK", "Emma")};
    try testing.expectEqual(@as(i64, 0), try ix.apply(2, &p2, 3, 2));
    try testing.expect(ix.complete);
    try testing.expectEqual(@as(usize, 3), ix.entries.items.len);

    // One new return: a single page, stopping at B3.
    try testing.expectEqual(@as(i64, 1), ix.beginSync());
    const n1 = [_]Source{ src("B4", "S4", "2026-04-01", "BK", "Binti"), src("B3", "S3", "2026-03-01", "DVD", "Moana") };
    try testing.expectEqual(@as(i64, 0), try ix.apply(1, &n1, 4, 2));
    try testing.expectEqual(@as(usize, 4), ix.entries.items.len);
    try testing.expectEqual(@as(i64, 4), ix.total);
}

test "a sync that doesn't add up refetches everything" {
    var ix = Index.init(testing.allocator);
    defer ix.deinit();
    _ = ix.beginSync();
    const p1 = [_]Source{ src("B2", "S2", "2026-02-01", "BK", "Dune"), src("B1", "S1", "2026-01-01", "BK", "Emma") };
    _ = try ix.apply(1, &p1, 2, 25);
    try testing.expect(ix.complete);
    const before = http.incidents.total;
    // History deleted on the website: the total shrank.
    try testing.expectEqual(@as(i64, 1), ix.beginSync());
    const shrunk = [_]Source{src("B2", "S2", "2026-02-01", "BK", "Dune")};
    try testing.expectEqual(@as(i64, 1), try ix.apply(1, &shrunk, 1, 25));
    try testing.expectEqual(before + 1, http.incidents.total);
    try testing.expect(!ix.complete and ix.mode == .full);
    try testing.expectEqual(@as(i64, 0), try ix.apply(1, &shrunk, 1, 25));
    try testing.expect(ix.complete);
    try testing.expectEqual(@as(usize, 1), ix.entries.items.len);
    // Oldest first: refetch.
    _ = ix.beginSync();
    const backwards = [_]Source{ src("B9", "S9", "2025-01-01", "BK", "X"), src("B8", "S8", "2026-05-01", "BK", "Y") };
    try testing.expectEqual(@as(i64, 1), try ix.apply(1, &backwards, 3, 25));
    try testing.expectEqual(before + 2, http.incidents.total);
}

test "a rebuild during a sync carries on from page 1" {
    var ix = Index.init(testing.allocator);
    defer ix.deinit();
    _ = ix.beginSync();
    const p1 = [_]Source{src("B1", "S1", "2026-01-01", "BK", "Emma")};
    try testing.expectEqual(@as(i64, 2), try ix.apply(1, &p1, 30, 1));
    try testing.expectEqual(@as(i64, 0), ix.rebuild());
    try testing.expectEqual(@as(usize, 0), ix.entries.items.len);
    // The running loop's page 2 is set aside for page 1.
    try testing.expectEqual(@as(i64, 1), try ix.apply(2, &p1, 30, 1));
}

test "matches by record, by work in a format, and by work in another format" {
    var ix = Index.init(testing.allocator);
    defer ix.deinit();
    _ = ix.beginSync();
    const page = [_]Source{
        src("B3", "S10", "2026-03-01", "DVD", "Moana"),
        src("B2", "S10", "2025-03-01", "DVD", "Moana"),
        src("B1", "S20", "2024-01-01", "BOOK_CD", "Rogue Protocol"),
    };
    _ = try ix.apply(1, &page, 3, 25);
    const exact = ix.lookup("S10", "DVD", "Moana", "");
    try testing.expectEqual(Match.same, exact.match);
    try testing.expectEqual(@as(i64, 2), exact.count);
    try testing.expectEqualStrings("2026-03-01", std.mem.span(exact.last_checkout.?));
    try testing.expectEqual(Match.same, ix.lookup("S11", "DVD", "Moana", "").match);
    const other = ix.lookup("S12", "UK", "Moana [videorecording]", "");
    try testing.expectEqual(Match.other_format, other.match);
    try testing.expectEqualStrings("DVD", std.mem.span(other.format.?));
    try testing.expectEqual(Match.other_format, ix.lookup("S21", "BK", "Rogue Protocol", "").match);
    try testing.expectEqual(Match.none, ix.lookup("S30", "BK", "Emma", "").match);
    const key = try formats.workKey(testing.allocator, "Moana", "");
    defer testing.allocator.free(key);
    try testing.expect(ix.hasWorkInFormat(key, "DVD"));
    try testing.expect(!ix.hasWorkInFormat(key, "UK"));
}

test "matches a record that writes the author differently, or names none" {
    var ix = Index.init(testing.allocator);
    defer ix.deinit();
    _ = ix.beginSync();
    var page = [_]Source{
        src("B2", "S1", "2026-02-01", "BK", "Dune"),
        src("B1", "S5", "2025-01-01", "DVD", "Arrival"),
    };
    page[0].author = "Herbert, Frank, 1920-1986";
    page[1].author = "Villeneuve, Denis";
    _ = try ix.apply(1, &page, 2, 25);
    try testing.expectEqual(Match.same, ix.lookup("S2", "BK", "Dune", "Frank Herbert").match);
    try testing.expectEqual(Match.same, ix.lookup("S6", "DVD", "Arrival", "").match);
    try testing.expectEqual(Match.none, ix.lookup("S3", "BK", "Dune", "Someone, Else").match);
    // The film (no author) is no match for a book called Arrival.
    try testing.expectEqual(Match.none, ix.lookup("S7", "BK", "Arrival", "Chiang, Ted").match);
}

test "export and import round-trip, refusing other versions" {
    var ix = Index.init(testing.allocator);
    defer ix.deinit();
    _ = ix.beginSync();
    const page = [_]Source{src("B1", "S1", "2026-01-01", "UK", "Dune")};
    _ = try ix.apply(1, &page, 1, 25);
    const text = try ix.exportJson(testing.allocator);
    defer testing.allocator.free(text);
    var copy = Index.init(testing.allocator);
    defer copy.deinit();
    try testing.expect(try copy.importJson(text));
    try testing.expect(copy.complete);
    try testing.expectEqual(Match.same, copy.lookup("S1", "UK", "Dune", "").match);
    try testing.expect(!try copy.importJson("{\"v\":0}"));
    try testing.expect(!try copy.importJson("nonsense"));
    try testing.expectEqual(@as(usize, 0), copy.entries.items.len);
}
