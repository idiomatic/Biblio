//! A paged item list's state, shared by every app: which server positions hold fetched items,
//! which pages to fetch next, and the rows to show after sorting and filtering.
//!
//! It does no I/O. The app asks it which page to fetch (`request`, `itemAppeared`,
//! `takeVisibleRequests`, `nextBackgroundPage`), fetches that page itself, and hands back the
//! result with `apply`, or `fail`. Every call comes from one thread.
//!
//! Once the first page reports the total count, every unfetched item is a placeholder row, so
//! the scroll bar has its final length from the start. Server sorts reload from page 1; client
//! sorts ("people waiting", title) and local filters need every page, so the app fetches the
//! rest in the background, capped at `background_page_limit` pages.

const std = @import("std");
const Allocator = std.mem.Allocator;
const models = @import("models.zig");

pub const Kind = enum(c_int) { search = 0, holds, checkouts, history };
pub const Sort = enum(c_int) { server = 0, people_waiting, title };
pub const HoldFilter = enum(c_int) { none = 0, ready, not_ready, on_order };

/// Caps background fetching for client sorts and local filters, to stay gentle with the
/// library's servers; long lists (e.g. years of borrowing history) sort their first 1,000.
pub const background_page_limit = 40;
/// How long a fetched list is trusted; showing it again after that refetches it.
pub const max_age_ms: i64 = 15 * 60 * 1000;

/// What the list needs to know about an entry to sort and filter it. The list keeps its own
/// copies of the strings, null-terminated.
pub const Item = struct {
    id: []const u8,
    title: []const u8,
    format: []const u8,
    held_copies: i64 = 0,
    server_index: i64 = 0,
    is_hold: bool = false,
    /// A hold ready for pickup.
    ready: bool = false,
    /// Waiting on copies the library hasn't received yet.
    on_order: bool = false,

    pub fn from(e: models.ListEntry) Item {
        return .{
            .id = e.id,
            .title = e.bib.title,
            .format = e.bib.format,
            .held_copies = e.bib.heldCopies,
            .server_index = e.serverIndex,
            .is_hold = e.hold != null,
            .ready = if (e.hold) |h| h.isReady() else false,
            .on_order = e.bib.onOrderCopies > 0 or
                (if (e.bib.status) |s| std.mem.eql(u8, s, "ON_ORDER") else false),
        };
    }

    fn matches(it: Item, filter: HoldFilter) bool {
        if (!it.is_hold) return false;
        return switch (filter) {
            .none => true,
            .ready => it.ready,
            .not_ready => !it.ready,
            .on_order => !it.ready and it.on_order,
        };
    }
};

/// A displayed row: a fetched item, or a stand-in for the item at a server position.
pub const Row = extern struct {
    position: i64,
    /// The item's id; null for a placeholder.
    id: ?[*:0]const u8,
};

pub const FormatCount = extern struct { format: [*:0]const u8, count: i64 };

/// A string the list copied, which is null-terminated.
fn z(s: []const u8) [*:0]const u8 {
    return @ptrCast(s.ptr);
}

