//! libbiblio's C interface: clients, memory and transport here; the operations are in capi.zig.
//! See include/biblio.h for the contract.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const http = @import("http.zig");
const json = @import("json.zig");
/// The result types, for Zig frontends that call `Client` directly.
pub const models = @import("models.zig");
/// Library lookup and display helpers (`subdomainFrom`, `formatName`, …).
pub const library = @import("library.zig");
const client_mod = @import("client.zig");
pub const Client = client_mod.Client;
pub const Failure = client_mod.Failure;

pub const html = @import("html.zig");
/// Finding library icons and trimming logos.
pub const icon = @import("icon.zig");
/// The paged list state every app shows (`List`).
pub const item_list = @import("list.zig");
/// The typed C functions (`biblio_search`, `biblio_login`, …).
pub const capi = @import("capi.zig");

comptime {
    _ = capi; // emit its exports
}
/// Locks and the allocator the core uses, for hosts written in Zig.
pub const sync = @import("sync.zig");

test {
    _ = json;
    _ = item_list;
    _ = models;
    _ = html;
    _ = http;
    _ = library;
    _ = icon;
    _ = client_mod;
    _ = @import("fixtures_test.zig");
    _ = capi;
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

pub fn hostString(s: []const u8) ?[*:0]u8 {
    const p = biblio_alloc(s.len + 1) orelse return null;
    @memcpy(p[0..s.len], s);
    p[s.len] = 0;
    return @ptrCast(p);
}

// MARK: Exports

pub export fn biblio_version() [*:0]const u8 {
    return "1.3.0";
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

/// Library lookups (info, directory, images) through the shared transport and throttle.
pub fn lookup() library.Lookup {
    return .{ .fetcher = .{ .transport = transport(), .throttle = &throttle, .jar = null } };
}
