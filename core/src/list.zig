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
const formats = @import("formats.zig");
const borrowed = @import("borrowed.zig");

pub const Kind = enum(c_int) { search = 0, holds, checkouts, history };
pub const Sort = enum(c_int) { server = 0, people_waiting, title, due_date, status, server_title, author };
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
    /// The first author, as the library lists it ("Last, First"); empty for none.
    author: []const u8 = "",
    held_copies: i64 = 0,
    server_index: i64 = 0,
    is_hold: bool = false,
    /// A hold ready for pickup.
    ready: bool = false,
    /// Waiting on copies the library hasn't received yet.
    on_order: bool = false,
    /// The due date of a checkout as days since 1970-01-01; 0 when there is none.
    due_day: i64 = 0,
    /// Where a hold's status falls in the "status" sort: ready, in transit, not yet available, paused.
    status_rank: u8 = 0,
    /// formats.workKey of the title and author; the list computes it.
    work_key: []const u8 = "",

    /// The rank of a hold's status string: ready, in transit, not yet available (or anything
    /// else), paused.
    pub fn statusRank(status: []const u8) u8 {
        const ready = [_][]const u8{ "READY_FOR_PICKUP", "READY" };
        const moving = [_][]const u8{ "IN_TRANSIT", "SHIPPED", "READY_SOON" };
        const paused = [_][]const u8{ "SUSPENDED", "INACTIVE" };
        for (ready) |s| if (std.mem.eql(u8, status, s)) return 0;
        for (moving) |s| if (std.mem.eql(u8, status, s)) return 1;
        for (paused) |s| if (std.mem.eql(u8, status, s)) return 3;
        return 2;
    }

    fn holdRank(h: models.Hold) u8 {
        return if (h.isReady()) 0 else statusRank(h.status);
    }

    pub fn from(e: models.ListEntry) Item {
        return .{
            .id = e.id,
            .title = e.bib.title,
            .format = e.bib.format,
            .author = if (e.bib.authors.len > 0) e.bib.authors[0] else "",
            .held_copies = e.bib.heldCopies,
            .server_index = e.serverIndex,
            .is_hold = e.hold != null,
            .ready = if (e.hold) |h| h.isReady() else false,
            .on_order = e.bib.onOrderCopies > 0 or
                (if (e.bib.status) |s| std.mem.eql(u8, s, "ON_ORDER") else false),
            .due_day = if (e.checkout) |c| if (c.dueDate) |d| dayNumber(d) else 0 else 0,
            .status_rank = if (e.hold) |h| holdRank(h) else 0,
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

/// Days since 1970-01-01 of a "YYYY-MM-DD" date (anything after those ten characters is
/// ignored); 0 if it isn't one.
pub fn dayNumber(date: []const u8) i64 {
    if (date.len < 10 or date[4] != '-' or date[7] != '-') return 0;
    const y = std.fmt.parseInt(i64, date[0..4], 10) catch return 0;
    const m = std.fmt.parseInt(i64, date[5..7], 10) catch return 0;
    const d = std.fmt.parseInt(i64, date[8..10], 10) catch return 0;
    if (m < 1 or m > 12 or d < 1 or d > 31) return 0;
    // Days from civil (Howard Hinnant).
    const yy = if (m <= 2) y - 1 else y;
    const era = @divFloor(yy, 400);
    const yoe = yy - era * 400;
    const doy = @divFloor(153 * (if (m > 2) m - 3 else m + 9) + 2, 5) + d - 1;
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    return era * 146097 + doe - 719468;
}

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
    /// "Not Borrowed": hides works these indexes (borrowed, the app's) have in the item's format.
    not_borrowed: []const *const borrowed.Index = &.{},

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
        l.gpa.free(l.not_borrowed);
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
            it.author = try a.dupe(u8, src.author);
            it.work_key = try formats.workKey(a, src.title, src.author);
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

    /// Searches filter on the server, except for refined formats (formats.zig) and "Not Borrowed".
    fn hasLocalFilter(l: *const List) bool {
        if (l.not_borrowed.len > 0) return true;
        if (l.kind == .search) return if (l.format) |f| formats.isRefined(f) else false;
        return l.format != null or l.hold_filter != .none;
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

    /// Shows only what none of these indexes has borrowed in the item's format; none turns the
    /// filter off. Call again after the indexes change.
    pub fn setNotBorrowed(l: *List, indexes: []const *const borrowed.Index) Allocator.Error!void {
        const copy = try l.gpa.dupe(*const borrowed.Index, indexes);
        l.gpa.free(l.not_borrowed);
        l.not_borrowed = copy;
        try l.rebuild();
    }

    fn passesNotBorrowed(l: *const List, it: Item) bool {
        for (l.not_borrowed) |ix| if (ix.hasWorkInFormat(it.work_key, it.format)) return false;
        return true;
    }

    /// Removes the items with these ids (after canceling holds); returns how many.
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
            if (it.matches(filter) and l.passesFormat(it) and l.passesNotBorrowed(it)) n += 1;
        };
        return n;
    }

    fn passesFormat(l: *const List, it: Item) bool {
        const f = l.format orelse return true;
        // The server filtered searches, except to refined formats.
        if (l.kind == .search and !formats.isRefined(f)) return true;
        return std.mem.eql(u8, f, it.format);
    }

    fn passesLocalFilters(l: *const List, it: Item) bool {
        return l.passesFormat(it) and (l.hold_filter == .none or it.matches(l.hold_filter)) and l.passesNotBorrowed(it);
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
            .due_date => if (x.due_day != y.due_day) dueBefore(x.due_day, y.due_day) else x.server_index < y.server_index,
            .status => if (x.status_rank != y.status_rank) x.status_rank < y.status_rank else x.server_index < y.server_index,
            .server, .server_title, .author => a < b,
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

/// Earlier due dates first, with items that have none last.
fn dueBefore(a: i64, b: i64) bool {
    if (a == 0 or b == 0) return a != 0;
    return a < b;
}

/// Orders titles as people expect: ignoring case and accents, with runs of digits compared as
/// numbers ("Book 2" before "Book 10", "Émile" before "Zoolander"). Other characters compare by
/// code point.
pub fn naturalOrder(a: []const u8, b: []const u8) std.math.Order {
    var x: Folded = .{ .s = a };
    var y: Folded = .{ .s = b };
    while (!x.done() and !y.done()) {
        if (x.atDigit() and y.atDigit()) {
            const dx = std.mem.trimStart(u8, x.digits(), "0");
            const dy = std.mem.trimStart(u8, y.digits(), "0");
            if (dx.len != dy.len) return std.math.order(dx.len, dy.len);
            const od = std.mem.order(u8, dx, dy);
            if (od != .eq) return od;
            continue;
        }
        const o = std.math.order(x.next(), y.next());
        if (o != .eq) return o;
    }
    return std.math.order(@intFromBool(!x.done()), @intFromBool(!y.done()));
}

/// A title read one character at a time: lowercase ASCII, Latin letters without their accents,
/// and ligatures spelled out ("Æ" reads "ae").
pub const Folded = struct {
    s: []const u8,
    i: usize = 0,
    /// The second letter of a spelled-out ligature.
    pending: u8 = 0,

    /// Base letters for U+00C0–U+017F, and second letters for ligatures; a space keeps the
    /// character as it is.
    const first = "aaaaaaaceeeeiiiidnooooo ouuuuytsaaaaaaaceeeeiiiidnooooo ouuuuytyaaaaaaccccccccddddeeeeeeeeeegggggggghhhhiiiiiiiiiiiijjkkkllllllllllnnnnnnnnnoooooooorrrrrrssssssssttttttuuuuuuuuuuuuwwyyyzzzzzzs";
    const second = "      e                       hs      e                       h                                                   jj                              ee                                            ";

    pub fn done(f: Folded) bool {
        return f.pending == 0 and f.i >= f.s.len;
    }

    fn atDigit(f: Folded) bool {
        return f.pending == 0 and f.i < f.s.len and std.ascii.isDigit(f.s[f.i]);
    }

    fn digits(f: *Folded) []const u8 {
        const start = f.i;
        while (f.i < f.s.len and std.ascii.isDigit(f.s[f.i])) f.i += 1;
        return f.s[start..f.i];
    }

    pub fn next(f: *Folded) u21 {
        if (f.pending != 0) {
            defer f.pending = 0;
            return f.pending;
        }
        // Invalid UTF-8 reads a byte at a time.
        const byte = f.s[f.i];
        const len = std.unicode.utf8ByteSequenceLength(byte) catch 1;
        const decoded: ?u21 = if (len > 1 and f.i + len <= f.s.len) std.unicode.utf8Decode(f.s[f.i..][0..len]) catch null else null;
        f.i += if (decoded != null) len else 1;
        const cp = decoded orelse byte;
        if (cp < 0x80) return std.ascii.toLower(@intCast(cp));
        if (cp < 0xC0 or cp >= 0x180 or first[cp - 0xC0] == ' ') return cp;
        if (second[cp - 0xC0] != ' ') f.pending = second[cp - 0xC0];
        return first[cp - 0xC0];
    }
};

// MARK: Merging

/// A displayed row of a merged list: a `Row` of the login's own list, tagged with the login.
pub const MergedRow = extern struct {
    /// The index of the login's list in the merge.
    login: u32,
    position: i64,
    /// The item's id, which is only unique within its login; null for a placeholder.
    id: ?[*:0]const u8,
};

/// Interlaces the lists of several logins of one library into one. The lists stay the app's:
/// each pages, goes stale, and refetches on its own, so a card's pages are fetched only when
/// that card's rows are viewed. The merge only orders what they have fetched.
///
/// Rows interleave by server position (card breaking ties), or by the sort with the card as
/// the secondary key. `due_date` merges a server sort by due date, which each list already has. Placeholders of every card keep the scroll bar's length.
pub const Merge = struct {
    gpa: Allocator,
    /// Borrowed; they must outlive the merge.
    lists: []const *List,
    sort: Sort = .server,
    /// Which logins show, by bit.
    cards: u64 = std.math.maxInt(u64),
    rows: std.ArrayList(MergedRow) = .empty,

    pub fn init(gpa: Allocator, lists: []const *List) Merge {
        return .{ .gpa = gpa, .lists = lists };
    }

    pub fn deinit(m: *Merge) void {
        m.rows.deinit(m.gpa);
    }

    /// Sorts the merged rows only; the lists keep the order the server gives.
    pub fn setSort(m: *Merge, sort: Sort) void {
        m.sort = sort;
    }

    pub fn setCards(m: *Merge, mask: u64) void {
        m.cards = mask;
    }

    /// The filters belong to the lists, because their counts and background fetching do.
    pub fn setFormat(m: *Merge, format: ?[]const u8) Allocator.Error!void {
        for (m.lists) |l| try l.setFormat(format);
    }

    pub fn setHoldFilter(m: *Merge, filter: HoldFilter) Allocator.Error!void {
        for (m.lists) |l| try l.setHoldFilter(filter);
    }

    /// Every list hides what any of the cards' indexes has borrowed.
    pub fn setNotBorrowed(m: *Merge, indexes: []const *const borrowed.Index) Allocator.Error!void {
        for (m.lists) |l| try l.setNotBorrowed(indexes);
    }

    pub fn total(m: *const Merge) i64 {
        var n: i64 = 0;
        for (m.lists, 0..) |l, i| if (m.shows(i)) {
            n += l.total;
        };
        return n;
    }

    pub fn holdCount(m: *const Merge, filter: HoldFilter) i64 {
        var n: i64 = 0;
        for (m.lists, 0..) |l, i| if (m.shows(i)) {
            n += l.holdCount(filter);
        };
        return n;
    }

    fn shows(m: *const Merge, login: usize) bool {
        return login < 64 and (m.cards >> @intCast(login)) & 1 == 1;
    }

    const Entry = struct { login: u32, position: usize, item: ?Item };

    fn lessThan(m: *const Merge, a: Entry, b: Entry) bool {
        // Fetched items come before placeholders, which keep server order among themselves.
        if ((a.item == null) != (b.item == null)) return a.item != null;
        if (a.item) |x| if (b.item) |y| switch (m.sort) {
            .people_waiting => if (x.held_copies != y.held_copies) return x.held_copies > y.held_copies,
            .title => switch (naturalOrder(x.title, y.title)) {
                .lt => return true,
                .gt => return false,
                .eq => {},
            },
            .due_date => if (x.due_day != y.due_day) return dueBefore(x.due_day, y.due_day),
            .status => if (x.status_rank != y.status_rank) return x.status_rank < y.status_rank,
            .server, .server_title, .author => {},
        };
        if (m.sort == .people_waiting or m.sort == .due_date or m.sort == .status) if (a.item) |x| if (b.item) |y| if (x.server_index != y.server_index) return x.server_index < y.server_index;
        if (a.position != b.position and (m.sort == .server or a.item == null)) return a.position < b.position;
        return a.login < b.login;
    }

    fn keyBefore(m: *const Merge, x: Item, y: Item) bool {
        if (m.sort == .author) {
            // Items with no author go last.
            if ((x.author.len == 0) != (y.author.len == 0)) return x.author.len != 0;
            return naturalOrder(x.author, y.author) == .lt;
        }
        return naturalOrder(x.title, y.title) == .lt;
    }

    /// Orders `entries` (grouped by login, each in its list's server order) so each login keeps
    /// the order the server gave it and the logins interleave by title or author. Placeholders
    /// follow, by position.
    fn mergeByKey(m: *const Merge, entries: *std.ArrayList(Entry)) Allocator.Error!void {
        var merged: std.ArrayList(Entry) = .empty;
        defer merged.deinit(m.gpa);
        var holes: std.ArrayList(Entry) = .empty;
        defer holes.deinit(m.gpa);
        var queues: [64]std.ArrayList(Entry) = @splat(.empty);
        defer for (&queues) |*q| q.deinit(m.gpa);
        for (entries.items) |e| {
            if (e.item == null) try holes.append(m.gpa, e) else try queues[e.login].append(m.gpa, e);
        }
        var heads: [64]usize = @splat(0);
        while (true) {
            var best: ?usize = null;
            for (queues, 0..) |q, login| {
                if (heads[login] >= q.items.len) continue;
                if (best) |b| {
                    if (m.keyBefore(q.items[heads[login]].item.?, queues[b].items[heads[b]].item.?)) best = login;
                } else best = login;
            }
            const b = best orelse break;
            try merged.append(m.gpa, queues[b].items[heads[b]]);
            heads[b] += 1;
        }
        std.mem.sort(Entry, holes.items, {}, struct {
            fn less(_: void, a: Entry, b: Entry) bool {
                return if (a.position != b.position) a.position < b.position else a.login < b.login;
            }
        }.less);
        entries.clearRetainingCapacity();
        try entries.appendSlice(m.gpa, merged.items);
        try entries.appendSlice(m.gpa, holes.items);
    }

    /// The merged rows, valid until the next call. A card still refreshing shows its stale rows.
    pub fn buildRows(m: *Merge) Allocator.Error![]const MergedRow {
        var entries: std.ArrayList(Entry) = .empty;
        defer entries.deinit(m.gpa);
        for (m.lists, 0..) |l, login| {
            if (!m.shows(login)) continue;
            for (l.slots.items, 0..) |slot, i| {
                if (slot) |it| {
                    if (!l.hasLocalFilter() or l.passesLocalFilters(it)) try entries.append(m.gpa, .{ .login = @intCast(login), .position = i, .item = it });
                } else if (!l.hasLocalFilter() and !l.loaded_pages.contains(l.pageOf(@intCast(i)))) {
                    try entries.append(m.gpa, .{ .login = @intCast(login), .position = i, .item = null });
                }
            }
        }
        if (m.sort == .server_title or m.sort == .author) try m.mergeByKey(&entries) else std.mem.sort(Entry, entries.items, m, lessThan);
        m.rows.clearRetainingCapacity();
        for (entries.items) |e| {
            try m.rows.append(m.gpa, .{
                .login = e.login,
                .position = @intCast(e.position),
                .id = if (e.item) |it| z(it.id) else null,
            });
        }
        return m.rows.items;
    }
};

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
    try testing.expectEqual(std.math.Order.lt, naturalOrder("Émile", "Zoolander"));
    try testing.expectEqual(std.math.Order.eq, naturalOrder("Café 2", "cafe 02"));
    try testing.expectEqual(std.math.Order.lt, naturalOrder("Ærø", "Aes"));
    try testing.expectEqual(std.math.Order.gt, naturalOrder("Straße", "Strass"));
    try testing.expectEqual(std.math.Order.gt, naturalOrder("日本", "Zoo"));
    try testing.expectEqual(std.math.Order.lt, naturalOrder("a\xff", "a\xffb"));
}

fn named(buf: *[8][8]u8, prefix: u8, n: usize, held: i64) []Item {
    const S = struct {
        var items: [8]Item = undefined;
    };
    for (0..n) |i| {
        const id = std.fmt.bufPrint(&buf[i], "{c}{d}", .{ prefix, i }) catch unreachable;
        S.items[i] = .{ .id = id, .title = id, .format = "BK", .held_copies = held - @as(i64, @intCast(i)), .server_index = @intCast(i) };
    }
    return S.items[0..n];
}

fn idAt(rows: []const MergedRow, i: usize) []const u8 {
    return std.mem.span(rows[i].id.?);
}

test "merged lists interlace by position, with placeholders for unfetched cards" {
    var a: List = .init(testing.allocator, .holds);
    defer a.deinit();
    var b: List = .init(testing.allocator, .holds);
    defer b.deinit();
    try a.reload(false);
    try b.reload(false);
    var bufa: [8][8]u8 = undefined;
    var bufb: [8][8]u8 = undefined;
    try testing.expect(try a.apply(a.generation, 1, named(&bufa, 'a', 3, 9), 3, 25, 0));
    // The second card has only fetched 2 of 30 items.
    try testing.expect(try b.apply(b.generation, 1, named(&bufb, 'b', 2, 9), 30, 2, 0));

    var m: Merge = .init(testing.allocator, &.{ &a, &b });
    defer m.deinit();
    const rows = try m.buildRows();
    try testing.expectEqual(@as(usize, 33), rows.len);
    try testing.expectEqual(@as(i64, 33), m.total());
    try testing.expectEqualStrings("a0", idAt(rows, 0));
    try testing.expectEqualStrings("b0", idAt(rows, 1));
    try testing.expectEqualStrings("a1", idAt(rows, 2));
    try testing.expectEqual(@as(u32, 1), rows[3].login);
    try testing.expectEqualStrings("b1", idAt(rows, 3));
    try testing.expectEqualStrings("a2", idAt(rows, 4));
    try testing.expect(rows[5].id == null and rows[5].login == 1);

    // Hiding a card drops its rows.
    m.setCards(0b01);
    try testing.expectEqual(@as(usize, 3), (try m.buildRows()).len);
}

test "merged lists sort across cards with the card as the secondary key" {
    var a: List = .init(testing.allocator, .holds);
    defer a.deinit();
    var b: List = .init(testing.allocator, .holds);
    defer b.deinit();
    try a.reload(false);
    try b.reload(false);
    // Both cards hold a title with the same name: it sorts once per card, the first card first.
    var one = [_]Item{.{ .id = "H1", .title = "Dune", .format = "BK", .held_copies = 2 }};
    var two = [_]Item{ .{ .id = "H9", .title = "Dune", .format = "BK", .held_copies = 2 }, .{ .id = "H8", .title = "Arrival", .format = "BK", .held_copies = 7 } };
    try testing.expect(try a.apply(a.generation, 1, &one, 1, 25, 0));
    try testing.expect(try b.apply(b.generation, 1, &two, 2, 25, 0));

    var m: Merge = .init(testing.allocator, &.{ &a, &b });
    defer m.deinit();
    m.setSort(.title);
    var rows = try m.buildRows();
    try testing.expectEqualStrings("H8", idAt(rows, 0));
    try testing.expectEqualStrings("H1", idAt(rows, 1));
    try testing.expectEqualStrings("H9", idAt(rows, 2));

    m.setSort(.people_waiting);
    rows = try m.buildRows();
    try testing.expectEqualStrings("H8", idAt(rows, 0));
    try testing.expectEqual(@as(u32, 0), rows[1].login);
}

test "day numbers" {
    try testing.expectEqual(@as(i64, 0), dayNumber("1970-01-01"));
    try testing.expectEqual(@as(i64, 19723), dayNumber("2024-01-01T00:00:00"));
    try testing.expectEqual(@as(i64, 0), dayNumber("soon"));
}

test "merged holds in status order put every ready hold before the rest" {
    var a: List = .init(testing.allocator, .holds);
    defer a.deinit();
    var b: List = .init(testing.allocator, .holds);
    defer b.deinit();
    try a.reload(false);
    try b.reload(false);
    // Each card's own list is in status order; interlacing by position would put A2 (ready)
    // after B1 (not yet available).
    var one = [_]Item{
        .{ .id = "A1", .title = "x", .format = "BK", .is_hold = true, .status_rank = 0 },
        .{ .id = "A2", .title = "x", .format = "BK", .server_index = 1, .is_hold = true, .status_rank = 0 },
    };
    var two = [_]Item{
        .{ .id = "B1", .title = "x", .format = "BK", .is_hold = true, .status_rank = 2 },
        .{ .id = "B2", .title = "x", .format = "BK", .server_index = 1, .is_hold = true, .status_rank = 2 },
    };
    try testing.expect(try a.apply(a.generation, 1, &one, 2, 25, 0));
    try testing.expect(try b.apply(b.generation, 1, &two, 2, 25, 0));
    var m: Merge = .init(testing.allocator, &.{ &a, &b });
    defer m.deinit();
    m.setSort(.status);
    const rows = try m.buildRows();
    const want = [_][]const u8{ "A1", "A2", "B1", "B2" };
    for (want, 0..) |id, i| try testing.expectEqualStrings(id, idAt(rows, i));
}

test "merged lists interleave by title or author, keeping each card's server order" {
    var a: List = .init(testing.allocator, .holds);
    defer a.deinit();
    var b: List = .init(testing.allocator, .holds);
    defer b.deinit();
    try a.reload(false);
    try b.reload(false);
    // The server orders titles its own way ("The Zoo" under Z); the merge must not reorder a card.
    var one = [_]Item{
        .{ .id = "A1", .title = "Apple", .author = "Zed, A", .format = "BK" },
        .{ .id = "A2", .title = "The Zoo", .author = "Yan, B", .format = "BK", .server_index = 1 },
    };
    var two = [_]Item{
        .{ .id = "B1", .title = "Banana", .author = "Xu, C", .format = "BK" },
        .{ .id = "B2", .title = "Cherry", .author = "", .format = "BK", .server_index = 1 },
    };
    try testing.expect(try a.apply(a.generation, 1, &one, 2, 25, 0));
    try testing.expect(try b.apply(b.generation, 1, &two, 2, 25, 0));
    var m: Merge = .init(testing.allocator, &.{ &a, &b });
    defer m.deinit();
    m.setSort(.server_title);
    var rows = try m.buildRows();
    const by_title = [_][]const u8{ "A1", "B1", "B2", "A2" };
    for (by_title, 0..) |id, i| try testing.expectEqualStrings(id, idAt(rows, i));
    m.setSort(.author);
    rows = try m.buildRows();
    const by_author = [_][]const u8{ "B1", "A1", "A2", "B2" };
    for (by_author, 0..) |id, i| try testing.expectEqualStrings(id, idAt(rows, i));
}

test "merged lists order checkouts by true due date" {
    var a: List = .init(testing.allocator, .checkouts);
    defer a.deinit();
    var b: List = .init(testing.allocator, .checkouts);
    defer b.deinit();
    try a.reload(false);
    try b.reload(false);
    var one = [_]Item{ .{ .id = "A1", .title = "x", .format = "BK", .due_day = 100 }, .{ .id = "A2", .title = "x", .format = "BK", .server_index = 1, .due_day = 130 } };
    var two = [_]Item{ .{ .id = "B1", .title = "x", .format = "BK", .due_day = 110 }, .{ .id = "B2", .title = "x", .format = "BK", .server_index = 1, .due_day = 0 } };
    try testing.expect(try a.apply(a.generation, 1, &one, 2, 25, 0));
    try testing.expect(try b.apply(b.generation, 1, &two, 2, 25, 0));
    var m: Merge = .init(testing.allocator, &.{ &a, &b });
    defer m.deinit();
    m.setSort(.due_date);
    const rows = try m.buildRows();
    const want = [_][]const u8{ "A1", "B1", "A2", "B2" };
    for (want, 0..) |id, i| try testing.expectEqualStrings(id, idAt(rows, i));
}

test "searches filter refined formats and what was borrowed locally" {
    var ix = borrowed.Index.init(testing.allocator);
    defer ix.deinit();
    _ = ix.beginSync();
    const history = [_]borrowed.Source{.{ .id = "B1", .metadata_id = "S9", .format = "DVD", .library_format = "DVD", .title = "Moana" }};
    _ = try ix.apply(1, &history, 1, 25);

    var l: List = .init(testing.allocator, .search);
    defer l.deinit();
    try l.reload(false);
    var page = [_]Item{
        .{ .id = "S1", .title = "Moana", .format = "DVD" },
        .{ .id = "S2", .title = "Moana", .format = "UK", .server_index = 1 },
        .{ .id = "S3", .title = "Coco", .format = "BLURAY", .server_index = 2 },
    };
    try testing.expect(try l.apply(l.generation, 1, &page, 3, 25, 0));
    // A server-side format filter is the server's business.
    try l.setFormat("DVD");
    try testing.expectEqual(@as(usize, 3), l.rows.items.len);
    try testing.expect(!l.needsAllPages());
    try l.setFormat("UK");
    try testing.expectEqual(@as(usize, 1), l.rows.items.len);
    try testing.expect(l.needsAllPages());
    try l.setFormat(null);
    try l.setNotBorrowed(&.{&ix});
    try testing.expectEqual(@as(usize, 2), l.rows.items.len);
    try testing.expectEqualStrings("S2", std.mem.span(l.rows.items[0].id.?));
    try l.setNotBorrowed(&.{});
    try testing.expectEqual(@as(usize, 3), l.rows.items.len);
}
