//! A mock library for screenshots and demos (see ../mock/README.md).
//!
//! Setting `BIBLIO_MOCK` to a fixtures directory (such as `core/mock/video`) puts this in
//! front of the real transport: the gateway and website of one fictional library are served
//! from the fixtures, with holds and settings changing in memory, and every other request
//! goes to the real transport. Compiled out of release builds (`ReleaseFast` and `ReleaseSmall`).

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const sync = @import("sync.zig");
const http = @import("http.zig");
const html = @import("html.zig");
const json = @import("json.zig");
const J = json.J;
const Value = std.json.Value;

const available = builtin.os.tag != .windows and !builtin.abi.isAndroid() and builtin.mode != .fast and builtin.mode != .small;

var instance: ?*Mock = null;
var instance_mutex: sync.Mutex = .{};

/// The mock transport in front of `real`, or null unless `BIBLIO_MOCK` names a fixtures directory.
pub fn wrap(real: http.Transport) ?http.Transport {
    if (!available) return null;
    instance_mutex.lock();
    defer instance_mutex.unlock();
    if (instance == null) {
        const dir = std.c.getenv("BIBLIO_MOCK") orelse return null;
        instance = Mock.load(std.mem.span(dir)) catch {
            const message = "libbiblio: BIBLIO_MOCK fixtures not loaded\n";
            _ = std.c.write(2, message.ptr, message.len);
            return null;
        };
    }
    instance.?.fallback = real;
    return .{ .ctx = instance, .sendFn = send };
}

fn send(ctx: ?*anyopaque, a: Allocator, req: http.Request) anyerror!http.Response {
    const m: *Mock = @ptrCast(@alignCast(ctx.?));
    m.mutex.lock();
    const res = m.route(a, req) catch |err| {
        m.mutex.unlock();
        return err;
    };
    m.mutex.unlock();
    return res orelse m.fallback.send(a, req);
}

// MARK: Fixtures

const Copy = struct {
    branch: []const u8,
    collection: []const u8,
    call: []const u8,
    status: []const u8,
    due_days: ?i64,
};

const Entry = struct {
    id: []const u8,
    brief: Value,
    title: []const u8,
    author: []const u8,
    format: []const u8,
    held: i64,
    on_order: i64,
    is_new: bool,
    order: i64,
    copies: []const Copy,

    fn count(e: Entry, wanted: []const u8) i64 {
        var n: i64 = 0;
        for (e.copies) |c| if (std.mem.eql(u8, c.status, wanted)) {
            n += 1;
        };
        return n;
    }

    fn status(e: Entry) []const u8 {
        if (e.count("AVAILABLE") > 0) return "AVAILABLE";
        return if (e.copies.len == 0 and e.on_order > 0) "ON_ORDER" else "UNAVAILABLE";
    }
};

const HoldRecord = struct {
    id: []const u8,
    bib: []const u8,
    status: []const u8,
    position: i64,
    pickup: []const u8,
    pickup_by_days: ?i64,
};

const CheckoutRecord = struct { bib: []const u8, due_days: i64, out_days: i64, renewed: i64 };
const HistoryRecord = struct { bib: []const u8, out_days: i64, returned_days: i64 };

const Branch = struct { id: []const u8, name: []const u8 };

