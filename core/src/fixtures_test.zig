//! End-to-end tests of the client against canned responses shaped like the gateway's and the
//! library website's, so parsing changes can be checked without contacting a library.

const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const http = @import("http.zig");
const root = @import("root.zig");
const Client = @import("client.zig").Client;
const json = @import("json.zig");

const login_json =
    \\{"auth":{"sessionId":"S1","authToken":"T1","currentUserId":42},
    \\ "entities":{"users":{"42":{"name":"Pat Reader","accounts":[7],"userContact":{"email":"pat@example.com"},"preferences":{"language":"en-US"}}},
    \\  "accounts":{"7":{"barcode":"21168000000001","preferredLocations":["BEA"],"borrowingHistoryEnabled":true}}}}
;

const search_json =
    \\{"catalogSearch":{"results":[{"representative":"S1C1","manifestations":["S1C2"]},{"representative":"S1C9"},{"representative":"MISSING"}],
    \\  "pagination":{"page":1,"pages":3,"count":60,"limit":25},
    \\  "fields":[{"id":"FORMAT","fieldFilters":[{"value":"BK","count":40},{"value":"UK","count":2}]}],
    \\  "sortBys":[{"id":"relevancy","applied":true},{"id":"newly_acquired"}]},
    \\ "entities":{"bibs":{
    \\   "S1C1":{"id":"S1C1","briefInfo":{"title":"Dune","subtitle":"Deluxe","authors":["Herbert, Frank"],"format":"BK","publicationDate":"2019","jacket":{"small":"https://img/s.jpg","large":"https://img/l.jpg"}},
    \\           "policy":{"materialType":"PHYSICAL","holdable":true},"availability":{"status":"AVAILABLE","heldCopies":3,"availableCopies":1,"totalCopies":9}},
    \\   "S1C9":{"id":"S1C9","briefInfo":{"title":"  ","format":"UK"},"availability":{"status":"ON_ORDER","onOrderCopies":4}}},
    \\  "holds":{"h1":{"holdsId":"H1","metadataId":"S1C2","status":"IN_TRANSIT","holdsPosition":2,"actions":["cancel"]}}}}
;

const holds_json =
    \\{"borrowing":{"holds":{"items":["h2","h1"],"pagination":{"page":1,"pages":1,"count":2,"limit":25},"sortOptions":[{"id":"status","applied":true},"title"]}},
    \\ "entities":{"holds":{
    \\   "h1":{"holdsId":"H1","metadataId":"S1C2","status":"READY_FOR_PICKUP","holdsPosition":0,"pickupLocation":{"name":"Beaverton"},"pickupByDate":"2026-11-01","actions":["cancel"]},
    \\   "h2":{"holdsId":"H2","metadataId":"S9","bibTitle":"Old Record","status":"NOT_YET_AVAILABLE","holdsPosition":5}},
    \\  "bibs":{"S1C2":{"id":"S1C2","briefInfo":{"title":"Dune","format":"BK"}}}}}
;

const availability_json =
    \\{"availability":{"items":["i2","i1","i3"]},
    \\ "entities":{"bibItems":{
    \\   "i1":{"branchName":"Tigard","callNumber":"SF HER","availability":{"statusType":"AVAILABLE","libraryStatus":"Available"}},
    \\   "i2":{"branch":{"name":"Beaverton"},"availability":{"status":"CHECKED_OUT"},"dueDate":"2026-11-03"},
    \\   "i3":{"branchName":"Aloha","availability":{"libraryStatus":"5 on order"}}}}}
;

const pickup_page =
    \\<html><title>Pickup</title><form action="/account/preferred_branches" method="post">
    \\<input type="hidden" name="authenticity_token" value="tok">
    \\<select name="first_preference"><option value="BEA" selected>Beaverton</option><option value="TIG">Tigard</option></select>
    \\<select name="second_preference"><option value="">None</option><option value="TIG" selected>Tigard</option></select>
    \\<input type="submit" name="commit" value="Save"></form>
    \\<form action="/account/contact_information" method="post"><input type="email" name="user_email" value="pat@example.com"></form>
    \\<form action="/account/user_lang" method="post"><select name="user_lang"><option value="en-US" selected>English</option></select></form></html>
;