pub const List = struct {
    gpa: Allocator,
    /// The items' strings, freed together when the content is replaced.
    arena: std.heap.ArenaAllocator,
    kind: Kind,
    sort: Sort = .server,
    format: ?[:0]u8 = null,
    hold_filter: HoldFilter = .none,

    /// Items by server position; null where the page hasn't been fetched yet.
    slots: std.ArrayList(?Item) = .empty,
    positions: std.StringHashMapUnmanaged(usize) = .empty,
    loaded_pages: std.AutoHashMapUnmanaged(i64, void) = .empty,
    in_flight: std.AutoHashMapUnmanaged(i64, void) = .empty,
    /// Page → how many of its placeholders are on screen.
    visible: std.AutoHashMapUnmanaged(i64, usize) = .empty,

    rows: std.ArrayList(Row) = .empty,
    /// Item ids in server order.
    ids: std.ArrayList([*:0]const u8) = .empty,
    /// The items' formats with counts, most common first.
    formats: std.ArrayList(FormatCount) = .empty,

    page_size: i64 = 25,
    total: i64 = 0,
    loaded: bool = false,
    loaded_at: ?i64 = null,
    /// Refetching while the stale rows stay in place, until the first page replaces them.
    refreshing: bool = false,
    background: bool = false,
    generation: u64 = 0,

    pub fn init(gpa: Allocator, kind: Kind) List {
        return .{ .gpa = gpa, .arena = .init(gpa), .kind = kind };
    }

    pub fn deinit(l: *List) void {
        if (l.format) |f| l.gpa.free(f);
        l.slots.deinit(l.gpa);
        l.positions.deinit(l.gpa);
        l.loaded_pages.deinit(l.gpa);
        l.in_flight.deinit(l.gpa);
        l.visible.deinit(l.gpa);
        l.rows.deinit(l.gpa);
        l.ids.deinit(l.gpa);
        l.formats.deinit(l.gpa);
        l.arena.deinit();
    }

    pub fn pages(l: *const List) i64 {
        return @max(1, @divFloor(l.total + l.page_size - 1, l.page_size));
    }

    pub fn hasMore(l: *const List) bool {
        return !l.loaded or l.loaded_pages.count() < l.pages();
    }

    pub fn isLoading(l: *const List) bool {
        return l.in_flight.count() > 0;
    }

    pub fn isStale(l: *const List, now_ms: i64) bool {
        const at = l.loaded_at orelse return false;
        return now_ms - at > max_age_ms;
    }

    fn pageOf(l: *const List, position: i64) i64 {
        return @divFloor(position, l.page_size) + 1;
    }

    // MARK: Loading

    /// Starts again from page 1, which it requests; the app fetches it. Keeping content leaves
    /// the current rows, stale, until page 1 replaces them all at once.
    pub fn reload(l: *List, keep_content: bool) Allocator.Error!void {
        l.restart();
        l.refreshing = keep_content and l.loaded;
        if (!l.refreshing) try l.clearContent();
        _ = try l.request(1);
    }

    /// Marks the rows stale before a reload that keeps them (e.g. while signing in afresh),
    /// which also holds back requests for later pages.
    pub fn beginRefresh(l: *List) void {
        l.refreshing = l.loaded;
    }

    /// Empties the list without fetching (an empty search).
    pub fn clear(l: *List) Allocator.Error!void {
        l.restart();
        l.refreshing = false;
        try l.clearContent();
    }

    fn restart(l: *List) void {
        l.generation +%= 1;
        l.background = false;
        l.loaded_pages.clearRetainingCapacity();
        l.in_flight.clearRetainingCapacity();
        l.visible.clearRetainingCapacity();
    }

    fn clearContent(l: *List) Allocator.Error!void {
        l.dropItems();
        l.total = 0;
        l.loaded = false;
        l.loaded_at = null;
        try l.rebuild();
    }

    fn dropItems(l: *List) void {
        l.slots.clearRetainingCapacity();
        l.positions.clearRetainingCapacity();
        l.rows.clearRetainingCapacity();
        l.ids.clearRetainingCapacity();
        l.formats.clearRetainingCapacity();
        _ = l.arena.reset(.retain_capacity);
    }

    /// Marks `page` in flight if it should be fetched: not fetched or in flight already, and
    /// within the list (only page 1 until the stale rows of a refresh are replaced).
    pub fn request(l: *List, page: i64) Allocator.Error!bool {
        if (page < 1 or l.loaded_pages.contains(page) or l.in_flight.contains(page)) return false;
        if (page != 1 and (page > l.pages() or l.refreshing)) return false;
        try l.in_flight.put(l.gpa, page, {});
        return true;
    }

    /// A fetched page. False if the list was reloaded since it was requested.
    pub fn apply(l: *List, generation: u64, page: i64, items: []const Item, count: i64, page_size: i64, now_ms: i64) Allocator.Error!bool {
        if (generation != l.generation) return false;
        _ = l.in_flight.remove(page);
        if (page == 1) {
            if (l.refreshing) {
                l.dropItems();
                l.refreshing = false;
            }
            l.page_size = @max(page_size, 1);
            l.loaded_at = now_ms;
        }
        l.total = count;
        // Size the list to the reported total (it may change between pages if the data does).
        const size: usize = @intCast(@max(count, (page - 1) * l.page_size + @as(i64, @intCast(items.len)), 0));
        if (l.slots.items.len < size) {
            try l.slots.appendNTimes(l.gpa, null, size - l.slots.items.len);
        } else if (l.slots.items.len > size) {
            for (l.slots.items[size..]) |slot| if (slot) |it| {
                _ = l.positions.remove(it.id);
            };
            l.slots.shrinkRetainingCapacity(size);
        }
        const start: usize = @intCast((page - 1) * l.page_size);
        const a = l.arena.allocator();
        for (items, 0..) |src, offset| {
            const i = start + offset;
            if (i >= l.slots.items.len) break;
            // An item that moved between pages while fetching is kept at its first position.
            if (l.positions.contains(src.id)) continue;
            var it = src;
            it.id = try a.dupeSentinel(u8, src.id, 0);
            it.title = try a.dupe(u8, src.title);
            it.format = try a.dupeSentinel(u8, src.format, 0);
            l.slots.items[i] = it;
            try l.positions.put(l.gpa, it.id, i);
        }
        try l.loaded_pages.put(l.gpa, page, {});
        l.loaded = true;
        try l.rebuild();
        return true;
    }

    /// A page that couldn't be fetched. False if the list was reloaded since it was requested.
    pub fn fail(l: *List, generation: u64, page: i64) Allocator.Error!bool {
        if (generation != l.generation) return false;
        _ = l.in_flight.remove(page);
        if (l.refreshing) {
            // Nothing left to retry from: the stale rows go, and the app shows the error.
            l.refreshing = false;
            try l.clearContent();
        }
        return true;
    }

    // MARK: Scrolling

    /// An item scrolled into view: the page to prefetch when nearing its placeholders, or 0.
    pub fn itemAppeared(l: *List, position: i64) Allocator.Error!i64 {
        if (l.sort != .server) return 0;
        const ahead = l.pageOf(position + @divFloor(l.page_size, 2));
        return if (try l.request(ahead)) ahead else 0;
    }

    /// The app fetches visible placeholders' pages once they have stayed on screen briefly.
    pub fn placeholderAppeared(l: *List, position: i64) Allocator.Error!void {
        const gop = try l.visible.getOrPut(l.gpa, l.pageOf(position));
        gop.value_ptr.* = if (gop.found_existing) gop.value_ptr.* + 1 else 1;
    }

    pub fn placeholderDisappeared(l: *List, position: i64) void {
        const p = l.pageOf(position);
        const n = l.visible.getPtr(p) orelse return;
        if (n.* > 1) n.* -= 1 else _ = l.visible.remove(p);
    }

    /// Requests the pages of the visible placeholders, in order, into `out`; returns how many.
    pub fn takeVisibleRequests(l: *List, out: []i64) Allocator.Error!usize {
        var pending: std.ArrayList(i64) = .empty;
        defer pending.deinit(l.gpa);
        var it = l.visible.keyIterator();
        while (it.next()) |p| try pending.append(l.gpa, p.*);
        std.mem.sort(i64, pending.items, {}, std.sort.asc(i64));
        var n: usize = 0;
        for (pending.items) |p| {
            if (n == out.len) break;
            if (try l.request(p)) {
                out[n] = p;
                n += 1;
            }
        }
        return n;
    }

    // MARK: Background fetching

    fn hasLocalFilter(l: *const List) bool {
        return l.kind != .search and (l.format != null or l.hold_filter != .none);
    }

    /// Client sorts and local filters are only correct once every page is loaded.
    pub fn needsAllPages(l: *const List) bool {
        return l.sort != .server or l.hasLocalFilter();
    }

    /// After page 1: whether to fetch the rest. Holds lists are short and their filter counts
    /// need every hold, so they load them all.
    pub fn wantsAllPages(l: *const List) bool {
        return l.needsAllPages() or l.kind == .holds;
    }

    /// Starts background fetching, unless it is running or there is nothing to fetch.
    pub fn beginBackground(l: *List) bool {
        if (l.background or !l.loaded or !l.hasMore() or l.refreshing) return false;
        l.background = true;
        return true;
    }

    /// The next page for background fetching to fetch (now in flight), or 0 when it is done.
    pub fn nextBackgroundPage(l: *List) Allocator.Error!i64 {
        if (!l.background) return 0;
        const last = @min(l.pages(), background_page_limit);
        var p: i64 = 1;
        while (p <= last) : (p += 1) {
            if (try l.request(p)) return p;
        }
        l.background = false;
        return 0;
    }

    /// Stops background fetching (after an error).
    pub fn endBackground(l: *List) void {
        l.background = false;
    }

    // MARK: Sorting and filtering

    pub fn setSort(l: *List, sort: Sort) Allocator.Error!void {
        l.sort = sort;
        try l.rebuild();
    }

    /// The format filter for account lists, applied locally (searches filter on the server).
    pub fn setFormat(l: *List, format: ?[]const u8) Allocator.Error!void {
        const new = if (format) |f| try l.gpa.dupeSentinel(u8, f, 0) else null;
        if (l.format) |f| l.gpa.free(f);
        l.format = new;
        try l.rebuild();
    }

    pub fn setHoldFilter(l: *List, filter: HoldFilter) Allocator.Error!void {
        l.hold_filter = filter;
        try l.rebuild();
    }

    /// Removes the items with these ids (after cancelling holds); returns how many.
    pub fn remove(l: *List, ids: []const []const u8) Allocator.Error!usize {
        var kept: usize = 0;
        for (l.slots.items) |slot| {
            if (slot) |it| if (contains(ids, it.id)) continue;
            l.slots.items[kept] = slot;
            kept += 1;
        }
        const removed = l.slots.items.len - kept;
        l.slots.shrinkRetainingCapacity(kept);
        l.total = @max(0, l.total - @as(i64, @intCast(removed)));
        l.positions.clearRetainingCapacity();
        for (l.slots.items, 0..) |slot, i| if (slot) |it| try l.positions.put(l.gpa, it.id, i);
        try l.rebuild();
        return removed;
    }

    fn contains(ids: []const []const u8, id: []const u8) bool {
        for (ids) |x| if (std.mem.eql(u8, x, id)) return true;
        return false;
    }

    /// How many loaded holds fall under a hold filter (and the format filter).
    pub fn holdCount(l: *const List, filter: HoldFilter) i64 {
        var n: i64 = 0;
        for (l.slots.items) |slot| if (slot) |it| {
            if (it.matches(filter) and l.passesFormat(it)) n += 1;
        };
        return n;
    }

    fn passesFormat(l: *const List, it: Item) bool {
        const f = l.format orelse return true;
        return std.mem.eql(u8, f, it.format);
    }

    fn passesLocalFilters(l: *const List, it: Item) bool {
        return l.passesFormat(it) and (l.hold_filter == .none or it.matches(l.hold_filter));
    }

    /// Rebuilds the rows, ids and format counts after loading, filtering or sorting. The stale
    /// rows of a refresh stay until its first page arrives.
    fn rebuild(l: *List) Allocator.Error!void {
        if (l.refreshing) return;
        l.ids.clearRetainingCapacity();
        for (l.slots.items) |slot| if (slot) |it| try l.ids.append(l.gpa, z(it.id));
        try l.countFormats();

        l.rows.clearRetainingCapacity();
        var items: std.ArrayList(usize) = .empty;
        defer items.deinit(l.gpa);
        for (l.slots.items, 0..) |slot, i| if (slot) |it| {
            if (!l.hasLocalFilter() or l.passesLocalFilters(it)) try items.append(l.gpa, i);
        };
        if (l.sort == .server and !l.hasLocalFilter()) {
            for (l.slots.items, 0..) |slot, i| {
                const pos: i64 = @intCast(i);
                if (slot) |it| {
                    try l.rows.append(l.gpa, .{ .position = pos, .id = z(it.id) });
                } else if (!l.loaded_pages.contains(l.pageOf(pos))) {
                    try l.rows.append(l.gpa, .{ .position = pos, .id = null });
                }
                // A short page from the server leaves gaps that are simply skipped.
            }
            return;
        }
        std.mem.sort(usize, items.items, l, lessThan);
        for (items.items) |i| try l.rows.append(l.gpa, .{ .position = @intCast(i), .id = z(l.slots.items[i].?.id) });
        // A local filter can't know which unfetched items match, so it shows no placeholders;
        // a client sort keeps the unfetched remainder for the scroll bar's length.
        if (l.hasLocalFilter()) return;
        for (l.slots.items, 0..) |slot, i| {
            const pos: i64 = @intCast(i);
            if (slot == null and !l.loaded_pages.contains(l.pageOf(pos))) try l.rows.append(l.gpa, .{ .position = pos, .id = null });
        }
    }

    fn lessThan(l: *const List, a: usize, b: usize) bool {
        const x = l.slots.items[a].?;
        const y = l.slots.items[b].?;
        return switch (l.sort) {
            .people_waiting => if (x.held_copies != y.held_copies) x.held_copies > y.held_copies else x.server_index < y.server_index,
            .title => naturalOrder(x.title, y.title) == .lt,
            .server => a < b,
        };
    }

    fn countFormats(l: *List) Allocator.Error!void {
        l.formats.clearRetainingCapacity();
        for (l.slots.items) |slot| if (slot) |it| {
            for (l.formats.items) |*f| {
                if (std.mem.eql(u8, std.mem.span(f.format), it.format)) {
                    f.count += 1;
                    break;
                }
            } else try l.formats.append(l.gpa, .{ .format = z(it.format), .count = 1 });
        };
        std.mem.sort(FormatCount, l.formats.items, {}, struct {
            fn f(_: void, a: FormatCount, b: FormatCount) bool {
                if (a.count != b.count) return a.count > b.count;
                return std.mem.orderZ(u8, a.format, b.format) == .lt;
            }
        }.f);
    }
};