const Mock = struct {
    arena: std.heap.ArenaAllocator,
    mutex: sync.Mutex = .{},
    fallback: http.Transport = undefined,

    library: J,
    subdomain: []const u8,
    branches: []const Branch,
    catalog: []Entry,
    holds: std.ArrayList(HoldRecord) = .empty,
    checkouts: []CheckoutRecord,
    history: []HistoryRecord,
    next_hold: u32 = 9000,
    today: i64,

    email: []const u8,
    pickup: []const u8,
    language: []const u8,
    history_enabled: bool,

    fn load(dir: []const u8) !*Mock {
        const m = try sync.allocator.create(Mock);
        errdefer sync.allocator.destroy(m);
        m.* = undefined;
        m.arena = .init(sync.allocator);
        m.mutex = .{};
        m.holds = .empty;
        m.next_hold = 9000;
        const a = m.arena.allocator();

        m.library = try readJson(a, dir, "../shared/library.json");
        const lib = m.library;
        m.subdomain = lib.get("subdomain").str(a) orelse "firstlanding";
        var branches: std.ArrayList(Branch) = .empty;
        for (lib.get("branches").items()) |b| {
            try branches.append(a, .{ .id = J.of(b).get("id").str(a) orelse continue, .name = J.of(b).get("name").str(a) orelse continue });
        }
        m.branches = branches.items;
        const patron = lib.get("patron");
        m.email = patron.get("email").str(a) orelse "";
        m.pickup = patron.get("pickup").str(a) orelse "";
        m.language = patron.get("language").str(a) orelse "en-US";
        m.history_enabled = patron.get("history").boolean() orelse true;

        var ts: std.c.timespec = undefined;
        _ = std.c.clock_gettime(.REALTIME, &ts);
        m.today = @divFloor(@as(i64, @intCast(ts.sec)), 86400);

        const cat = try readJson(a, dir, "catalog.json");
        var entries: std.ArrayList(Entry) = .empty;
        for (cat.items(), 0..) |item, index| {
            const e = J.of(item);
            const id = e.get("metadataId").str(a) orelse continue;
            var copies: std.ArrayList(Copy) = .empty;
            for (e.get("copies").items()) |c| {
                const cj = J.of(c);
                try copies.append(a, .{
                    .branch = cj.get("branch").str(a) orelse "",
                    .collection = cj.get("collection").str(a) orelse "",
                    .call = cj.get("call").str(a) orelse "",
                    .status = cj.get("status").str(a) orelse "AVAILABLE",
                    .due_days = cj.get("dueDays").int(),
                });
            }
            const authors = e.get("authors").strings(a);
            try entries.append(a, .{
                .id = id,
                .brief = item,
                .title = e.get("title").str(a) orelse "",
                .author = if (authors.len > 0) authors[0] else "",
                .format = e.get("format").str(a) orelse "UNKNOWN",
                .held = e.get("held").int() orelse 0,
                .on_order = e.get("onOrder").int() orelse 0,
                .is_new = e.get("new").boolean() orelse false,
                .order = @intCast(index),
                .copies = copies.items,
            });
        }
        m.catalog = entries.items;

        const acct = try readJson(a, dir, "account.json");
        for (acct.get("holds").items()) |h| {
            const hj = J.of(h);
            try m.holds.append(a, .{
                .id = try std.fmt.allocPrint(a, "H{d}", .{m.next_hold}),
                .bib = hj.get("bib").str(a) orelse continue,
                .status = hj.get("status").str(a) orelse "NOT_YET_AVAILABLE",
                .position = hj.get("position").int() orelse 0,
                .pickup = hj.get("pickup").str(a) orelse "",
                .pickup_by_days = hj.get("pickupByDays").int(),
            });
            m.next_hold += 1;
        }
        var checkouts: std.ArrayList(CheckoutRecord) = .empty;
        for (acct.get("checkouts").items()) |c| {
            const cj = J.of(c);
            try checkouts.append(a, .{
                .bib = cj.get("bib").str(a) orelse continue,
                .due_days = cj.get("dueDays").int() orelse 0,
                .out_days = cj.get("outDays").int() orelse 0,
                .renewed = cj.get("renewed").int() orelse 0,
            });
        }
        m.checkouts = checkouts.items;
        var history: std.ArrayList(HistoryRecord) = .empty;
        for (acct.get("history").items()) |h| {
            const hj = J.of(h);
            try history.append(a, .{
                .bib = hj.get("bib").str(a) orelse continue,
                .out_days = hj.get("outDays").int() orelse 0,
                .returned_days = hj.get("returnedDays").int() orelse 0,
            });
        }
        m.history = history.items;
        return m;
    }

    fn entry(m: *Mock, id: []const u8) ?*Entry {
        for (m.catalog) |*e| if (std.mem.eql(u8, e.id, id)) return e;
        return null;
    }

    fn branchName(m: *Mock, id: []const u8) []const u8 {
        for (m.branches) |b| if (std.mem.eql(u8, b.id, id)) return b.name;
        return id;
    }

    /// An ISO date `days` from today.
    fn date(m: *Mock, a: Allocator, days: i64) []const u8 {
        const day: std.time.epoch.EpochDay = .{ .day = @intCast(m.today + days) };
        const year_day = day.calculateYearDay();
        const month_day = year_day.calculateMonthDay();
        return std.fmt.allocPrint(a, "{d:0>4}-{d:0>2}-{d:0>2}", .{ year_day.year, month_day.month.numeric(), month_day.day_index + 1 }) catch "";
    }

    // MARK: Routing

    fn route(m: *Mock, a: Allocator, req: http.Request) !?http.Response {
        const host = http.hostOf(req.url);
        const path = html.urlPath(req.url);
        if (std.mem.eql(u8, host, "gateway.bibliocommons.com")) {
            const prefix = try std.fmt.allocPrint(a, "/v2/libraries/{s}/", .{m.subdomain});
            if (!std.mem.startsWith(u8, path, prefix)) return null;
            return try m.gateway(a, req, path[prefix.len..]);
        }
        const site = try std.fmt.allocPrint(a, "{s}.bibliocommons.com", .{m.subdomain});
        if (std.ascii.eqlIgnoreCase(host, site)) return try m.website(a, req, path);
        if (std.mem.eql(u8, host, "www.bibliocommons.com") and std.mem.eql(u8, path, "/libraries-we-work-with")) {
            return try m.directory(a);
        }
        return null;
    }

    fn gateway(m: *Mock, a: Allocator, req: http.Request, rest: []const u8) !http.Response {
        const get = std.mem.eql(u8, req.method, "GET");
        if (std.mem.eql(u8, rest, "sessions")) return m.login(a, req);
        if (std.mem.eql(u8, rest, "locations")) return m.locations(a);
        if (std.mem.eql(u8, rest, "bibs/search")) return m.search(a, req);
        if (std.mem.startsWith(u8, rest, "bibs/") and std.mem.endsWith(u8, rest, "/availability")) {
            return m.availability(a, rest["bibs/".len .. rest.len - "/availability".len]);
        }
        if (std.mem.startsWith(u8, rest, "catalogbibs/")) return m.detail(a, rest["catalogbibs/".len..]);
        if (std.mem.eql(u8, rest, "holds")) {
            if (get) return m.borrowing(a, req, .holds);
            if (std.mem.eql(u8, req.method, "POST")) return m.placeHold(a, req);
            if (std.mem.eql(u8, req.method, "DELETE")) return m.cancelHolds(a, req);
        }
        if (get and std.mem.eql(u8, rest, "checkouts")) return m.borrowing(a, req, .checkouts);
        if (get and std.mem.eql(u8, rest, "borrowinghistory")) return m.borrowing(a, req, .history);
        if (std.mem.endsWith(u8, rest, "/settings/borrowingHistorySetting")) {
            const body = json.parse(a, req.body orelse "");
            m.history_enabled = body.get("enabled").boolean() orelse m.history_enabled;
            return reply(a, 200, "{}");
        }
        return reply(a, 404, "{\"message\":\"Not found\"}");
    }

    fn reply(a: Allocator, status: u16, body: []const u8) !http.Response {
        const headers = try a.alloc(http.Header, 1);
        headers[0] = .{ .name = "Content-Type", .value = "application/json" };
        return .{ .status = status, .url = "", .headers = headers, .body = body };
    }

    fn page(a: Allocator, body: []const u8) !http.Response {
        const headers = try a.alloc(http.Header, 1);
        headers[0] = .{ .name = "Content-Type", .value = "text/html; charset=utf-8" };
        return .{ .status = 200, .url = "", .headers = headers, .body = body };
    }

    fn redirect(a: Allocator, to: []const u8) !http.Response {
        const headers = try a.alloc(http.Header, 1);
        headers[0] = .{ .name = "Location", .value = to };
        return .{ .status = 302, .url = "", .headers = headers, .body = "" };
    }

    // MARK: Gateway

    fn login(m: *Mock, a: Allocator, req: http.Request) !http.Response {
        const body = json.parse(a, req.body orelse "");
        const username = body.get("username").str(a) orelse "";
        const password = body.get("password").str(a) orelse "";
        if (username.len == 0 or password.len == 0 or std.mem.eql(u8, password, "wrong")) {
            return reply(a, 401, "{\"error\":{\"message\":\"The username or PIN was not recognized.\"}}");
        }
        const p = m.library.get("patron");
        var w: std.Io.Writer.Allocating = .init(a);
        try w.writer.print("{{\"auth\":{{\"sessionId\":\"MOCK\",\"authToken\":\"MOCK\",\"currentUserId\":{d}}},", .{p.get("userId").int() orelse 1});
        try w.writer.print("\"entities\":{{\"users\":{{\"{d}\":{{\"name\":", .{p.get("userId").int() orelse 1});
        try str(&w.writer, p.get("name").str(a) orelse username);
        try w.writer.print(",\"accounts\":[{d}],\"userContact\":{{\"email\":", .{p.get("accountId").int() orelse 1});
        try str(&w.writer, m.email);
        try w.writer.writeAll("},\"preferences\":{\"language\":");
        try str(&w.writer, m.language);
        try w.writer.print("}}}}}},\"accounts\":{{\"{d}\":{{\"barcode\":", .{p.get("accountId").int() orelse 1});
        try str(&w.writer, p.get("barcode").str(a) orelse "");
        try w.writer.writeAll(",\"preferredLocations\":[");
        try str(&w.writer, m.pickup);
        try w.writer.print("],\"borrowingHistoryEnabled\":{s}}}}}}}}}", .{if (m.history_enabled) "true" else "false"});
        return reply(a, 200, w.written());
    }

    fn locations(m: *Mock, a: Allocator) !http.Response {
        var w: std.Io.Writer.Allocating = .init(a);
        try w.writer.writeAll("{\"entities\":{\"locations\":{");
        for (m.branches, 0..) |b, i| {
            if (i > 0) try w.writer.writeByte(',');
            try str(&w.writer, b.id);
            try w.writer.writeAll(":{\"id\":");
            try str(&w.writer, b.id);
            try w.writer.writeAll(",\"name\":");
            try str(&w.writer, b.name);
            try w.writer.writeByte('}');
        }
        try w.writer.writeAll("}}}");
        return reply(a, 200, w.written());
    }

    /// `entities.bibs[id]`: the stored brief record plus the policy and availability summary.
    fn writeBib(m: *Mock, w: *std.Io.Writer, e: Entry) !void {
        _ = m;
        try str(w, e.id);
        try w.writeAll(":{\"id\":");
        try str(w, e.id);
        try w.writeAll(",\"briefInfo\":{\"metadataId\":");
        try str(w, e.id);
        // The stored fields use the brief record's own names.
        const o = e.brief.object;
        for ([_][]const u8{ "title", "subtitle", "format", "callNumber", "description", "authors", "publicationDate", "jacket", "edition" }) |key| {
            if (o.get(key)) |v| {
                try w.writeByte(',');
                try str(w, key);
                try w.writeByte(':');
                try std.json.Stringify.value(v, .{}, w);
            }
        }
        const total: i64 = @intCast(e.copies.len);
        try w.print("}},\"policy\":{{\"materialType\":\"PHYSICAL\",\"holdable\":true}},\"availability\":{{\"status\":\"{s}\",\"heldCopies\":{d},\"availableCopies\":{d},\"totalCopies\":{d},\"onOrderCopies\":{d}}}}}", .{
            e.status(), e.held, e.count("AVAILABLE"), total, e.on_order,
        });
    }

    fn writeHold(m: *Mock, a: Allocator, w: *std.Io.Writer, h: HoldRecord) !void {
        try w.writeAll("{\"holdsId\":");
        try str(w, h.id);
        try w.writeAll(",\"metadataId\":");
        try str(w, h.bib);
        try w.print(",\"status\":\"{s}\",\"holdsPosition\":{d},\"pickupLocation\":{{\"name\":", .{ h.status, h.position });
        try str(w, h.pickup);
        try w.writeByte('}');
        if (h.pickup_by_days) |d| {
            try w.writeAll(",\"pickupByDate\":");
            try str(w, m.date(a, d));
        }
        try w.writeAll(",\"actions\":[\"cancel\"]}");
    }

    fn writeCheckout(m: *Mock, a: Allocator, w: *std.Io.Writer, index: usize, c: CheckoutRecord) !void {
        try w.print("{{\"checkoutId\":\"C{d}\",\"metadataId\":", .{index + 1});
        try str(w, c.bib);
        try w.writeAll(",\"dueDate\":");
        try str(w, m.date(a, c.due_days));
        try w.writeAll(",\"checkoutDate\":");
        try str(w, m.date(a, -c.out_days));
        try w.print(",\"timesRenewed\":{d}}}", .{c.renewed});
    }

    fn search(m: *Mock, a: Allocator, req: http.Request) !http.Response {
        const body = json.parse(a, req.body orelse "");
        const text = try std.ascii.allocLowerString(a, body.get("query").str(a) orelse "");
        const search_type = body.get("searchType").str(a) orelse "smart";
        const want_format = body.get("f_FORMAT").nonEmpty(a);
        const on_order = body.get("f_on_order").str(a);
        const sort = body.get("sort").str(a) orelse "relevancy";
        const page_number = @max(1, body.get("page").int() orelse 1);
        const signed_in = for (req.headers) |h| {
            if (std.ascii.eqlIgnoreCase(h.name, "X-Session-Id")) break true;
        } else false;

        const new_titles = std.mem.eql(u8, search_type, "bl") and std.mem.startsWith(u8, text, "nw:");
        var matched: std.ArrayList(*Entry) = .empty;
        var formats: std.StringArrayHashMapUnmanaged(i64) = .empty;
        for (m.catalog) |*e| {
            if (new_titles) {
                if (!e.is_new) continue;
                if (on_order) |v| if ((e.on_order > 0) != std.mem.eql(u8, v, "true")) continue;
            } else if (!m.matches(a, e.*, text)) continue;
            try formats.put(a, e.format, (formats.get(e.format) orelse 0) + 1);
            if (want_format) |f| if (!std.mem.eql(u8, f, e.format)) continue;
            try matched.append(a, e);
        }
        std.mem.sort(*Entry, matched.items, sort, lessEntry);

        const limit: i64 = 25;
        const count: i64 = @intCast(matched.items.len);
        const pages = @max(1, @divTrunc(count + limit - 1, limit));
        const start: usize = @intCast(@min(count, (page_number - 1) * limit));
        const end: usize = @intCast(@min(count, page_number * limit));
        const shown = matched.items[start..end];

        var w: std.Io.Writer.Allocating = .init(a);
        try w.writer.writeAll("{\"catalogSearch\":{\"results\":[");
        for (shown, 0..) |e, i| {
            if (i > 0) try w.writer.writeByte(',');
            try w.writer.writeAll("{\"representative\":");
            try str(&w.writer, e.id);
            try w.writer.writeByte('}');
        }
        try w.writer.print("],\"pagination\":{{\"page\":{d},\"pages\":{d},\"count\":{d},\"limit\":{d}}},\"fields\":[{{\"id\":\"FORMAT\",\"fieldFilters\":[", .{ page_number, pages, count, limit });
        const Counted = struct { key: []const u8, n: i64 };
        var counted: std.ArrayList(Counted) = .empty;
        var it = formats.iterator();
        while (it.next()) |f| try counted.append(a, .{ .key = f.key_ptr.*, .n = f.value_ptr.* });
        std.mem.sort(Counted, counted.items, {}, struct {
            fn less(_: void, x: Counted, y: Counted) bool {
                if (x.n != y.n) return x.n > y.n;
                return std.mem.order(u8, x.key, y.key) == .lt;
            }
        }.less);
        for (counted.items, 0..) |f, i| {
            if (i > 0) try w.writer.writeByte(',');
            try w.writer.writeAll("{\"value\":");
            try str(&w.writer, f.key);
            try w.writer.print(",\"count\":{d}}}", .{f.n});
        }
        try w.writer.writeAll("]}],\"sortBys\":[");
        const sorts = [_][]const u8{ "relevancy", "newly_acquired", "title", "author" };
        for (sorts, 0..) |s, i| {
            if (i > 0) try w.writer.writeByte(',');
            try w.writer.print("{{\"id\":\"{s}\"{s}}}", .{ s, if (std.mem.eql(u8, s, sort)) ",\"applied\":true" else "" });
        }
        try w.writer.writeAll("]},\"entities\":{\"bibs\":{");
        for (shown, 0..) |e, i| {
            if (i > 0) try w.writer.writeByte(',');
            try m.writeBib(&w.writer, e.*);
        }
        try w.writer.writeAll("}");
        if (signed_in) {
            try w.writer.writeAll(",\"holds\":{");
            var first = true;
            for (m.holds.items) |h| {
                if (!contains(shown, h.bib)) continue;
                if (!first) try w.writer.writeByte(',');
                first = false;
                try str(&w.writer, h.id);
                try w.writer.writeByte(':');
                try m.writeHold(a, &w.writer, h);
            }
            try w.writer.writeAll("},\"checkouts\":{");
            first = true;
            for (m.checkouts, 0..) |c, i| {
                if (!contains(shown, c.bib)) continue;
                if (!first) try w.writer.writeByte(',');
                first = false;
                try w.writer.print("\"c{d}\":", .{i});
                try m.writeCheckout(a, &w.writer, i, c);
            }
            try w.writer.writeByte('}');
        }
        try w.writer.writeAll("}}");
        return reply(a, 200, w.written());
    }

    /// Every word of the query appears in the title, subtitle, or author.
    fn matches(m: *Mock, a: Allocator, e: Entry, text: []const u8) bool {
        _ = m;
        var words = std.mem.tokenizeAny(u8, text, " \t\"");
        const hay = std.ascii.allocLowerString(a, std.fmt.allocPrint(a, "{s} {s}", .{ e.title, e.author }) catch return true) catch return true;
        while (words.next()) |word| {
            if (std.mem.find(u8, hay, word) == null) return false;
        }
        return true;
    }

    fn lessEntry(sort: []const u8, x: *Entry, y: *Entry) bool {
        if (std.mem.eql(u8, sort, "title")) {
            const o = orderIgnoringCase(x.title, y.title);
            if (o != .eq) return o == .lt;
        } else if (std.mem.eql(u8, sort, "author")) {
            const o = orderIgnoringCase(x.author, y.author);
            if (o != .eq) return o == .lt;
        } else if (std.mem.eql(u8, sort, "newly_acquired")) {
            const kx: u8 = if (x.on_order > 0) 0 else if (x.is_new) 1 else 2;
            const ky: u8 = if (y.on_order > 0) 0 else if (y.is_new) 1 else 2;
            if (kx != ky) return kx < ky;
        }
        return x.order < y.order;
    }

    fn orderIgnoringCase(x: []const u8, y: []const u8) std.math.Order {
        return std.ascii.orderIgnoreCase(x, y);
    }

    fn availability(m: *Mock, a: Allocator, id: []const u8) !http.Response {
        const e = m.entry(id) orelse return reply(a, 404, "{\"message\":\"Not found\"}");
        var w: std.Io.Writer.Allocating = .init(a);
        try w.writer.writeAll("{\"availability\":{\"items\":[");
        var n: usize = 0;
        while (n < e.copies.len + @as(usize, if (e.on_order > 0) 1 else 0)) : (n += 1) {
            if (n > 0) try w.writer.writeByte(',');
            try w.writer.print("\"i{d}\"", .{n});
        }
        try w.writer.writeAll("]},\"entities\":{\"bibItems\":{");
        for (e.copies, 0..) |c, i| {
            if (i > 0) try w.writer.writeByte(',');
            const available_copy = std.mem.eql(u8, c.status, "AVAILABLE");
            const label: []const u8 = if (available_copy) "Available" else if (std.mem.eql(u8, c.status, "CHECKED_OUT")) "Checked out" else if (std.mem.eql(u8, c.status, "IN_TRANSIT")) "In-Transit" else "On hold shelf";
            try w.writer.print("\"i{d}\":{{\"collection\":", .{i});
            try str(&w.writer, c.collection);
            try w.writer.writeAll(",\"callNumber\":");
            try str(&w.writer, c.call);
            try w.writer.writeAll(",\"branchName\":");
            try str(&w.writer, c.branch);
            try w.writer.print(",\"availability\":{{\"status\":\"{s}\",\"statusType\":\"{s}\",\"libraryStatus\":\"{s}\",\"group\":\"{s}\"}}", .{
                c.status,
                if (available_copy) "AVAILABLE" else "UNAVAILABLE",
                label,
                if (available_copy) "AVAILABLE_ITEMS" else "NOT_AVAILABLE_ITEMS",
            });
            if (c.due_days) |d| {
                try w.writer.writeAll(",\"dueDate\":");
                try str(&w.writer, m.date(a, d));
            }
            try w.writer.writeByte('}');
        }
        if (e.on_order > 0) {
            if (e.copies.len > 0) try w.writer.writeByte(',');
            try w.writer.print("\"i{d}\":{{\"collection\":\"On order\",\"branchName\":\"Preservation Central\",\"availability\":{{\"status\":\"ON_ORDER\",\"statusType\":\"ON_ORDER\",\"libraryStatus\":\"{d} on order\",\"group\":\"NOT_AVAILABLE_ITEMS\"}}}}", .{ e.copies.len, e.on_order });
        }
        try w.writer.writeAll("}}}");
        return reply(a, 200, w.written());
    }

    fn detail(m: *Mock, a: Allocator, id: []const u8) !http.Response {
        const e = m.entry(id) orelse return reply(a, 404, "{\"message\":\"Not found\"}");
        const o = e.brief.object;
        var w: std.Io.Writer.Allocating = .init(a);
        try w.writer.writeAll("{\"entities\":{\"catalogBibs\":{");
        try str(&w.writer, id);
        try w.writer.writeAll(":{\"fields\":[{\"items\":[");
        var first = true;
        const rows = [_]struct { name: []const u8, key: []const u8 }{
            .{ .name = "EDITION", .key = "edition" },
            .{ .name = "PUBLICATION_DATE", .key = "publicationDate" },
            .{ .name = "CALL_NUMBER", .key = "callNumber" },
        };
        for (rows) |row| {
            const v = J.of(o.get(row.key) orelse continue).nonEmpty(a) orelse continue;
            if (!first) try w.writer.writeByte(',');
            first = false;
            try w.writer.print("{{\"fieldName\":\"{s}\",\"fieldValues\":[{{\"primary\":{{\"values\":[", .{row.name});
            try str(&w.writer, v);
            try w.writer.writeAll("]}}]}");
        }
        try w.writer.writeAll("]}]}}}}");
        return reply(a, 200, w.written());
    }

    const Kind = enum { holds, checkouts, history };

    fn borrowing(m: *Mock, a: Allocator, req: http.Request, kind: Kind) !http.Response {
        const page_number = @max(1, queryInt(req.url, "page") orelse 1);
        const sort = queryValue(a, req.url, "sort");
        const limit: i64 = 25;

        const Row = struct { index: usize, bib: *Entry };
        var rows: std.ArrayList(Row) = .empty;
        const total: usize = switch (kind) {
            .holds => m.holds.items.len,
            .checkouts => m.checkouts.len,
            .history => if (m.history_enabled) m.history.len else 0,
        };
        for (0..total) |i| {
            const bib_id = switch (kind) {
                .holds => m.holds.items[i].bib,
                .checkouts => m.checkouts[i].bib,
                .history => m.history[i].bib,
            };
            try rows.append(a, .{ .index = i, .bib = m.entry(bib_id) orelse continue });
        }
        const Ctx = struct { m: *Mock, kind: Kind, sort: ?[]const u8 };
        std.mem.sort(Row, rows.items, Ctx{ .m = m, .kind = kind, .sort = sort }, struct {
            fn less(c: Ctx, x: Row, y: Row) bool {
                const s = c.sort orelse switch (c.kind) {
                    .holds => "status",
                    .checkouts => "due_date",
                    .history => "",
                };
                if (std.mem.eql(u8, s, "title")) {
                    const o = std.ascii.orderIgnoreCase(x.bib.title, y.bib.title);
                    if (o != .eq) return o == .lt;
                } else if (std.mem.eql(u8, s, "author")) {
                    const o = std.ascii.orderIgnoreCase(x.bib.author, y.bib.author);
                    if (o != .eq) return o == .lt;
                } else if (c.kind == .holds and std.mem.eql(u8, s, "status")) {
                    const hx = c.m.holds.items[x.index];
                    const hy = c.m.holds.items[y.index];
                    const rx = holdRank(hx.status);
                    const ry = holdRank(hy.status);
                    if (rx != ry) return rx < ry;
                    if (hx.position != hy.position) return hx.position < hy.position;
                } else if (c.kind == .checkouts and std.mem.eql(u8, s, "due_date")) {
                    const dx = c.m.checkouts[x.index].due_days;
                    const dy = c.m.checkouts[y.index].due_days;
                    if (dx != dy) return dx < dy;
                } else if (c.kind == .history) {
                    const rx = c.m.history[x.index].returned_days;
                    const ry = c.m.history[y.index].returned_days;
                    if (rx != ry) return rx < ry;
                }
                return x.index < y.index;
            }
        }.less);

        const count: i64 = @intCast(rows.items.len);
        const pages = @max(1, @divTrunc(count + limit - 1, limit));
        const start: usize = @intCast(@min(count, (page_number - 1) * limit));
        const end: usize = @intCast(@min(count, page_number * limit));
        const shown = rows.items[start..end];

        const list_key = switch (kind) {
            .holds => "holds",
            .checkouts => "checkouts",
            .history => "borrowinghistory",
        };
        const entity_key = switch (kind) {
            .holds => "holds",
            .checkouts => "checkouts",
            .history => "borrowingHistory",
        };
        const sort_ids: []const []const u8 = switch (kind) {
            .holds => &.{ "status", "title", "author" },
            .checkouts => &.{ "due_date", "title", "author" },
            .history => &.{},
        };
        const applied = sort orelse if (sort_ids.len > 0) sort_ids[0] else "";

        var w: std.Io.Writer.Allocating = .init(a);
        try w.writer.print("{{\"borrowing\":{{\"{s}\":{{\"items\":[", .{list_key});
        for (shown, 0..) |r, i| {
            if (i > 0) try w.writer.writeByte(',');
            try w.writer.print("\"{s}{d}\"", .{ entity_key[0..1], r.index });
        }
        try w.writer.print("],\"pagination\":{{\"page\":{d},\"pages\":{d},\"count\":{d},\"limit\":{d}}},\"sortOptions\":[", .{ page_number, pages, count, limit });
        for (sort_ids, 0..) |s, i| {
            if (i > 0) try w.writer.writeByte(',');
            try w.writer.print("{{\"id\":\"{s}\"{s}}}", .{ s, if (std.mem.eql(u8, s, applied)) ",\"applied\":true" else "" });
        }
        try w.writer.print("]}}}},\"entities\":{{\"{s}\":{{", .{entity_key});
        for (shown, 0..) |r, i| {
            if (i > 0) try w.writer.writeByte(',');
            try w.writer.print("\"{s}{d}\":", .{ entity_key[0..1], r.index });
            switch (kind) {
                .holds => try m.writeHold(a, &w.writer, m.holds.items[r.index]),
                .checkouts => try m.writeCheckout(a, &w.writer, r.index, m.checkouts[r.index]),
                .history => {
                    const h = m.history[r.index];
                    try w.writer.print("{{\"borrowingHistoryId\":\"B{d}\",\"metadataId\":", .{r.index + 1});
                    try str(&w.writer, h.bib);
                    try w.writer.writeAll(",\"checkedoutDate\":");
                    try str(&w.writer, m.date(a, -h.out_days));
                    try w.writer.writeAll(",\"returnedDate\":");
                    try str(&w.writer, m.date(a, -h.returned_days));
                    try w.writer.writeByte('}');
                },
            }
        }
        try w.writer.writeAll("},\"bibs\":{");
        for (shown, 0..) |r, i| {
            if (i > 0) try w.writer.writeByte(',');
            try m.writeBib(&w.writer, r.bib.*);
        }
        try w.writer.writeAll("}}}");
        return reply(a, 200, w.written());
    }

    fn holdRank(status: []const u8) u8 {
        if (std.mem.eql(u8, status, "READY_FOR_PICKUP")) return 0;
        if (std.mem.eql(u8, status, "IN_TRANSIT")) return 1;
        return 2;
    }

    fn placeHold(m: *Mock, a: Allocator, req: http.Request) !http.Response {
        const body = json.parse(a, req.body orelse "");
        const id = body.get("metadataId").str(a) orelse "";
        const e = m.entry(id) orelse return reply(a, 200, "{\"failures\":[{\"message\":\"This item can’t be found.\"}]}");
        for (m.holds.items) |h| if (std.mem.eql(u8, h.bib, id)) {
            return reply(a, 200, "{\"failures\":[{\"message\":\"You already have a hold on this item.\"}]}");
        };
        const branch = body.path("materialParams.branchId").str(a) orelse m.pickup;
        e.held += 1;
        try m.holds.append(m.arena.allocator(), .{
            .id = try std.fmt.allocPrint(m.arena.allocator(), "H{d}", .{m.next_hold}),
            .bib = e.id,
            .status = "NOT_YET_AVAILABLE",
            .position = e.held,
            .pickup = m.branchName(branch),
            .pickup_by_days = null,
        });
        m.next_hold += 1;
        return reply(a, 200, "{}");
    }

    fn cancelHolds(m: *Mock, a: Allocator, req: http.Request) !http.Response {
        const body = json.parse(a, req.body orelse "");
        var w: std.Io.Writer.Allocating = .init(a);
        try w.writer.writeAll("{\"failures\":[");
        var first = true;
        for (body.get("holdIds").strings(a)) |id| {
            for (m.holds.items, 0..) |h, i| {
                if (!std.mem.eql(u8, h.id, id)) continue;
                if (std.mem.eql(u8, h.status, "READY_FOR_PICKUP")) {
                    if (!first) try w.writer.writeByte(',');
                    first = false;
                    try w.writer.writeAll("{\"id\":");
                    try str(&w.writer, id);
                    try w.writer.writeAll(",\"message\":\"This hold is ready for pickup and can’t be cancelled online.\"}");
                } else {
                    if (m.entry(h.bib)) |e| e.held = @max(0, e.held - 1);
                    _ = m.holds.orderedRemove(i);
                }
                break;
            }
        }
        try w.writer.writeAll("]}");
        return reply(a, 200, w.written());
    }

    // MARK: Website

    fn website(m: *Mock, a: Allocator, req: http.Request, path: []const u8) !http.Response {
        const lib = m.library;
        if (std.mem.eql(u8, path, "/v2/search")) {
            var w: std.Io.Writer.Allocating = .init(a);
            const name = lib.get("name").str(a) orelse "Library";
            try w.writer.writeAll("<html><head><title>");
            try w.writer.writeAll(name);
            try w.writer.writeAll("</title></head><body><script type=\"application/json\">{\"branding\":{\"primaryBrandColor\":");
            try str(&w.writer, lib.get("color").str(a) orelse "#2f5d9e");
            try w.writer.writeAll("},\"entities\":{\"libraries\":{\"1\":{\"fullName\":");
            try str(&w.writer, name);
            try w.writer.writeAll(",\"shortName\":");
            try str(&w.writer, lib.get("shortName").str(a) orelse name);
            try w.writer.writeAll(",\"homeLink\":");
            try str(&w.writer, lib.get("website").str(a) orelse "");
            try w.writer.writeAll("}}},\"localization\":{\"messages\":{");
            var first = true;
            if (lib.get("labels").object()) |o| {
                var it = o.iterator();
                while (it.next()) |e| {
                    if (!first) try w.writer.writeByte(',');
                    first = false;
                    try str(&w.writer, e.key_ptr.*);
                    try w.writer.writeByte(':');
                    try std.json.Stringify.value(e.value_ptr.*, .{}, &w.writer);
                }
            }
            try w.writer.writeAll("},\"availableLanguages\":");
            try w.writer.writeByte('[');
            for (lib.get("languages").strings(a), 0..) |code, i| {
                if (i > 0) try w.writer.writeByte(',');
                try str(&w.writer, code);
            }
            try w.writer.writeByte(']');
            try w.writer.writeAll("}}</script></body></html>");
            return page(a, w.written());
        }
        const post = std.mem.eql(u8, req.method, "POST");
        if (std.mem.eql(u8, path, "/account/email")) return m.form(a, "/account/contact_information", try std.fmt.allocPrint(a, "<input type=\"email\" name=\"user_email\" value=\"{s}\">", .{m.email}));
        if (std.mem.eql(u8, path, "/account/password")) {
            return m.form(a, "/account/change_pin", "<input type=\"password\" name=\"old_password\"><input type=\"password\" name=\"new_password\"><input type=\"password\" name=\"new_password_confirm\">");
        }
        if (std.mem.eql(u8, path, "/account/pickup_location")) {
            var options: std.Io.Writer.Allocating = .init(a);
            try options.writer.writeAll("<select name=\"first_preference\">");
            for (m.branches) |b| {
                try options.writer.print("<option value=\"{s}\"{s}>{s}</option>", .{ b.id, if (std.mem.eql(u8, b.id, m.pickup)) " selected" else "", b.name });
            }
            try options.writer.writeAll("</select><select name=\"second_preference\"><option value=\"\" selected>None</option></select>");
            return m.form(a, "/account/preferred_branches", options.written());
        }
        if (std.mem.eql(u8, path, "/account/language")) {
            var options: std.Io.Writer.Allocating = .init(a);
            try options.writer.writeAll("<select name=\"user_lang\">");
            for (lib.get("languages").strings(a)) |code| {
                try options.writer.print("<option value=\"{s}\"{s}>{s}</option>", .{ code, if (std.mem.eql(u8, code, m.language)) " selected" else "", code });
            }
            try options.writer.writeAll("</select>");
            return m.form(a, "/account/user_lang", options.written());
        }
        if (post) {
            const body = req.body orelse "";
            if (std.mem.eql(u8, path, "/account/contact_information")) {
                if (formField(a, body, "user_email")) |v| m.email = try m.arena.allocator().dupe(u8, v);
                return redirect(a, "/account/email");
            }
            if (std.mem.eql(u8, path, "/account/preferred_branches")) {
                if (formField(a, body, "first_preference")) |v| m.pickup = try m.arena.allocator().dupe(u8, v);
                return redirect(a, "/account/pickup_location");
            }
            if (std.mem.eql(u8, path, "/account/user_lang")) {
                if (formField(a, body, "user_lang")) |v| m.language = try m.arena.allocator().dupe(u8, v);
                return redirect(a, "/account/language");
            }
            if (std.mem.eql(u8, path, "/account/change_pin")) return redirect(a, "/account/password");
        }
        // Anything else on the library's site (its icon, say) is not served.
        return .{ .status = 404, .url = "", .headers = &.{}, .body = "" };
    }

    fn form(m: *Mock, a: Allocator, action: []const u8, fields: []const u8) !http.Response {
        _ = m;
        var w: std.Io.Writer.Allocating = .init(a);
        try w.writer.print("<html><head><title>Account</title></head><body><form action=\"{s}\" method=\"post\"><input type=\"hidden\" name=\"authenticity_token\" value=\"mock\">", .{action});
        try w.writer.writeAll(fields);
        try w.writer.writeAll("<input type=\"submit\" name=\"commit\" value=\"Save\"></form></body></html>");
        return page(a, w.written());
    }

    fn directory(m: *Mock, a: Allocator) !http.Response {
        const lib = m.library;
        var w: std.Io.Writer.Allocating = .init(a);
        try w.writer.writeAll("<html><body>");
        try w.writer.print("<a class=\"library-link w-inline-block\" href=\"{s}\"><img alt=\"{s}\" src=\"\"><div fs-cmsfilter-field=\"Region\">{s}</div></a>", .{
            lib.get("website").str(a) orelse "",
            lib.get("name").str(a) orelse "",
            lib.get("region").str(a) orelse "",
        });
        try w.writer.writeAll("</body></html>");
        return page(a, w.written());
    }
};

