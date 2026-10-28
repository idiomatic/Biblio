//! HTTP for the core: one request at a time per call, paced app-wide by `Throttle`, with a
//! per-client cookie jar. Redirects are followed here (not by the transport) so cookies set
//! on a redirect response are kept and the final URL is known.
//!
//! The transport is either Zig's `std.http.Client` or a host-provided callback, so apps can
//! use their platform's HTTP stack (system trust store, proxies, VPNs). A host transport must
//! not follow redirects or store cookies itself.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const sync = @import("sync.zig");

pub const user_agent = "Biblio/1.0 (libbiblio)";

pub const Header = struct { name: []const u8, value: []const u8 };

pub const Request = struct {
    method: []const u8,
    url: []const u8,
    headers: []const Header = &.{},
    body: ?[]const u8 = null,
};

pub const Response = struct {
    status: u16,
    /// The URL that produced this response, after redirects.
    url: []const u8,
    headers: []const Header,
    body: []const u8,

    pub fn header(self: Response, name: []const u8) ?[]const u8 {
        for (self.headers) |h| if (std.ascii.eqlIgnoreCase(h.name, name)) return h.value;
        return null;
    }
};

/// Sends one request without following redirects. Everything returned is allocated in `arena`.
pub const Transport = struct {
    ctx: ?*anyopaque,
    sendFn: *const fn (ctx: ?*anyopaque, arena: Allocator, req: Request) anyerror!Response,

    pub fn send(self: Transport, arena: Allocator, req: Request) !Response {
        return self.sendFn(self.ctx, arena, req);
    }
};

// MARK: Throttle

/// App-wide request pacing so the library sites are not hammered:
/// at most `max_concurrent` requests in flight and a minimum gap between starts.
pub const Throttle = struct {
    const max_concurrent = 3;
    const minimum_gap_ns: i96 = 250 * std.time.ns_per_ms;

    mutex: sync.Mutex = .{},
    cond: sync.Condition = .{},
    in_flight: u32 = 0,
    last_start_ns: i96 = 0,

    pub fn acquire(t: *Throttle) void {
        t.mutex.lock();
        while (t.in_flight >= max_concurrent) t.cond.wait(&t.mutex);
        t.in_flight += 1;
        const now = sync.now();
        const next = t.last_start_ns + minimum_gap_ns;
        t.last_start_ns = @max(now, next);
        t.mutex.unlock();
        if (next > now) sync.sleep(@intCast(next - now));
    }

    pub fn release(t: *Throttle) void {
        t.mutex.lock();
        t.in_flight -= 1;
        t.mutex.unlock();
        t.cond.signal();
    }
};

// MARK: Cookies

/// A minimal cookie jar: name/value per host, honoring Domain (suffix match) and Max-Age=0 /
/// past Expires deletion, which is all the BiblioCommons login and Rails pages need.
pub const CookieJar = struct {
    const Cookie = struct { domain: []u8, name: []u8, value: []u8, host_only: bool };

    gpa: Allocator,
    mutex: sync.Mutex = .{},
    cookies: std.ArrayList(Cookie) = .empty,

    pub fn init(gpa: Allocator) CookieJar {
        return .{ .gpa = gpa };
    }

    pub fn deinit(j: *CookieJar) void {
        for (j.cookies.items) |c| j.freeCookie(c);
        j.cookies.deinit(j.gpa);
    }

    fn freeCookie(j: *CookieJar, c: Cookie) void {
        j.gpa.free(c.domain);
        j.gpa.free(c.name);
        j.gpa.free(c.value);
    }

    pub fn clear(j: *CookieJar) void {
        j.mutex.lock();
        defer j.mutex.unlock();
        for (j.cookies.items) |c| j.freeCookie(c);
        j.cookies.clearRetainingCapacity();
    }

    /// The `Cookie` header value for a request to `host`, or null if none apply.
    pub fn header(j: *CookieJar, arena: Allocator, host: []const u8) ?[]const u8 {
        j.mutex.lock();
        defer j.mutex.unlock();
        var out: std.ArrayList(u8) = .empty;
        for (j.cookies.items) |c| {
            if (!domainMatches(host, c.domain, c.host_only)) continue;
            if (out.items.len > 0) out.appendSlice(arena, "; ") catch return null;
            out.print(arena, "{s}={s}", .{ c.name, c.value }) catch return null;
        }
        return if (out.items.len == 0) null else out.items;
    }

    /// Stores one `Set-Cookie` header value received from `host`.
    pub fn store(j: *CookieJar, host: []const u8, set_cookie: []const u8) void {
        var parts = std.mem.splitScalar(u8, set_cookie, ';');
        const pair = std.mem.trim(u8, parts.first(), " ");
        const eq = std.mem.findScalar(u8, pair, '=') orelse return;
        const name = std.mem.trim(u8, pair[0..eq], " ");
        const value = std.mem.trim(u8, pair[eq + 1 ..], " \"");
        if (name.len == 0) return;
        var domain: []const u8 = host;
        var host_only = true;
        var expired = false;
        while (parts.next()) |raw| {
            const attr = std.mem.trim(u8, raw, " ");
            const aeq = std.mem.findScalar(u8, attr, '=') orelse continue;
            const key = attr[0..aeq];
            const val = std.mem.trim(u8, attr[aeq + 1 ..], " ");
            if (std.ascii.eqlIgnoreCase(key, "domain")) {
                const d = std.mem.trimStart(u8, val, ".");
                // Only accept a domain the host belongs to.
                if (domainMatches(host, d, false)) {
                    domain = d;
                    host_only = false;
                }
            } else if (std.ascii.eqlIgnoreCase(key, "max-age")) {
                if ((std.fmt.parseInt(i64, val, 10) catch 1) <= 0) expired = true;
            } else if (std.ascii.eqlIgnoreCase(key, "expires")) {
                // Rails and the gateway delete cookies with an expiry in 1970.
                if (std.mem.find(u8, val, "1970") != null) expired = true;
            }
        }

        j.mutex.lock();
        defer j.mutex.unlock();
        var i: usize = 0;
        while (i < j.cookies.items.len) {
            const c = j.cookies.items[i];
            if (std.mem.eql(u8, c.name, name) and std.ascii.eqlIgnoreCase(c.domain, domain)) {
                j.freeCookie(c);
                _ = j.cookies.orderedRemove(i);
            } else i += 1;
        }
        if (expired) return;
        const c: Cookie = .{
            .domain = j.gpa.dupe(u8, domain) catch return,
            .name = j.gpa.dupe(u8, name) catch return,
            .value = j.gpa.dupe(u8, value) catch return,
            .host_only = host_only,
        };
        j.cookies.append(j.gpa, c) catch j.freeCookie(c);
    }
};

