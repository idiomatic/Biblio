//! End-to-end tests of the client against canned responses shaped like the gateway's and the
//! library website's, so parsing changes can be checked without contacting a library.

const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const Io = std.Io;
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
    threaded: Io.Threaded,
    throttle: http.Throttle = .{},
    fake: Fake,
    arena: std.heap.ArenaAllocator,
};

fn makeClient(s: *Setup, username: []const u8) !*Client {
    return Client.create(testing.allocator, s.threaded.io(), s.fake.transport(), &s.throttle, "wccls", username, password, null);
}

fn result(a: Allocator, c: *Client, request: []const u8) !json.J {
    const out = root.call(a, c, request);
    const j = json.parse(a, out);
    if (j.get("ok").boolean() != true) {
        std.debug.print("call failed: {s}\n", .{out});
        return error.CallFailed;
    }
    return j.get("result");
}

test "login, search and account status" {
    var s: Setup = .{ .threaded = .init_single_threaded, .fake = .{ .gpa = testing.allocator }, .arena = .init(testing.allocator) };
    defer s.fake.deinit();
    defer s.arena.deinit();
    const a = s.arena.allocator();
    const c = try makeClient(&s, "pat");
    defer c.destroy();

    const patron = try result(a, c, "{\"op\":\"login\"}");
    try testing.expectEqualStrings("Pat Reader", patron.get("name").str(a).?);
    try testing.expectEqual(@as(?i64, 7), patron.get("accountId").int());
    try testing.expectEqualStrings("BEA", patron.get("preferredPickup").str(a).?);

    const page = try result(a, c, "{\"op\":\"search\",\"query\":\"dune\",\"filters\":{\"f_AUDIENCE\":\"adult\"},\"format\":\"BK\"}");
    try testing.expectEqual(@as(usize, 2), page.get("entries").items().len);
    const dune = page.get("entries").at(0);
    try testing.expectEqualStrings("Dune", dune.path("bib.title").str(a).?);
    try testing.expectEqualStrings("https://img/s.jpg", dune.path("bib.jacketSmall").str(a).?);
    // Held through another edition of the same title.
    try testing.expectEqualStrings("onHold", dune.path("accountStatus.kind").str(a).?);
    try testing.expectEqualStrings("H1", dune.path("hold.id").str(a).?);
    try testing.expectEqualStrings("Untitled", page.get("entries").at(1).path("bib.title").str(a).?);
    try testing.expectEqual(@as(?i64, 60), page.get("count").int());
    try testing.expectEqualStrings("relevancy", page.get("appliedSort").str(a).?);
    try testing.expectEqualStrings("UK", page.get("facets").at(0).get("values").at(1).get("value").str(a).?);

    // The search body carries the filters, format and locale.
    const body = json.parse(a, s.fake.bodies.items[1]);
    try testing.expectEqualStrings("adult", body.get("f_AUDIENCE").str(a).?);
    try testing.expectEqualStrings("BK", body.get("f_FORMAT").str(a).?);
    try testing.expectEqualStrings("en-US", body.get("locale").str(a).?);
}

test "guests can search but not see holds" {
    var s: Setup = .{ .threaded = .init_single_threaded, .fake = .{ .gpa = testing.allocator }, .arena = .init(testing.allocator) };
    defer s.fake.deinit();
    defer s.arena.deinit();
    const a = s.arena.allocator();
    const c = try makeClient(&s, "");
    defer c.destroy();
    _ = try result(a, c, "{\"op\":\"search\",\"query\":\"dune\"}");
    try testing.expectEqual(@as(u32, 0), s.fake.logins);
    const out = json.parse(a, root.call(a, c, "{\"op\":\"holds\"}"));
    try testing.expectEqualStrings("signInRequired", out.path("error.kind").str(a).?);
}