/// Serves canned responses by method and path, and records what was sent.
const Fake = struct {
    gpa: Allocator,
    sent: std.ArrayList([]const u8) = .empty,
    bodies: std.ArrayList([]const u8) = .empty,
    sessions_valid: bool = true,
    logins: u32 = 0,

    fn deinit(f: *Fake) void {
        for (f.sent.items) |s| f.gpa.free(s);
        for (f.bodies.items) |s| f.gpa.free(s);
        f.sent.deinit(f.gpa);
        f.bodies.deinit(f.gpa);
    }

    fn transport(f: *Fake) http.Transport {
        return .{ .ctx = f, .sendFn = send };
    }

    fn send(ctx: ?*anyopaque, a: Allocator, req: http.Request) anyerror!http.Response {
        const f: *Fake = @ptrCast(@alignCast(ctx.?));
        try f.sent.append(f.gpa, try std.fmt.allocPrint(f.gpa, "{s} {s}", .{ req.method, req.url }));
        try f.bodies.append(f.gpa, try f.gpa.dupe(u8, req.body orelse ""));
        const path = @import("html.zig").urlPath(req.url);
        const ok = struct {
            fn r(body: []const u8) http.Response {
                return .{ .status = 200, .url = "", .headers = &.{}, .body = body };
            }
        }.r;
        if (std.mem.endsWith(u8, path, "/sessions")) {
            f.logins += 1;
            f.sessions_valid = true;
            return .{ .status = 200, .url = "", .headers = &.{.{ .name = "Set-Cookie", .value = "session_id=abc; Domain=.bibliocommons.com" }}, .body = login_json };
        }
        if (std.mem.find(u8, path, "/account/") != null and std.mem.eql(u8, req.method, "GET")) {
            var has_cookie = false;
            for (req.headers) |h| if (std.mem.eql(u8, h.name, "Cookie") and std.mem.find(u8, h.value, "session_id=abc") != null) {
                has_cookie = true;
            };
            if (!has_cookie) return .{ .status = 302, .url = "", .headers = &.{.{ .name = "Location", .value = "/user/login" }}, .body = "" };
            return ok(pickup_page);
        }
        if (std.mem.eql(u8, path, "/account/preferred_branches")) {
            return .{ .status = 302, .url = "", .headers = &.{.{ .name = "Location", .value = "/account/pickup_location" }}, .body = "" };
        }
        if (std.mem.eql(u8, path, "/user/login")) return ok("<title>Log In</title>");
        if (!f.sessions_valid) return .{ .status = 401, .url = "", .headers = &.{}, .body = "{\"error\":{\"message\":\"Session expired\"}}" };
        if (std.mem.endsWith(u8, path, "/bibs/search")) return ok(search_json);
        if (std.mem.endsWith(u8, path, "/availability")) return ok(availability_json);
        if (std.mem.endsWith(u8, path, "/holds") and std.mem.eql(u8, req.method, "GET")) return ok(holds_json);
        if (std.mem.endsWith(u8, path, "/holds") and std.mem.eql(u8, req.method, "DELETE")) {
            return ok("{\"failures\":[{\"id\":\"H1\",\"message\":\"Ready holds can't be cancelled.\"}]}");
        }
        if (std.mem.endsWith(u8, path, "/holds") and std.mem.eql(u8, req.method, "POST")) {
            return ok("{\"failures\":[{\"message\":\"You have reached the maximum number of holds.\"}]}");
        }
        _ = a;
        return .{ .status = 404, .url = "", .headers = &.{}, .body = "{\"message\":\"Not here\"}" };
    }
};

fn password(_: ?*anyopaque, _: []const u8, _: []const u8, _: Allocator) ?[]const u8 {
    return "1234";
}

const Setup = struct {
    throttle: http.Throttle = .{},
    fake: Fake,
    arena: std.heap.ArenaAllocator,
};

fn makeClient(s: *Setup, username: []const u8) !*Client {
    return Client.create(testing.allocator, s.fake.transport(), &s.throttle, "wccls", username, password, null);
}

var failure: @import("client.zig").Failure = undefined;