fn domainMatches(host: []const u8, domain: []const u8, host_only: bool) bool {
    if (std.ascii.eqlIgnoreCase(host, domain)) return true;
    if (host_only) return false;
    return host.len > domain.len and host[host.len - domain.len - 1] == '.' and
        std.ascii.eqlIgnoreCase(host[host.len - domain.len ..], domain);
}

pub fn hostOf(url: []const u8) []const u8 {
    const start = (std.mem.find(u8, url, "://") orelse return "") + 3;
    const end = std.mem.findAnyPos(u8, url, start, "/?#:") orelse url.len;
    return url[start..end];
}

// MARK: Fetching with cookies, redirects and pacing

pub const Fetcher = struct {
    transport: Transport,
    throttle: *Throttle,
    jar: ?*CookieJar,
    /// Called after each response, for the app's status bar.
    observer: ?*const fn (ctx: ?*anyopaque, url: []const u8, body: []const u8) void = null,
    observer_ctx: ?*anyopaque = null,

    /// Sends `req`, following up to 5 redirects (a 303, or a 301/302 after POST, becomes a GET).
    pub fn fetch(f: Fetcher, arena: Allocator, req: Request) !Response {
        var current = req;
        var redirects: u8 = 0;
        while (true) {
            var headers: std.ArrayList(Header) = .empty;
            try headers.appendSlice(arena, current.headers);
            try headers.append(arena, .{ .name = "User-Agent", .value = user_agent });
            if (f.jar) |jar| {
                if (jar.header(arena, hostOf(current.url))) |c| try headers.append(arena, .{ .name = "Cookie", .value = c });
            }
            const send: Request = .{ .method = current.method, .url = current.url, .headers = headers.items, .body = current.body };

            f.throttle.acquire();
            const result = f.transport.send(arena, send);
            f.throttle.release();
            var res = try result;
            res.url = current.url;

            if (f.jar) |jar| {
                for (res.headers) |h| {
                    if (std.ascii.eqlIgnoreCase(h.name, "set-cookie")) jar.store(hostOf(current.url), h.value);
                }
            }
            const is_redirect = switch (res.status) {
                301, 302, 303, 307, 308 => true,
                else => false,
            };
            if (!is_redirect or redirects >= 5) {
                if (f.observer) |o| o(f.observer_ctx, res.url, res.body);
                return res;
            }
            const location = res.header("location") orelse return res;
            redirects += 1;
            const html = @import("html.zig");
            const next_url = html.resolve(arena, current.url, location);
            const keep_method = res.status == 307 or res.status == 308;
            current = if (keep_method) .{
                .method = current.method,
                .url = next_url,
                .headers = current.headers,
                .body = current.body,
            } else .{
                .method = "GET",
                .url = next_url,
                .headers = withoutContentType(arena, current.headers),
            };
        }
    }
};

fn withoutContentType(arena: Allocator, headers: []const Header) []const Header {
    var out: std.ArrayList(Header) = .empty;
    for (headers) |h| {
        if (!std.ascii.eqlIgnoreCase(h.name, "content-type")) out.append(arena, h) catch {};
    }
    return out.items;
}