// MARK: Helpers

fn contains(shown: []const *Entry, bib: []const u8) bool {
    for (shown) |e| if (std.mem.eql(u8, e.id, bib)) return true;
    return false;
}

fn str(w: *std.Io.Writer, s: []const u8) !void {
    try std.json.Stringify.value(s, .{}, w);
}

/// A query-string value, percent-decoded.
fn queryValue(a: Allocator, url: []const u8, name: []const u8) ?[]const u8 {
    const q = std.mem.findScalar(u8, url, '?') orelse return null;
    var pairs = std.mem.tokenizeScalar(u8, url[q + 1 ..], '&');
    while (pairs.next()) |pair| {
        const eq = std.mem.findScalar(u8, pair, '=') orelse continue;
        if (std.mem.eql(u8, pair[0..eq], name)) return decode(a, pair[eq + 1 ..]);
    }
    return null;
}

fn queryInt(url: []const u8, name: []const u8) ?i64 {
    var buf: [256]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buf);
    const v = queryValue(fba.allocator(), url, name) orelse return null;
    return std.fmt.parseInt(i64, v, 10) catch null;
}

/// One field of a form-encoded body.
fn formField(a: Allocator, body: []const u8, name: []const u8) ?[]const u8 {
    var pairs = std.mem.tokenizeScalar(u8, body, '&');
    while (pairs.next()) |pair| {
        const eq = std.mem.findScalar(u8, pair, '=') orelse continue;
        if (std.mem.eql(u8, pair[0..eq], name)) return decode(a, pair[eq + 1 ..]);
    }
    return null;
}

