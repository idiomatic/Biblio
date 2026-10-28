//! biblio: a command-line front end to libbiblio, for testing the core against a live library
//! sparingly. Each invocation is one or two requests; results print as JSON.
//!
//!   biblio info wccls
//!   biblio search wccls "dune"
//!   biblio --user NAME holds wccls   (password from $BIBLIO_PASSWORD)

const std = @import("std");
const biblio = @import("biblio");

var password_env: ?[]const u8 = null;

fn password(_: ?*anyopaque, _: [*:0]const u8, _: [*:0]const u8) callconv(.c) ?[*:0]u8 {
    const p = password_env orelse return null;
    const out = biblio.biblio_alloc(p.len + 1) orelse return null;
    @memcpy(out[0..p.len], p);
    out[p.len] = 0;
    return @ptrCast(out);
}

const usage =
    \\usage: biblio info SUBDOMAIN
    \\       biblio search SUBDOMAIN TEXT
    \\       biblio availability SUBDOMAIN METADATA_ID
    \\       biblio --user NAME (holds | checkouts | history) SUBDOMAIN
    \\The password for --user comes from $BIBLIO_PASSWORD.
    \\
;

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
    // Streaming, not positional: output appended to a file or pipe must not overwrite earlier output.
    var stdout = std.Io.File.stdout().writerStreaming(init.io, &stdout_buf);
    const w = &stdout.interface;
    defer w.flush() catch {};

    if (r.len < 2) return w.writeAll(usage);
    const command = r[0];
    if (std.mem.eql(u8, command, "info")) {
        var message: []const u8 = "";
        const info = biblio.lookup().info(a, r[1], &message) catch return show(w, .{ .@"error" = message });
        return show(w, info);
    }

    const h = biblio.biblio_client_new(try a.dupeSentinel(u8, r[1], 0), try a.dupeSentinel(u8, user, 0), password, null) orelse
        return error.OutOfMemory;
    defer biblio.biblio_client_free(h);
    const c = h.client;
    var failure: biblio.Failure = undefined;
    const kind = std.meta.stringToEnum(enum { search, availability, holds, checkouts, history }, command) orelse return w.writeAll(usage);
    if ((kind == .search or kind == .availability) and r.len < 3) return w.writeAll(usage);
    switch (kind) {
        .search => try show(w, c.search(a, .{ .query = r[2] }, &failure) catch return show(w, failure)),
        .availability => try show(w, c.availability(a, r[2], &failure) catch return show(w, failure)),
        .holds => try show(w, c.borrowing(a, .holds, 1, null, &failure) catch return show(w, failure)),
        .checkouts => try show(w, c.borrowing(a, .checkouts, 1, null, &failure) catch return show(w, failure)),
        .history => try show(w, c.borrowing(a, .history, 1, null, &failure) catch return show(w, failure)),
    }
}

fn show(w: *std.Io.Writer, value: anytype) !void {
    try std.json.Stringify.value(value, .{ .whitespace = .indent_2, .emit_null_optional_fields = false }, w);
    try w.writeAll("\n");
}
