//! biblio: a command-line front end to libbiblio, for testing the core against a live library
//! sparingly. Each invocation is one or two requests.
//!
//!   biblio call '{"op":"libraryInfo","subdomain":"wccls"}'
//!   biblio search wccls "dune"
//!   biblio --user NAME call wccls '{"op":"holds"}'   (password from $BIBLIO_PASSWORD)

const std = @import("std");
const biblio = @import("biblio");

extern fn biblio_client_new(subdomain: [*:0]const u8, username: [*:0]const u8, password: *const fn (?*anyopaque, [*:0]const u8, [*:0]const u8) callconv(.c) ?[*:0]u8, ctx: ?*anyopaque) ?*anyopaque;
extern fn biblio_client_free(client: ?*anyopaque) void;
extern fn biblio_call(client: ?*anyopaque, request: [*:0]const u8) ?[*:0]u8;
extern fn biblio_alloc(len: usize) ?[*]u8;
extern fn biblio_free(ptr: ?*anyopaque) void;

var password_env: ?[]const u8 = null;

fn password(_: ?*anyopaque, _: [*:0]const u8, _: [*:0]const u8) callconv(.c) ?[*:0]u8 {
    const p = password_env orelse return null;
    const out = biblio_alloc(p.len + 1) orelse return null;
    @memcpy(out[0..p.len], p);
    out[p.len] = 0;
    return @ptrCast(out);
}

pub fn main(init: std.process.Init) !void {
    const a = init.arena.allocator();
    const args = try init.minimal.args.toSlice(a);
    password_env = init.environ_map.get("BIBLIO_PASSWORD");

    var user: []const u8 = "";
    var rest: std.ArrayList([]const u8) = .empty;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--user") and i + 1 < args.len) {
            i += 1;
            user = args[i];
        } else try rest.append(a, args[i]);
    }
    const r = rest.items;

    var stdout_buf: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(init.io, &stdout_buf);
    defer stdout.interface.flush() catch {};

    if (r.len == 2 and std.mem.eql(u8, r[0], "call")) {
        try print(&stdout.interface, null, r[1]);
    } else if (r.len == 3 and std.mem.eql(u8, r[0], "call")) {
        const client = biblio_client_new(try a.dupeSentinel(u8, r[1], 0), try a.dupeSentinel(u8, user, 0), password, null);
        defer biblio_client_free(client);
        try print(&stdout.interface, client, r[2]);
    } else if (r.len == 3 and std.mem.eql(u8, r[0], "search")) {
        const client = biblio_client_new(try a.dupeSentinel(u8, r[1], 0), try a.dupeSentinel(u8, user, 0), password, null);
        defer biblio_client_free(client);
        const req = try std.json.Stringify.valueAlloc(a, .{ .op = "search", .query = r[2] }, .{});
        try print(&stdout.interface, client, req);
    } else {
        try stdout.interface.writeAll(
            \\usage: biblio [--user NAME] call [SUBDOMAIN] JSON
            \\       biblio [--user NAME] search SUBDOMAIN TEXT
            \\The password for --user comes from $BIBLIO_PASSWORD.
            \\
        );
    }
}

fn print(w: *std.Io.Writer, client: ?*anyopaque, request: []const u8) !void {
    var buf: [64 * 1024]u8 = undefined;
    if (request.len >= buf.len) return error.RequestTooLong;
    @memcpy(buf[0..request.len], request);
    buf[request.len] = 0;
    const out = biblio_call(client, @ptrCast(&buf)) orelse return error.OutOfMemory;
    defer biblio_free(out);
    try w.writeAll(std.mem.span(out));
    try w.writeAll("\n");
}

comptime {
    _ = biblio;
}