/// Orders titles as people expect: ignoring case, with runs of digits compared as numbers
/// ("Book 2" before "Book 10"). Non-ASCII bytes compare by value.
pub fn naturalOrder(a: []const u8, b: []const u8) std.math.Order {
    var i: usize = 0;
    var j: usize = 0;
    while (i < a.len and j < b.len) {
        if (std.ascii.isDigit(a[i]) and std.ascii.isDigit(b[j])) {
            const si = i;
            const sj = j;
            while (i < a.len and std.ascii.isDigit(a[i])) i += 1;
            while (j < b.len and std.ascii.isDigit(b[j])) j += 1;
            const x = std.mem.trimStart(u8, a[si..i], "0");
            const y = std.mem.trimStart(u8, b[sj..j], "0");
            if (x.len != y.len) return std.math.order(x.len, y.len);
            const o = std.mem.order(u8, x, y);
            if (o != .eq) return o;
            continue;
        }
        const o = std.math.order(std.ascii.toLower(a[i]), std.ascii.toLower(b[j]));
        if (o != .eq) return o;
        i += 1;
        j += 1;
    }
    return std.math.order(a.len - i, b.len - j);
}

// MARK: Tests

const testing = std.testing;

fn item(id: []const u8, held: i64) Item {
    return .{ .id = id, .title = id, .format = "BK", .held_copies = held };
}