test "login, search and account status" {
    var s: Setup = .{ .fake = .{ .gpa = testing.allocator }, .arena = .init(testing.allocator) };
    defer s.fake.deinit();
    defer s.arena.deinit();
    const a = s.arena.allocator();
    const c = try makeClient(&s, "pat");
    defer c.destroy();

    const patron = try c.login(a, false, &failure);
    try testing.expectEqualStrings("Pat Reader", patron.name);
    try testing.expectEqual(@as(i64, 7), patron.accountId);
    try testing.expectEqualStrings("BEA", patron.preferredPickup.?);

    var filters: std.json.ArrayHashMap([]const u8) = .{};
    try filters.map.put(a, "f_AUDIENCE", "adult");
    const page = try c.search(a, .{ .query = "dune", .filters = filters, .format = "BK" }, &failure);
    try testing.expectEqual(@as(usize, 2), page.entries.len);
    const dune = page.entries[0];
    try testing.expectEqualStrings("Dune", dune.bib.title);
    try testing.expectEqualStrings("https://img/s.jpg", dune.bib.jacketSmall.?);
    // Held through another edition of the same title.
    try testing.expectEqualStrings("onHold", dune.accountStatus.?.kind);
    try testing.expectEqualStrings("H1", dune.hold.?.id);
    try testing.expectEqualStrings("Untitled", page.entries[1].bib.title);
    try testing.expectEqual(@as(i64, 60), page.count);
    try testing.expectEqualStrings("relevancy", page.appliedSort.?);
    try testing.expectEqualStrings("UK", page.facets[0].values[1].value);

    // The search body carries the filters, format and locale.
    const body = json.parse(a, s.fake.bodies.items[1]);
    try testing.expectEqualStrings("adult", body.get("f_AUDIENCE").str(a).?);
    try testing.expectEqualStrings("BK", body.get("f_FORMAT").str(a).?);
    try testing.expectEqualStrings("en-US", body.get("locale").str(a).?);
}

test "guests can search but not see holds" {
    var s: Setup = .{ .fake = .{ .gpa = testing.allocator }, .arena = .init(testing.allocator) };
    defer s.fake.deinit();
    defer s.arena.deinit();
    const a = s.arena.allocator();
    const c = try makeClient(&s, "");
    defer c.destroy();
    _ = try c.search(a, .{ .query = "dune" }, &failure);
    try testing.expectEqual(@as(u32, 0), s.fake.logins);
    try testing.expectError(error.SignInRequired, c.borrowing(a, .holds, 1, null, &failure));
    try testing.expectEqualStrings("signInRequired", failure.kind);
}

test "holds, expiry and re-login" {
    var s: Setup = .{ .fake = .{ .gpa = testing.allocator }, .arena = .init(testing.allocator) };
    defer s.fake.deinit();
    defer s.arena.deinit();
    const a = s.arena.allocator();
    const c = try makeClient(&s, "pat");
    defer c.destroy();
    _ = try c.login(a, false, &failure);
    s.fake.sessions_valid = false;
    const page = try c.borrowing(a, .holds, 1, null, &failure);
    try testing.expectEqual(@as(u32, 2), s.fake.logins);
    try testing.expectEqual(@as(usize, 2), page.entries.len);
    const old = page.entries[0];
    try testing.expectEqualStrings("hold-H2", old.id);
    try testing.expectEqualStrings("Old Record", old.bib.title);
    try testing.expectEqual(@as(?i64, 5), old.hold.?.position);
    const ready = page.entries[1];
    try testing.expect(ready.accountStatus.?.ready);
    try testing.expect(ready.hold.?.position == null);
    try testing.expectEqualStrings("Beaverton", ready.hold.?.pickupLocation.?);
    try testing.expectEqualStrings("status", page.sortOptions[0]);
    try testing.expectEqualStrings("title", page.sortOptions[1]);

    const refused = try c.cancelHolds(a, &.{ .{ .id = "H1", .metadataId = "S1C2" }, .{ .id = "H2", .metadataId = "S9" } }, &failure);
    try testing.expectEqual(@as(usize, 1), refused.len);
    try testing.expectEqualStrings("H1", refused[0].holdId);
    const del = json.parse(a, s.fake.bodies.items[s.fake.bodies.items.len - 1]);
    try testing.expectEqualStrings("H2", del.get("holdIds").at(1).str(a).?);

    try testing.expectError(error.Unexpected, c.placeHold(a, "S1C9", "PHYSICAL", null, &failure));
    try testing.expectEqualStrings("You have reached the maximum number of holds.", failure.message);
    const place = json.parse(a, s.fake.bodies.items[s.fake.bodies.items.len - 1]);
    try testing.expectEqualStrings("BEA", place.path("materialParams.branchId").str(a).?);
}