// MARK: Built-in transport (std.http)

pub const StdTransport = if (!sync.has_std_io) void else struct {
    client: std.http.Client,

    pub fn init(gpa: Allocator) @This() {
        return .{ .client = .{ .allocator = gpa, .io = sync.io() } };
    }

    pub fn deinit(t: *@This()) void {
        t.client.deinit();
    }

    pub fn transport(t: *@This()) Transport {
        return .{ .ctx = t, .sendFn = send };
    }

    fn send(ctx: ?*anyopaque, arena: Allocator, req: Request) anyerror!Response {
        const t: *@This() = @ptrCast(@alignCast(ctx.?));
        const method = std.meta.stringToEnum(std.http.Method, req.method) orelse return error.UnsupportedMethod;
        const uri = try std.Uri.parse(req.url);

        var extra: std.ArrayList(std.http.Header) = .empty;
        var user_agent_override: ?[]const u8 = null;
        var content_type: ?[]const u8 = null;
        for (req.headers) |h| {
            if (std.ascii.eqlIgnoreCase(h.name, "user-agent")) {
                user_agent_override = h.value;
            } else if (std.ascii.eqlIgnoreCase(h.name, "content-type")) {
                content_type = h.value;
            } else {
                try extra.append(arena, .{ .name = h.name, .value = h.value });
            }
        }
        // std.http only sends bodies for POST/PUT/PATCH; the gateway's DELETE /holds takes
        // one too, so its length header and body are written by hand after the head.
        const manual_body = req.body != null and !method.requestHasBody();
        if (manual_body) {
            try extra.append(arena, .{ .name = "content-length", .value = try std.fmt.allocPrint(arena, "{d}", .{req.body.?.len}) });
            if (content_type) |ct| try extra.append(arena, .{ .name = "content-type", .value = ct });
        }

        var r = try t.client.request(method, uri, .{
            .redirect_behavior = .unhandled,
            .headers = .{
                .user_agent = if (user_agent_override) |u| .{ .override = u } else .default,
                .content_type = if (content_type != null and !manual_body) .{ .override = content_type.? } else .default,
            },
            .extra_headers = extra.items,
        });
        defer r.deinit();

        if (req.body) |body| {
            if (manual_body) {
                try r.sendBodilessUnflushed();
                try r.connection.?.writer().writeAll(body);
                try r.connection.?.flush();
            } else {
                try r.sendBodyComplete(@constCast(body));
            }
        } else if (method.requestHasBody()) {
            try r.sendBodyComplete(@constCast(""));
        } else {
            try r.sendBodiless();
        }

        var response = try r.receiveHead(&.{});
        var headers: std.ArrayList(Header) = .empty;
        var it = response.head.iterateHeaders();
        while (it.next()) |h| {
            try headers.append(arena, .{ .name = try arena.dupe(u8, h.name), .value = try arena.dupe(u8, h.value) });
        }
        const status: u16 = @intFromEnum(response.head.status);

        const decompress_buffer: []u8 = switch (response.head.content_encoding) {
            .identity => &.{},
            .zstd => try arena.alloc(u8, std.compress.zstd.default_window_len),
            .deflate, .gzip => try arena.alloc(u8, std.compress.flate.max_window_len),
            .compress => return error.UnsupportedCompressionMethod,
        };
        var transfer_buffer: [64]u8 = undefined;
        var decompress: std.http.Decompress = undefined;
        const reader = response.readerDecompressing(&transfer_buffer, &decompress, decompress_buffer);
        var body: Io.Writer.Allocating = .init(arena);
        _ = reader.streamRemaining(&body.writer) catch |err| switch (err) {
            error.ReadFailed => return response.bodyErr().?,
            else => |e| return e,
        };
        return .{ .status = status, .url = req.url, .headers = headers.items, .body = body.written() };
    }
};

test "cookie jar" {
    var jar = CookieJar.init(std.testing.allocator);
    defer jar.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    jar.store("wccls.bibliocommons.com", "session=abc; path=/; HttpOnly");
    jar.store("gateway.bibliocommons.com", "bc_access_token=t1; Domain=.bibliocommons.com; Secure");
    jar.store("evil.example.com", "x=1; Domain=bibliocommons.com");
    try std.testing.expectEqualStrings("session=abc; bc_access_token=t1", jar.header(a, "wccls.bibliocommons.com").?);
    try std.testing.expectEqualStrings("bc_access_token=t1", jar.header(a, "gateway.bibliocommons.com").?);
    jar.store("wccls.bibliocommons.com", "session=; expires=Thu, 01 Jan 1970 00:00:00 GMT");
    try std.testing.expectEqualStrings("bc_access_token=t1", jar.header(a, "wccls.bibliocommons.com").?);
    try std.testing.expectEqualStrings("wccls.bibliocommons.com", hostOf("https://wccls.bibliocommons.com/v2/x"));
}