/// Items "<prefix>0", "<prefix>1", …; the ids live in `buf`.
fn pageOfItems(buf: *[32][8]u8, prefix: []const u8, n: usize) []Item {
    const S = struct {
        var items: [32]Item = undefined;
    };
    for (0..n) |i| S.items[i] = item(std.fmt.bufPrint(&buf[i], "{s}{d}", .{ prefix, i }) catch unreachable, 0);
    return S.items[0..n];
}

fn placeholders(l: *const List) usize {
    var n: usize = 0;
    for (l.rows.items) |r| if (r.id == null) {
        n += 1;
    };
    return n;
}

test "placeholders fill the list to its total" {
    var l: List = .init(testing.allocator, .search);
    defer l.deinit();
    try l.reload(false);
    try testing.expect(l.isLoading());
    var buf: [32][8]u8 = undefined;
    const p1 = pageOfItems(&buf, "a", 25);
    try testing.expect(try l.apply(l.generation, 1, p1, 60, 25, 0));
    try testing.expectEqual(@as(usize, 60), l.rows.items.len);
    try testing.expectEqual(@as(usize, 35), placeholders(&l));
    try testing.expectEqual(@as(i64, 3), l.pages());
    try testing.expect(l.hasMore());
    // Placeholders on page 3 stay visible, so it is fetched, not page 2.
    try l.placeholderAppeared(55);
    try l.placeholderAppeared(56);
    l.placeholderDisappeared(56);
    var out: [4]i64 = undefined;
    try testing.expectEqual(@as(usize, 1), try l.takeVisibleRequests(&out));
    try testing.expectEqual(@as(i64, 3), out[0]);
    // Nearing the end of page 1 prefetches page 2.
    try testing.expectEqual(@as(i64, 0), try l.itemAppeared(5));
    try testing.expectEqual(@as(i64, 2), try l.itemAppeared(20));
    try testing.expectEqual(@as(i64, 0), try l.itemAppeared(20));
}