test "holds, expiry and re-login" {
    var s: Setup = .{ .threaded = .init_single_threaded, .fake = .{ .gpa = testing.allocator }, .arena = .init(testing.allocator) };
    defer s.fake.deinit();
    defer s.arena.deinit();
    const a = s.arena.allocator();
    const c = try makeClient(&s, "pat");
    defer c.destroy();
    _ = try result(a, c, "{\"op\":\"login\"}");
    s.fake.sessions_valid = false;
    const page = try result(a, c, "{\"op\":\"holds\",\"page\":1}");
    try testing.expectEqual(@as(u32, 2), s.fake.logins);
    const entries = page.get("entries").items();
    try testing.expectEqual(@as(usize, 2), entries.len);
    const old = json.J.of(entries[0]);
    try testing.expectEqualStrings("hold-H2", old.get("id").str(a).?);
    try testing.expectEqualStrings("Old Record", old.path("bib.title").str(a).?);
    try testing.expectEqual(@as(?i64, 5), old.path("hold.position").int());
    const ready = json.J.of(entries[1]);
    try testing.expectEqual(@as(?bool, true), ready.path("accountStatus.ready").boolean());
    try testing.expect(ready.path("hold.position").isNull());
    try testing.expectEqualStrings("Beaverton", ready.path("hold.pickupLocation").str(a).?);
    try testing.expectEqualStrings("status", page.get("sortOptions").at(0).str(a).?);
    try testing.expectEqualStrings("title", page.get("sortOptions").at(1).str(a).?);

    const cancel = try result(a, c, "{\"op\":\"cancelHolds\",\"holds\":[{\"id\":\"H1\",\"metadataId\":\"S1C2\"},{\"id\":\"H2\",\"metadataId\":\"S9\"}]}");
    try testing.expectEqual(@as(usize, 1), cancel.get("refused").items().len);
    try testing.expectEqualStrings("H1", cancel.get("refused").at(0).get("holdId").str(a).?);
    const del = json.parse(a, s.fake.bodies.items[s.fake.bodies.items.len - 1]);
    try testing.expectEqualStrings("H2", del.get("holdIds").at(1).str(a).?);

    const hold = json.parse(a, root.call(a, c, "{\"op\":\"placeHold\",\"metadataId\":\"S1C9\",\"materialType\":\"PHYSICAL\"}"));
    try testing.expectEqualStrings("You have reached the maximum number of holds.", hold.path("error.message").str(a).?);
    const place = json.parse(a, s.fake.bodies.items[s.fake.bodies.items.len - 1]);
    try testing.expectEqualStrings("BEA", place.path("materialParams.branchId").str(a).?);
}

test "availability sorts available copies first" {
    var s: Setup = .{ .threaded = .init_single_threaded, .fake = .{ .gpa = testing.allocator }, .arena = .init(testing.allocator) };
    defer s.fake.deinit();
    defer s.arena.deinit();
    const a = s.arena.allocator();
    const c = try makeClient(&s, "");
    defer c.destroy();
    const copies = try result(a, c, "{\"op\":\"availability\",\"metadataId\":\"S1C1\"}");
    try testing.expectEqualStrings("Tigard", copies.at(0).get("branch").str(a).?);
    try testing.expectEqualStrings("Aloha", copies.at(1).get("branch").str(a).?);
    try testing.expectEqual(@as(?bool, true), copies.at(1).get("isOnOrder").boolean());
    try testing.expectEqualStrings("Checked out", copies.at(2).get("status").str(a).?);
}

test "account form submission keeps cookies and clears duplicate preferences" {
    var s: Setup = .{ .threaded = .init_single_threaded, .fake = .{ .gpa = testing.allocator }, .arena = .init(testing.allocator) };
    defer s.fake.deinit();
    defer s.arena.deinit();
    const a = s.arena.allocator();
    const c = try makeClient(&s, "pat");
    defer c.destroy();
    const settings = try result(a, c, "{\"op\":\"accountSettings\"}");
    try testing.expectEqualStrings("BEA", settings.get("pickup").str(a).?);
    _ = try result(a, c, "{\"op\":\"setPickup\",\"branchId\":\"TIG\"}");
    var posted: ?[]const u8 = null;
    for (s.fake.sent.items, 0..) |line, i| {
        if (std.mem.startsWith(u8, line, "POST https://wccls.bibliocommons.com/account/preferred_branches")) posted = s.fake.bodies.items[i];
    }
    try testing.expect(std.mem.find(u8, posted.?, "first_preference=TIG") != null);
    try testing.expect(std.mem.find(u8, posted.?, "second_preference=&") != null);
    try testing.expect(std.mem.find(u8, posted.?, "authenticity_token=tok") != null);
    const patron = try result(a, c, "{\"op\":\"patron\"}");
    try testing.expectEqualStrings("TIG", patron.get("preferredPickup").str(a).?);
}

test "library helpers without a client" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const sub = json.parse(a, root.call(a, null, "{\"op\":\"subdomainFrom\",\"input\":\"https://smpl.bibliocommons.com\"}"));
    try testing.expectEqualStrings("smpl", sub.get("result").str(a).?);
    const name = json.parse(a, root.call(a, null, "{\"op\":\"formatName\",\"code\":\"UK\"}"));
    try testing.expectEqualStrings("4K Ultra HD Blu-ray", name.get("result").str(a).?);
    const bad = json.parse(a, root.call(a, null, "{\"op\":\"nope\"}"));
    try testing.expectEqualStrings("badRequest", bad.path("error.kind").str(a).?);
}
