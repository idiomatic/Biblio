//! libbiblio's C interface: JSON in, JSON out. See include/biblio.h for the contract.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const http = @import("http.zig");
const json = @import("json.zig");
const models = @import("models.zig");
const library = @import("library.zig");
const client_mod = @import("client.zig");
const Client = client_mod.Client;
const Failure = client_mod.Failure;
const J = json.J;

pub const html = @import("html.zig");
/// Locks and the allocator the core uses, for hosts written in Zig.
pub const sync = @import("sync.zig");

test {
    _ = json;
    _ = models;
    _ = html;
    _ = http;
    _ = library;
    _ = client_mod;
    _ = @import("fixtures_test.zig");
}

// MARK: Process-wide state

const gpa = sync.allocator;

/// Without `std.Io` (iOS), panics can't use the standard handler's stderr: log and abort.
pub const panic = if (sync.has_std_io) std.debug.FullPanic(std.debug.defaultPanic) else std.debug.FullPanic(abortPanic);

fn abortPanic(message: []const u8, _: ?usize) noreturn {
    _ = std.c.write(2, "libbiblio panic: ", 17);
    _ = std.c.write(2, message.ptr, message.len);
    _ = std.c.write(2, "\n", 1);
    std.c.abort();
}

var throttle: http.Throttle = .{};
var std_transport: http.StdTransport = undefined;
var host_transport: ?HostTransport = null;
var std_transport_ready: std.atomic.Value(bool) = .init(false);
var std_transport_mutex: sync.Mutex = .{};

fn builtInTransport() ?http.Transport {
    if (!sync.has_std_io) return null;
    if (!std_transport_ready.load(.acquire)) {
        std_transport_mutex.lock();
        defer std_transport_mutex.unlock();
        if (!std_transport_ready.load(.acquire)) {
            std_transport = .init(gpa);
            std_transport_ready.store(true, .release);
        }
    }
    return std_transport.transport();
}

/// The host's transport if it set one, else the built-in one (none on iOS).
fn transport() http.Transport {
    if (host_transport) |*t| return .{ .ctx = t, .sendFn = HostTransport.send };
    return builtInTransport() orelse .{ .ctx = null, .sendFn = noTransport };
}

fn noTransport(_: ?*anyopaque, _: Allocator, _: http.Request) anyerror!http.Response {
    return error.NoTransport;
}

// MARK: Host transport

pub const CHeader = extern struct { name: [*:0]const u8, value: [*:0]const u8 };

pub const CRequest = extern struct {
    method: [*:0]const u8,
    url: [*:0]const u8,
    headers: [*]const CHeader,
    header_count: usize,
    body: ?[*]const u8,
    body_len: usize,
};

pub const CResponse = extern struct {
    status: c_int = 0,
    /// "Name: value\r\n" lines, allocated with `biblio_alloc`.
    headers: ?[*]u8 = null,
    headers_len: usize = 0,
    /// Allocated with `biblio_alloc`.
    body: ?[*]u8 = null,
    body_len: usize = 0,
};

pub const CTransportFn = *const fn (ctx: ?*anyopaque, req: *const CRequest, res: *CResponse) callconv(.c) c_int;

const HostTransport = struct {
    func: CTransportFn,
    ctx: ?*anyopaque,

    fn send(ctx: ?*anyopaque, a: Allocator, req: http.Request) anyerror!http.Response {
        const t: *HostTransport = @ptrCast(@alignCast(ctx.?));
        var headers = try a.alloc(CHeader, req.headers.len);
        for (req.headers, 0..) |h, i| headers[i] = .{ .name = try a.dupeSentinel(u8, h.name, 0), .value = try a.dupeSentinel(u8, h.value, 0) };
        const c_req: CRequest = .{
            .method = try a.dupeSentinel(u8, req.method, 0),
            .url = try a.dupeSentinel(u8, req.url, 0),
            .headers = headers.ptr,
            .header_count = headers.len,
            .body = if (req.body) |b| b.ptr else null,
            .body_len = if (req.body) |b| b.len else 0,
        };
        var res: CResponse = .{};
        const rc = t.func(t.ctx, &c_req, &res);
        defer {
            if (res.headers) |p| biblio_free(p);
            if (res.body) |p| biblio_free(p);
        }
        if (rc != 0) return error.TransportFailed;
        const body = if (res.body) |p| try a.dupe(u8, p[0..res.body_len]) else "";
        var list: std.ArrayList(http.Header) = .empty;
        if (res.headers) |p| {
            var lines = std.mem.splitSequence(u8, p[0..res.headers_len], "\r\n");
            while (lines.next()) |line| {
                const colon = std.mem.findScalar(u8, line, ':') orelse continue;
                try list.append(a, .{
                    .name = try a.dupe(u8, std.mem.trim(u8, line[0..colon], " ")),
                    .value = try a.dupe(u8, std.mem.trim(u8, line[colon + 1 ..], " ")),
                });
            }
        }
        return .{ .status = @intCast(res.status), .url = req.url, .headers = list.items, .body = body };
    }
};