fn decode(a: Allocator, s: []const u8) []const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        switch (s[i]) {
            '+' => out.append(a, ' ') catch return s,
            '%' => {
                if (i + 2 < s.len) {
                    if (std.fmt.parseInt(u8, s[i + 1 .. i + 3], 16)) |byte| {
                        out.append(a, byte) catch return s;
                        i += 2;
                        continue;
                    } else |_| {}
                }
                out.append(a, '%') catch return s;
            },
            else => out.append(a, s[i]) catch return s,
        }
    }
    return out.items;
}

fn readJson(a: Allocator, dir: []const u8, name: []const u8) !J {
    const path = try std.fmt.allocPrintSentinel(a, "{s}/{s}", .{ dir, name }, 0);
    const file = std.c.fopen(path, "rb") orelse return error.FileNotFound;
    defer _ = std.c.fclose(file);
    var data: std.ArrayList(u8) = .empty;
    var buf: [16 * 1024]u8 = undefined;
    while (true) {
        const n = std.c.fread(&buf, 1, buf.len, file);
        if (n == 0) break;
        try data.appendSlice(a, buf[0..n]);
    }
    const value = try std.json.parseFromSliceLeaky(Value, a, data.items, .{});
    return J.of(value);
}

test "mock library serves search, holds, and settings" {
    if (!available) return error.SkipZigTest;
    const m = Mock.load("mock/video") catch return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const search = (try m.route(a, .{
        .method = "POST",
        .url = "https://gateway.bibliocommons.com/v2/libraries/firstlanding/bibs/search",
        .body = "{\"query\":\"dune\",\"searchType\":\"smart\",\"page\":1}",
    })).?;
    const results = json.parse(a, search.body);
    try std.testing.expect(results.path("catalogSearch.results").items().len > 0);
    try std.testing.expectEqualStrings("BLURAY", results.path("catalogSearch.fields").at(0).get("fieldFilters").at(0).get("value").str(a).?);

    // A ready hold can't be cancelled; a waiting one can.
    var ready: ?[]const u8 = null;
    var waiting: ?[]const u8 = null;
    for (m.holds.items) |h| {
        if (std.mem.eql(u8, h.status, "READY_FOR_PICKUP")) ready = h.id else if (std.mem.eql(u8, h.status, "NOT_YET_AVAILABLE")) waiting = h.id;
    }
    const body = try std.fmt.allocPrint(a, "{{\"holdIds\":[\"{s}\",\"{s}\"]}}", .{ ready.?, waiting.? });
    const before = m.holds.items.len;
    const cancelled = (try m.route(a, .{ .method = "DELETE", .url = "https://gateway.bibliocommons.com/v2/libraries/firstlanding/holds", .body = body })).?;
    try std.testing.expectEqual(before - 1, m.holds.items.len);
    try std.testing.expectEqual(@as(usize, 1), json.parse(a, cancelled.body).get("failures").items().len);

    // Other libraries go to the real transport.
    try std.testing.expect((try m.route(a, .{ .method = "GET", .url = "https://gateway.bibliocommons.com/v2/libraries/wccls/locations" })) == null);
}