test "availability sorts available copies first" {
    var s: Setup = .{ .fake = .{ .gpa = testing.allocator }, .arena = .init(testing.allocator) };
    defer s.fake.deinit();
    defer s.arena.deinit();
    const a = s.arena.allocator();
    const c = try makeClient(&s, "");
    defer c.destroy();
    const copies = try c.availability(a, "S1C1", &failure);
    try testing.expectEqualStrings("Tigard", copies[0].branch);
    try testing.expectEqualStrings("Aloha", copies[1].branch);
    try testing.expect(copies[1].isOnOrder);
    try testing.expectEqualStrings("Checked out", copies[2].status);
}

test "account form submission keeps cookies and clears duplicate preferences" {
    var s: Setup = .{ .fake = .{ .gpa = testing.allocator }, .arena = .init(testing.allocator) };
    defer s.fake.deinit();
    defer s.arena.deinit();
    const a = s.arena.allocator();
    const c = try makeClient(&s, "pat");
    defer c.destroy();
    const settings = try c.accountSettings(a, &failure);
    try testing.expectEqualStrings("BEA", settings.pickup.?);
    try c.setDefaultPickupLocation(a, "TIG", &failure);
    var posted: ?[]const u8 = null;
    for (s.fake.sent.items, 0..) |line, i| {
        if (std.mem.startsWith(u8, line, "POST https://wccls.bibliocommons.com/account/preferred_branches")) posted = s.fake.bodies.items[i];
    }
    try testing.expect(std.mem.find(u8, posted.?, "first_preference=TIG") != null);
    try testing.expect(std.mem.find(u8, posted.?, "second_preference=&") != null);
    try testing.expect(std.mem.find(u8, posted.?, "authenticity_token=tok") != null);
    try testing.expectEqualStrings("TIG", c.currentPatron(a).?.preferredPickup.?);
}

test "typed functions" {
    const capi = root.capi;
    var s: Setup = .{ .fake = .{ .gpa = testing.allocator }, .arena = .init(testing.allocator) };
    defer s.fake.deinit();
    defer s.arena.deinit();
    const a = s.arena.allocator();
    const c = try makeClient(&s, "pat");
    defer c.destroy();
    // A handle around the test client (its password comes from the client, not the bridge).
    var h: root.Handle = .{ .client = c, .bridge = undefined };

    var err: capi.Error = .{};
    var patron: ?*capi.Patron = null;
    try testing.expectEqual(capi.Result.ok, capi.biblio_login(&h, false, &patron, &err));
    defer capi.free(patron);
    try testing.expectEqualStrings("Pat Reader", std.mem.span(patron.?.name));
    try testing.expect(patron.?.has_borrowing_history_enabled and patron.?.borrowing_history_enabled);

    const filters = [_]capi.Pair{.{ .key = "f_AUDIENCE", .value = "adult" }};
    const query: capi.SearchQuery = .{ .query = "dune", .filters = &filters, .filter_count = 1, .format = "BK" };
    var page: ?*capi.ListPage = null;
    try testing.expectEqual(capi.Result.ok, capi.biblio_search(&h, &query, &page, &err));
    defer capi.free(page);
    try testing.expectEqual(@as(usize, 2), page.?.entries_count);
    try testing.expectEqualStrings("onHold", std.mem.span(page.?.entries[0].account_status.?.kind));
    try testing.expectEqualStrings("adult", json.parse(a, s.fake.bodies.items[1]).get("f_AUDIENCE").str(a).?);

    const refs = [_]capi.HoldRef{ .{ .id = "H1", .metadata_id = "S1C2" }, .{ .id = "H2", .metadata_id = "S9" } };
    var refused: ?*capi.RefusalList = null;
    try testing.expectEqual(capi.Result.ok, capi.biblio_cancel_holds(&h, &refs, refs.len, &refused, &err));
    defer capi.free(refused);
    try testing.expectEqual(@as(usize, 1), refused.?.items_count);
    try testing.expectEqualStrings("H1", std.mem.span(refused.?.items[0].hold_id));

    try testing.expectEqual(capi.Result.unexpected, capi.biblio_place_hold(&h, "S1C9", null, null, &err));
    try testing.expectEqualStrings("You have reached the maximum number of holds.", std.mem.span(err.message.?));
    capi.biblio_error_clear(&err);
    try testing.expect(err.message == null);
}