// MARK: Memory shared with the host

/// Allocations the host hands to the core (transport responses) and the core hands to the
/// host (results) carry their length in a header, so either side frees with `biblio_free`.
const Prefix = extern struct { len: usize, _pad: usize = 0 };

pub export fn biblio_alloc(len: usize) ?[*]u8 {
    const mem = gpa.alignedAlloc(u8, .of(Prefix), len + @sizeOf(Prefix)) catch return null;
    @as(*Prefix, @ptrCast(mem.ptr)).* = .{ .len = len };
    return mem.ptr + @sizeOf(Prefix);
}

pub export fn biblio_free(ptr: ?*anyopaque) void {
    const p: [*]u8 = @ptrCast(ptr orelse return);
    const base: [*]align(@alignOf(Prefix)) u8 = @alignCast(p - @sizeOf(Prefix));
    const len = @as(*Prefix, @ptrCast(base)).len;
    gpa.free(base[0 .. len + @sizeOf(Prefix)]);
}

fn hostString(s: []const u8) ?[*:0]u8 {
    const p = biblio_alloc(s.len + 1) orelse return null;
    @memcpy(p[0..s.len], s);
    p[s.len] = 0;
    return @ptrCast(p);
}

// MARK: Exports

pub export fn biblio_version() [*:0]const u8 {
    return "1.1.0";
}

/// Routes every request through the host's HTTP stack. Pass null to go back to the built-in one.
/// Call before creating clients.
pub export fn biblio_set_transport(func: ?CTransportFn, ctx: ?*anyopaque) void {
    host_transport = if (func) |f| .{ .func = f, .ctx = ctx } else null;
}

pub const CPasswordFn = *const fn (ctx: ?*anyopaque, subdomain: [*:0]const u8, username: [*:0]const u8) callconv(.c) ?[*:0]u8;

const PasswordBridge = struct {
    func: CPasswordFn,
    ctx: ?*anyopaque,

    fn get(ctx: ?*anyopaque, subdomain: []const u8, username: []const u8, a: Allocator) ?[]const u8 {
        const b: *PasswordBridge = @ptrCast(@alignCast(ctx.?));
        const sd = a.dupeSentinel(u8, subdomain, 0) catch return null;
        const un = a.dupeSentinel(u8, username, 0) catch return null;
        const p = b.func(b.ctx, sd, un) orelse return null;
        defer biblio_free(p);
        const s = std.mem.span(p);
        const copy = a.dupe(u8, s) catch null;
        std.crypto.secureZero(u8, s);
        return copy;
    }
};

pub const Handle = struct {
    client: *Client,
    bridge: PasswordBridge,
};

/// Creates a client for one (library, username) pair. An empty username makes a guest client.
/// `password` is called (from the calling thread) whenever the core needs to log in; it returns
/// a string allocated with `biblio_alloc`, or null if no password is saved.
pub export fn biblio_client_new(subdomain: [*:0]const u8, username: [*:0]const u8, password: CPasswordFn, ctx: ?*anyopaque) ?*Handle {
    const h = gpa.create(Handle) catch return null;
    h.bridge = .{ .func = password, .ctx = ctx };
    h.client = Client.create(gpa, transport(), &throttle, std.mem.span(subdomain), std.mem.span(username), PasswordBridge.get, &h.bridge) catch {
        gpa.destroy(h);
        return null;
    };
    return h;
}

pub export fn biblio_client_free(h: ?*Handle) void {
    const handle = h orelse return;
    handle.client.destroy();
    gpa.destroy(handle);
}

/// Runs one operation. `client` may be null for operations that need no account.
/// Blocks until done; returns a JSON string the caller frees with `biblio_free`.
pub export fn biblio_call(h: ?*Handle, request: [*:0]const u8) ?[*:0]u8 {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const out = call(a, if (h) |x| x.client else null, std.mem.span(request));
    return hostString(out);
}