test "a reload discards pages from before it" {
    var l: List = .init(testing.allocator, .holds);
    defer l.deinit();
    try l.reload(false);
    const old = l.generation;
    try l.reload(false);
    var buf: [32][8]u8 = undefined;
    const p1 = pageOfItems(&buf, "a", 3);
    try testing.expect(!try l.apply(old, 1, p1, 3, 25, 0));
    try testing.expect(!l.loaded);
    try testing.expect(try l.apply(l.generation, 1, p1, 3, 25, 0));
    try testing.expect(l.loaded);
}

test "a refresh keeps stale rows until page 1 replaces them" {
    var l: List = .init(testing.allocator, .checkouts);
    defer l.deinit();
    try l.reload(false);
    var buf: [32][8]u8 = undefined;
    const old = pageOfItems(&buf, "old", 25);
    _ = try l.apply(l.generation, 1, old, 30, 25, 0);
    l.beginRefresh();
    try testing.expect(l.refreshing);
    try l.reload(true);
    try testing.expectEqual(@as(usize, 30), l.rows.items.len);
    try testing.expectEqualStrings("old0", std.mem.span(l.rows.items[0].id.?));
    // Later pages wait for page 1.
    try testing.expect(!try l.request(2));
    try testing.expectEqual(@as(i64, 0), try l.itemAppeared(20));
    var buf2: [32][8]u8 = undefined;
    const new = pageOfItems(&buf2, "new", 2);
    _ = try l.apply(l.generation, 1, new, 2, 25, 0);
    try testing.expect(!l.refreshing);
    try testing.expectEqual(@as(usize, 2), l.rows.items.len);
    try testing.expectEqualStrings("new0", std.mem.span(l.rows.items[0].id.?));
}

test "a failed refresh drops the stale rows" {
    var l: List = .init(testing.allocator, .checkouts);
    defer l.deinit();
    try l.reload(false);
    var buf: [32][8]u8 = undefined;
    const p1 = pageOfItems(&buf, "a", 2);
    _ = try l.apply(l.generation, 1, p1, 2, 25, 0);
    try l.reload(true);
    try testing.expect(try l.fail(l.generation, 1));
    try testing.expect(!l.loaded);
    try testing.expectEqual(@as(usize, 0), l.rows.items.len);
    try testing.expect(!l.isLoading());
}

test "people waiting sorts fetched items first, then the rest in the background" {
    var l: List = .init(testing.allocator, .search);
    defer l.deinit();
    try l.reload(false);
    const p1 = [_]Item{ item("a", 1), item("b", 5), item("c", 5) };
    _ = try l.apply(l.generation, 1, &p1, 5, 3, 0);
    try l.setSort(.people_waiting);
    try testing.expect(l.needsAllPages());
    try testing.expectEqualStrings("b", std.mem.span(l.rows.items[0].id.?));
    try testing.expectEqualStrings("c", std.mem.span(l.rows.items[1].id.?));
    try testing.expectEqualStrings("a", std.mem.span(l.rows.items[2].id.?));
    try testing.expectEqual(@as(usize, 2), placeholders(&l));
    // No prefetching by scroll position under a client sort.
    try testing.expectEqual(@as(i64, 0), try l.itemAppeared(2));
    try testing.expect(l.beginBackground());
    try testing.expect(!l.beginBackground());
    const next = try l.nextBackgroundPage();
    try testing.expectEqual(@as(i64, 2), next);
    const p2 = [_]Item{ item("d", 9), item("e", 0) };
    _ = try l.apply(l.generation, 2, &p2, 5, 3, 0);
    try testing.expectEqualStrings("d", std.mem.span(l.rows.items[0].id.?));
    try testing.expectEqual(@as(i64, 0), try l.nextBackgroundPage());
    try testing.expect(!l.background);
}