// MARK: Dispatch

const Op = enum {
    // Library information (no client needed).
    subdomainFrom,
    libraryInfo,
    libraryExists,
    directoryPage,
    resolveSubdomain,
    formatName,
    sortName,
    readableTint,
    codabar,
    fetchImage,
    // Client operations.
    configure,
    status,
    login,
    patron,
    search,
    availability,
    details,
    locations,
    holds,
    checkouts,
    history,
    placeHold,
    cancelHolds,
    accountSettings,
    setPickup,
    setLanguage,
    setBorrowingHistory,
    changeEmail,
    changePassword,
};

/// Runs a request and returns `{"ok":true,"result":…}` or `{"ok":false,"error":{…}}`.
pub fn call(a: Allocator, c: ?*Client, request: []const u8) []const u8 {
    var failure: Failure = .{ .kind = "unexpected", .message = "Something went wrong." };
    const req = json.parse(a, request);
    const op_name = req.get("op").str(a) orelse "";
    const op = std.meta.stringToEnum(Op, op_name) orelse {
        failure = .{ .kind = "badRequest", .message = std.fmt.allocPrint(a, "Unknown operation “{s}”.", .{op_name}) catch "Unknown operation." };
        return encodeFailure(a, failure);
    };
    var out: std.Io.Writer.Allocating = .init(a);
    var w: std.json.Stringify = .{ .writer = &out.writer, .options = .{ .emit_null_optional_fields = false } };
    run(a, c, op, req, &w, &failure) catch return encodeFailure(a, failure);
    return out.written();
}

fn encodeFailure(a: Allocator, failure: Failure) []const u8 {
    return std.json.Stringify.valueAlloc(a, .{ .ok = false, .@"error" = failure }, .{ .emit_null_optional_fields = false }) catch
        "{\"ok\":false,\"error\":{\"kind\":\"outOfMemory\",\"message\":\"Out of memory.\"}}";
}

fn ok(w: *std.json.Stringify, result: anytype) !void {
    try w.beginObject();
    try w.objectField("ok");
    try w.write(true);
    try w.objectField("result");
    try w.write(result);
    try w.endObject();
}

fn requireString(a: Allocator, req: J, key: []const u8, failure: *Failure) ![]const u8 {
    return req.get(key).str(a) orelse {
        failure.* = .{ .kind = "badRequest", .message = std.fmt.allocPrint(a, "Missing “{s}”.", .{key}) catch "Missing field." };
        return error.BadRequest;
    };
}

fn requireClient(c: ?*Client, failure: *Failure) !*Client {
    return c orelse {
        failure.* = .{ .kind = "badRequest", .message = "This operation needs a client." };
        return error.BadRequest;
    };
}

fn lookup() library.Lookup {
    return .{ .fetcher = .{ .transport = transport(), .throttle = &throttle, .jar = null } };
}

fn run(a: Allocator, c_opt: ?*Client, op: Op, req: J, w: *std.json.Stringify, failure: *Failure) !void {
    switch (op) {
        .subdomainFrom => try ok(w, library.subdomainFrom(a, try requireString(a, req, "input", failure))),
        .libraryInfo => {
            const subdomain = try requireString(a, req, "subdomain", failure);
            var message: []const u8 = "";
            const info = lookup().info(a, subdomain, &message) catch {
                failure.* = .{ .kind = "notALibrary", .message = message };
                return error.Failed;
            };
            try ok(w, info);
        },
        .libraryExists => try ok(w, lookup().exists(a, try requireString(a, req, "subdomain", failure))),
        .directoryPage => {
            const page = lookup().directoryPage(a, req.get("url").str(a)) catch {
                failure.* = .{ .kind = "network", .message = "The library directory could not be loaded." };
                return error.Failed;
            };
            try ok(w, page);
        },
        .resolveSubdomain => try ok(w, lookup().resolveSubdomain(a, try requireString(a, req, "name", failure), req.get("website").str(a))),
        .formatName => try ok(w, library.formatName(a, req.get("labels"), try requireString(a, req, "code", failure))),
        .sortName => try ok(w, library.sortName(a, req.get("labels"), try requireString(a, req, "id", failure))),
        .readableTint => {
            var buf: [7]u8 = undefined;
            try ok(w, library.readableTint(try requireString(a, req, "hex", failure), req.get("dark").boolean() orelse false, &buf));
        },
        .codabar => try ok(w, models.codabar(a, try requireString(a, req, "value", failure))),
        .fetchImage => {
            // For apps without an image loader of their own (GNOME): jacket art as base64.
            const url = try requireString(a, req, "url", failure);
            const res = lookup().fetcher.fetch(a, .{ .method = "GET", .url = url }) catch {
                failure.* = .{ .kind = "network", .message = "The image could not be loaded." };
                return error.Failed;
            };
            if (res.status != 200) {
                failure.* = .{ .kind = "http", .status = res.status, .message = "The image could not be loaded." };
                return error.Failed;
            }
            const encoder = std.base64.standard.Encoder;
            const out = try a.alloc(u8, encoder.calcSize(res.body.len));
            try ok(w, encoder.encode(out, res.body));
        },
        else => {
            const c = try requireClient(c_opt, failure);
            try runClient(a, c, op, req, w, failure);
        },
    }
}