test "hold filters and formats count loaded holds" {
    var l: List = .init(testing.allocator, .holds);
    defer l.deinit();
    try l.reload(false);
    var p1 = [_]Item{ item("r", 0), item("w", 0), item("o", 0), item("dvd", 0) };
    for (&p1) |*it| it.is_hold = true;
    p1[0].ready = true;
    p1[2].on_order = true;
    p1[3].format = "DVD";
    _ = try l.apply(l.generation, 1, &p1, 4, 25, 0);
    try testing.expect(l.wantsAllPages());
    try testing.expectEqual(@as(i64, 1), l.holdCount(.ready));
    try testing.expectEqual(@as(i64, 3), l.holdCount(.not_ready));
    try testing.expectEqual(@as(i64, 1), l.holdCount(.on_order));
    try testing.expectEqualStrings("BK", std.mem.span(l.formats.items[0].format));
    try testing.expectEqual(@as(i64, 3), l.formats.items[0].count);
    try l.setHoldFilter(.not_ready);
    try testing.expectEqual(@as(usize, 3), l.rows.items.len);
    try l.setFormat("DVD");
    try testing.expectEqual(@as(usize, 1), l.rows.items.len);
    try testing.expectEqual(@as(i64, 1), l.holdCount(.not_ready));
    try l.setFormat(null);
    try l.setHoldFilter(.none);
    try testing.expectEqual(@as(usize, 2), try l.remove(&.{ "r", "o" }));
    try testing.expectEqual(@as(i64, 2), l.total);
    try testing.expectEqualStrings("dvd", std.mem.span(l.ids.items[1]));
}

test "an item that moved between pages keeps its first position" {
    var l: List = .init(testing.allocator, .search);
    defer l.deinit();
    try l.reload(false);
    const p1 = [_]Item{ item("a", 0), item("b", 0) };
    _ = try l.apply(l.generation, 1, &p1, 4, 2, 0);
    _ = try l.request(2);
    const p2 = [_]Item{ item("b", 0), item("c", 0) };
    _ = try l.apply(l.generation, 2, &p2, 4, 2, 0);
    try testing.expectEqual(@as(usize, 3), l.ids.items.len);
    // The list shrinks when the total does.
    try l.reload(false);
    _ = try l.apply(l.generation, 1, &p1, 2, 2, 0);
    try testing.expectEqual(@as(usize, 2), l.rows.items.len);
}

test "lists go stale after 15 minutes" {
    var l: List = .init(testing.allocator, .history);
    defer l.deinit();
    try testing.expect(!l.isStale(0));
    try l.reload(false);
    _ = try l.apply(l.generation, 1, &.{}, 0, 25, 1000);
    try testing.expect(!l.isStale(1000 + max_age_ms));
    try testing.expect(l.isStale(1001 + max_age_ms));
}

test "natural order" {
    try testing.expectEqual(std.math.Order.lt, naturalOrder("Book 2", "book 10"));
    try testing.expectEqual(std.math.Order.gt, naturalOrder("b", "A"));
    try testing.expectEqual(std.math.Order.lt, naturalOrder("Dune", "Dune Messiah"));
    try testing.expectEqual(std.math.Order.eq, naturalOrder("x07", "X7"));
}