fn runClient(a: Allocator, c: *Client, op: Op, req: J, w: *std.json.Stringify, failure: *Failure) !void {
    switch (op) {
        .configure => {
            if (req.get("language").str(a)) |l| c.setLanguage(l);
            if (req.get("sampleAccount").boolean()) |b| c.sample_account = b;
            try ok(w, true);
        },
        .status => {
            c.status_mutex.lock();
            defer c.status_mutex.unlock();
            try ok(w, .{
                .active = c.active.load(.monotonic),
                .title = if (c.status_title) |s| a.dupe(u8, s) catch null else null,
                .url = if (c.status_url) |s| a.dupe(u8, s) catch null else null,
                .bytes = c.status_bytes,
            });
        },
        .login => try ok(w, try c.login(a, req.get("force").boolean() orelse false, failure)),
        .patron => try ok(w, c.currentPatron(a)),
        .search => {
            const q = std.json.parseFromValueLeaky(Client.SearchQuery, a, req.v.?, .{ .ignore_unknown_fields = true }) catch {
                failure.* = .{ .kind = "badRequest", .message = "Search needs a “query”." };
                return error.BadRequest;
            };
            try ok(w, try c.search(a, q, failure));
        },
        .availability => try ok(w, try c.availability(a, try requireString(a, req, "metadataId", failure), failure)),
        .details => try ok(w, try c.detailFields(a, try requireString(a, req, "metadataId", failure), failure)),
        .locations => try ok(w, try c.locations(a, failure)),
        .holds, .checkouts, .history => {
            const kind: models.BorrowingKind = switch (op) {
                .holds => .holds,
                .checkouts => .checkouts,
                else => .history,
            };
            try ok(w, try c.borrowing(a, kind, req.get("page").int() orelse 1, req.get("sort").str(a), failure));
        },
        .placeHold => {
            try c.placeHold(a, try requireString(a, req, "metadataId", failure), req.get("materialType").str(a) orelse "PHYSICAL", req.get("pickupBranch").str(a), failure);
            try ok(w, true);
        },
        .cancelHolds => {
            var refs: std.ArrayList(Client.HoldRef) = .empty;
            for (req.get("holds").items()) |v| {
                const h = J.of(v);
                try refs.append(a, .{ .id = h.get("id").str(a) orelse continue, .metadataId = h.get("metadataId").str(a) orelse continue });
            }
            try ok(w, .{ .refused = try c.cancelHolds(a, refs.items, failure) });
        },
        .accountSettings => try ok(w, try c.accountSettings(a, failure)),
        .setPickup => {
            try c.setDefaultPickupLocation(a, try requireString(a, req, "branchId", failure), failure);
            try ok(w, true);
        },
        .setLanguage => {
            try c.changeLanguage(a, try requireString(a, req, "code", failure), failure);
            try ok(w, true);
        },
        .setBorrowingHistory => {
            try c.setBorrowingHistory(a, req.get("enabled").boolean() orelse return error.BadRequest, failure);
            try ok(w, true);
        },
        .changeEmail => {
            try c.changeEmail(a, try requireString(a, req, "email", failure), failure);
            try ok(w, true);
        },
        .changePassword => {
            try c.changePassword(a, try requireString(a, req, "current", failure), try requireString(a, req, "new", failure), failure);
            try ok(w, true);
        },
        else => unreachable,
    }
}
