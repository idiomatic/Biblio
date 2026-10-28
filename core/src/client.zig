//! One authenticated BiblioCommons session for a (library, username) pair.
//!
//! Requests carry the gateway's `X-Session-Id`/`X-Access-Token` headers. When the gateway
//! rejects them (inactivity timeout, or another login with the same credentials evicted us)
//! the client logs in again with the saved password and retries once, so callers never see
//! the expiry. Every method blocks; apps call them from a background thread.

const std = @import("std");
const Allocator = std.mem.Allocator;
const sync = @import("sync.zig");
const http = @import("http.zig");
const html = @import("html.zig");
const json = @import("json.zig");
const models = @import("models.zig");
const J = json.J;

pub const Error = error{
    MissingCredentials,
    SignInRequired,
    LoginFailed,
    Http,
    Unexpected,
    OutOfMemory,
    Transport,
};

/// What went wrong, in words an app can show. Set alongside every returned error.
pub const Failure = struct {
    kind: []const u8,
    message: []const u8,
    status: ?u16 = null,
};

/// Asks the app for the saved password. Returns null if there is none. The returned
/// string must stay valid until the call returns (the core copies it).
pub const PasswordFn = *const fn (ctx: ?*anyopaque, subdomain: []const u8, username: []const u8, arena: Allocator) ?[]const u8;

pub const Client = struct {
    gpa: Allocator,
    subdomain: []u8,
    /// Empty for a guest client, which can only make unauthenticated catalog requests.
    username: []u8,
    password_fn: PasswordFn,
    password_ctx: ?*anyopaque,
    jar: http.CookieJar,
    transport: http.Transport,
    throttle: *http.Throttle,
    sample_account: bool = false,

    /// Guards the session fields below; held for a whole login so concurrent callers join it.
    mutex: sync.Mutex = .{},
    session_id: ?[]u8 = null,
    auth_token: ?[]u8 = null,
    patron: ?models.Patron = null,
    /// The app's language, used until a login reports the account's.
    language: ?[]u8 = null,
    /// Bumped on every login, so a request that saw an expired session can tell whether
    /// another thread already logged in again.
    login_generation: u64 = 0,

    /// Status-bar reporting: the latest request's title, URL and size, and requests in flight.
    status_mutex: sync.Mutex = .{},
    status_title: ?[]u8 = null,
    status_url: ?[]u8 = null,
    status_bytes: usize = 0,
    active: std.atomic.Value(u32) = .init(0),

    pub fn create(gpa: Allocator, transport: http.Transport, throttle: *http.Throttle, subdomain: []const u8, username: []const u8, password_fn: PasswordFn, password_ctx: ?*anyopaque) !*Client {
        const c = try gpa.create(Client);
        c.* = .{
            .gpa = gpa,
            .subdomain = try gpa.dupe(u8, subdomain),
            .username = try gpa.dupe(u8, username),
            .password_fn = password_fn,
            .password_ctx = password_ctx,
            .jar = .init(gpa),
            .transport = transport,
            .throttle = throttle,
        };
        return c;
    }

    pub fn destroy(c: *Client) void {
        c.jar.deinit();
        c.clearSession();
        if (c.patron) |p| p.free(c.gpa);
        if (c.language) |l| c.gpa.free(l);
        if (c.status_title) |s| c.gpa.free(s);
        if (c.status_url) |s| c.gpa.free(s);
        c.gpa.free(c.subdomain);
        c.gpa.free(c.username);
        c.gpa.destroy(c);
    }

    pub fn isGuest(c: *const Client) bool {
        return c.username.len == 0;
    }

    fn clearSession(c: *Client) void {
        if (c.session_id) |s| c.gpa.free(s);
        if (c.auth_token) |s| c.gpa.free(s);
        c.session_id = null;
        c.auth_token = null;
    }

    pub fn locale(c: *Client, a: Allocator) []const u8 {
        c.mutex.lock();
        defer c.mutex.unlock();
        if (c.patron) |p| return a.dupe(u8, p.language) catch "en-US";
        if (c.language) |l| return a.dupe(u8, l) catch "en-US";
        return "en-US";
    }

    pub fn setLanguage(c: *Client, code: []const u8) void {
        c.mutex.lock();
        defer c.mutex.unlock();
        if (c.language) |l| c.gpa.free(l);
        c.language = c.gpa.dupe(u8, code) catch null;
        if (c.patron) |*p| {
            if (c.gpa.dupe(u8, code)) |copy| {
                c.gpa.free(p.language);
                p.language = copy;
            } else |_| {}
        }
    }

    fn gateway(c: *Client, a: Allocator, path: []const u8) ![]const u8 {
        return std.fmt.allocPrint(a, "https://gateway.bibliocommons.com/v2/libraries/{s}/{s}", .{ c.subdomain, path });
    }

    pub fn webBase(c: *Client, a: Allocator) ![]const u8 {
        return std.fmt.allocPrint(a, "https://{s}.bibliocommons.com", .{c.subdomain});
    }

    fn fetcher(c: *Client) http.Fetcher {
        return .{ .transport = c.transport, .throttle = c.throttle, .jar = &c.jar, .observer = observe, .observer_ctx = c };
    }

    fn observe(ctx: ?*anyopaque, url: []const u8, body: []const u8) void {
        const c: *Client = @ptrCast(@alignCast(ctx.?));
        var arena = std.heap.ArenaAllocator.init(c.gpa);
        defer arena.deinit();
        const title = fetchTitle(arena.allocator(), url, body);
        c.status_mutex.lock();
        defer c.status_mutex.unlock();
        if (c.status_title) |s| c.gpa.free(s);
        if (c.status_url) |s| c.gpa.free(s);
        c.status_title = c.gpa.dupe(u8, title) catch null;
        c.status_url = c.gpa.dupe(u8, url) catch null;
        c.status_bytes = body.len;
    }

    fn request(c: *Client, a: Allocator, req: http.Request, failure: *Failure) Error!http.Response {
        _ = c.active.fetchAdd(1, .monotonic);
        defer _ = c.active.fetchSub(1, .monotonic);
        return c.fetcher().fetch(a, req) catch |err| {
            failure.* = .{ .kind = "network", .message = std.fmt.allocPrint(a, "The library could not be reached ({s}).", .{@errorName(err)}) catch "The library could not be reached." };
            return error.Transport;
        };
    }

    // MARK: Authentication

    /// Logs in (or joins a login already in progress) and returns the patron.
    pub fn login(c: *Client, a: Allocator, force: bool, failure: *Failure) Error!models.Patron {
        if (c.isGuest()) {
            failure.* = .{ .kind = "signInRequired", .message = "Sign in to use this feature." };
            return error.SignInRequired;
        }
        const seen = c.login_generation;
        c.mutex.lock();
        defer c.mutex.unlock();
        // Someone else logged in while we waited for the lock: use their session.
        if (c.patron != null and c.session_id != null and (!force or c.login_generation != seen)) {
            return c.patron.?.clone(a);
        }
        const patron = try c.performLogin(a, failure);
        if (c.patron) |old| old.free(c.gpa);
        c.patron = try patron.clone(c.gpa);
        c.login_generation += 1;
        return patron;
    }

    /// Called with `mutex` held.
    fn performLogin(c: *Client, a: Allocator, failure: *Failure) Error!models.Patron {
        const password = c.password_fn(c.password_ctx, c.subdomain, c.username, a) orelse {
            failure.* = .{ .kind = "missingCredentials", .message = "No saved password for this user. Add the user again." };
            return error.MissingCredentials;
        };
        c.clearSession();
        c.jar.clear();
        var body: std.Io.Writer.Allocating = .init(a);
        std.json.Stringify.value(.{ .username = c.username, .password = password }, .{}, &body.writer) catch return error.OutOfMemory;
        const res = try c.request(a, .{
            .method = "POST",
            .url = try c.gateway(a, "sessions"),
            .headers = &.{ .{ .name = "Accept", .value = "application/json" }, .{ .name = "Content-Type", .value = "application/json" } },
            .body = body.written(),
        }, failure);
        const j = json.parse(a, res.body);
        const sid = j.path("auth.sessionId").str(a);
        const token = j.path("auth.authToken").str(a);
        const uid = j.path("auth.currentUserId").int();
        if (res.status < 200 or res.status >= 300 or sid == null or token == null or uid == null) {
            failure.* = .{ .kind = "loginFailed", .message = models.message(a, j) orelse "Login failed. Check the username and PIN." };
            return error.LoginFailed;
        }
        c.session_id = try c.gpa.dupe(u8, sid.?);
        c.auth_token = try c.gpa.dupe(u8, token.?);

        const uid_s = try std.fmt.allocPrint(a, "{d}", .{uid.?});
        const user = j.path("entities.users").get(uid_s);
        var account_id = user.get("accounts").at(0).int();
        if (account_id == null) {
            if (j.path("entities.accounts").object()) |o| {
                for (o.keys()) |k| if (std.fmt.parseInt(i64, k, 10) catch null) |n| {
                    account_id = n;
                    break;
                };
            }
        }
        const account = j.path("entities.accounts").get(try std.fmt.allocPrint(a, "{d}", .{account_id orelse 0}));
        // The language chosen in this session wins; then the account's; then the app's default.
        const language = if (c.patron) |p| try a.dupe(u8, p.language) else user.path("preferences.language").str(a) orelse
            if (c.language) |l| try a.dupe(u8, l) else "en-US";
        var patron: models.Patron = .{
            .userId = uid.?,
            .accountId = account_id orelse 0,
            .name = user.get("name").str(a) orelse c.username,
            .email = user.path("userContact.email").nonEmpty(a),
            .language = language,
            .barcode = account.get("barcode").str(a),
            .preferredPickup = account.get("preferredLocations").at(0).str(a) orelse account.path("singleClickHoldsSettings.branchId").str(a),
            .borrowingHistoryEnabled = account.get("borrowingHistoryEnabled").boolean(),
        };
        // For screenshots: hide the real card and email.
        if (c.sample_account) {
            patron.email = "reader@example.com";
            patron.barcode = "21168012345678";
        }
        return patron;
    }

    /// The patron from the last login, without contacting the library.
    pub fn currentPatron(c: *Client, a: Allocator) ?models.Patron {
        c.mutex.lock();
        defer c.mutex.unlock();
        return if (c.patron) |p| p.clone(a) catch null else null;
    }

    fn updatePatron(c: *Client, comptime field: []const u8, value: anytype) void {
        c.mutex.lock();
        defer c.mutex.unlock();
        if (c.patron) |*p| {
            const T = @TypeOf(@field(p.*, field));
            if (T == ?[]const u8) {
                if (@field(p.*, field)) |old| c.gpa.free(old);
                @field(p.*, field) = c.gpa.dupe(u8, value) catch null;
            } else {
                @field(p.*, field) = value;
            }
        }
    }

    // MARK: Gateway requests

    pub const Query = []const struct { []const u8, []const u8 };

    /// Sends a gateway request, logging in first and re-authenticating once if the session expired.
    pub fn send(c: *Client, a: Allocator, method: []const u8, path: []const u8, query: Query, body: ?[]const u8, authenticated: bool, failure: *Failure) Error!J {
        var url: std.ArrayList(u8) = .empty;
        try url.appendSlice(a, try c.gateway(a, path));
        // Sorted by name, with the locale added unless given, so URLs are stable.
        var items: std.ArrayList(struct { []const u8, []const u8 }) = .empty;
        try items.appendSlice(a, query);
        var has_locale = false;
        for (query) |q| if (std.mem.eql(u8, q[0], "locale")) {
            has_locale = true;
        };
        if (!has_locale) try items.append(a, .{ "locale", c.locale(a) });
        std.mem.sort(struct { []const u8, []const u8 }, items.items, {}, struct {
            fn less(_: void, x: struct { []const u8, []const u8 }, y: struct { []const u8, []const u8 }) bool {
                return std.mem.order(u8, x[0], y[0]) == .lt;
            }
        }.less);
        for (items.items, 0..) |q, i| {
            try url.append(a, if (i == 0) '?' else '&');
            try percentEncode(a, &url, q[0]);
            try url.append(a, '=');
            try percentEncode(a, &url, q[1]);
        }

        if (authenticated) _ = try c.login(a, false, failure);
        var res = try c.rawGateway(a, method, url.items, body, authenticated, failure);
        var j = json.parse(a, res.body);
        if (authenticated and isAuthFailure(a, res.status, j)) {
            _ = try c.login(a, true, failure);
            res = try c.rawGateway(a, method, url.items, body, authenticated, failure);
            j = json.parse(a, res.body);
        }
        if (res.status < 200 or res.status >= 300) {
            failure.* = .{ .kind = "http", .status = res.status, .message = models.message(a, j) orelse statusText(res.status) };
            return error.Http;
        }
        return j;
    }

    fn rawGateway(c: *Client, a: Allocator, method: []const u8, url: []const u8, body: ?[]const u8, authenticated: bool, failure: *Failure) Error!http.Response {
        var headers: std.ArrayList(http.Header) = .empty;
        try headers.append(a, .{ .name = "Accept", .value = "application/json" });
        if (body != null) try headers.append(a, .{ .name = "Content-Type", .value = "application/json" });
        if (authenticated) {
            c.mutex.lock();
            if (c.session_id) |s| headers.append(a, .{ .name = "X-Session-Id", .value = a.dupe(u8, s) catch "" }) catch {};
            if (c.auth_token) |t| headers.append(a, .{ .name = "X-Access-Token", .value = a.dupe(u8, t) catch "" }) catch {};
            c.mutex.unlock();
        }
        return c.request(a, .{ .method = method, .url = url, .headers = headers.items, .body = body }, failure);
    }

    fn isAuthFailure(a: Allocator, status: u16, j: J) bool {
        if (status == 401 or status == 403) return true;
        if (status < 400) return false;
        const m = std.ascii.allocLowerString(a, models.message(a, j) orelse "") catch return false;
        for ([_][]const u8{ "session", "not logged", "unauthor", "authenticat" }) |w| {
            if (std.mem.find(u8, m, w) != null) return true;
        }
        return false;
    }

    /// Fetches an HTML page on the library's web host (shares this session's cookies).
    pub fn webPage(c: *Client, a: Allocator, path: []const u8, failure: *Failure) Error!struct { html: []const u8, url: []const u8 } {
        _ = try c.login(a, false, failure);
        const url = try std.fmt.allocPrint(a, "{s}/{s}", .{ try c.webBase(a), path });
        const headers: []const http.Header = &.{.{ .name = "Accept", .value = "text/html" }};
        var res = try c.request(a, .{ .method = "GET", .url = url, .headers = headers }, failure);
        if (std.mem.find(u8, html.urlPath(res.url), "/user/login") != null) {
            // Web session expired independently of the gateway one: log in again and retry.
            _ = try c.login(a, true, failure);
            res = try c.request(a, .{ .method = "GET", .url = url, .headers = headers }, failure);
        }
        return .{ .html = res.body, .url = res.url };
    }

    /// Submits an HTML form on the library's web host.
    fn submitForm(c: *Client, a: Allocator, form: html.Form, values: []const struct { []const u8, []const u8 }, failure: *Failure) Error!http.Response {
        var fields = form.fields(a);
        for (values) |v| try fields.put(a, v[0], v[1]);
        var body: std.ArrayList(u8) = .empty;
        var it = fields.iterator();
        var first = true;
        while (it.next()) |e| {
            if (!first) try body.append(a, '&');
            first = false;
            try percentEncode(a, &body, e.key_ptr.*);
            try body.append(a, '=');
            try percentEncode(a, &body, e.value_ptr.*);
        }
        return c.request(a, .{
            .method = form.method,
            .url = form.action,
            .headers = &.{.{ .name = "Content-Type", .value = "application/x-www-form-urlencoded" }},
            .body = body.items,
        }, failure);
    }

    fn accountForm(c: *Client, a: Allocator, page: []const u8, action: []const u8, failure: *Failure) Error!html.Form {
        const p = try c.webPage(a, page, failure);
        for (html.forms(a, p.html, p.url)) |f| {
            if (std.mem.eql(u8, f.actionPath(), action)) return f;
        }
        failure.* = .{ .kind = "unexpected", .message = "This library’s account settings page could not be read." };
        return error.Unexpected;
    }

    fn submitAccountForm(c: *Client, a: Allocator, form: html.Form, values: []const struct { []const u8, []const u8 }, failure: *Failure) Error!void {
        const res = try c.submitForm(a, form, values, failure);
        if (res.status < 200 or res.status >= 400) {
            failure.* = .{ .kind = "http", .status = res.status, .message = statusText(res.status) };
            return error.Http;
        }
        if (html.errorMessage(a, res.body)) |m| {
            failure.* = .{ .kind = "unexpected", .message = m };
            return error.Unexpected;
        }
    }

    // MARK: Catalog

    pub const SearchQuery = struct {
        query: []const u8,
        /// "smart" for keyword searches, "bl" for field-qualified (advanced) queries.
        searchType: []const u8 = "smart",
        /// Extra filters, e.g. `{"f_on_order": "true", "f_AUDIENCE": "adult"}`.
        filters: ?std.json.ArrayHashMap([]const u8) = null,
        page: i64 = 1,
        sort: ?[]const u8 = null,
        format: ?[]const u8 = null,
    };

    pub fn search(c: *Client, a: Allocator, q: SearchQuery, failure: *Failure) Error!models.ListPage {
        var body: std.Io.Writer.Allocating = .init(a);
        var w: std.json.Stringify = .{ .writer = &body.writer };
        writeSearchBody(&w, q, c.locale(a)) catch return error.OutOfMemory;
        // Signed in, the response also lists this account's holds and checkouts among the results.
        const j = try c.send(a, "POST", "bibs/search", &.{}, body.written(), !c.isGuest(), failure);
        return models.searchPage(a, j, q.page);
    }

    fn writeSearchBody(w: *std.json.Stringify, q: SearchQuery, locale_: []const u8) !void {
        try w.beginObject();
        try w.objectField("query");
        try w.write(q.query);
        try w.objectField("searchType");
        try w.write(q.searchType);
        try w.objectField("page");
        try w.write(q.page);
        try w.objectField("locale");
        try w.write(locale_);
        if (q.filters) |f| {
            var it = f.map.iterator();
            while (it.next()) |e| {
                try w.objectField(e.key_ptr.*);
                try w.write(e.value_ptr.*);
            }
        }
        if (q.sort) |s| {
            try w.objectField("sort");
            try w.write(s);
        }
        if (q.format) |f| {
            try w.objectField("f_FORMAT");
            try w.write(f);
        }
        try w.endObject();
    }

    pub fn availability(c: *Client, a: Allocator, metadata_id: []const u8, failure: *Failure) Error![]const models.CopyAvailability {
        const path = try std.fmt.allocPrint(a, "bibs/{s}/availability", .{metadata_id});
        return models.availability(a, try c.send(a, "GET", path, &.{}, null, false, failure));
    }

    pub fn detailFields(c: *Client, a: Allocator, metadata_id: []const u8, failure: *Failure) Error![]const models.DetailField {
        const path = try std.fmt.allocPrint(a, "catalogbibs/{s}", .{metadata_id});
        return models.detailFields(a, try c.send(a, "GET", path, &.{}, null, false, failure), metadata_id);
    }

    pub fn locations(c: *Client, a: Allocator, failure: *Failure) Error![]const models.Location {
        return models.locations(a, try c.send(a, "GET", "locations", &.{.{ "limit", "200" }}, null, false, failure));
    }

    // MARK: Borrowing

    pub fn borrowing(c: *Client, a: Allocator, kind: models.BorrowingKind, page: i64, sort: ?[]const u8, failure: *Failure) Error!models.ListPage {
        const p = try c.login(a, false, failure);
        const path = switch (kind) {
            .holds => "holds",
            .checkouts => "checkouts",
            .history => "borrowinghistory",
        };
        const account = try std.fmt.allocPrint(a, "{d}", .{p.accountId});
        const page_s = try std.fmt.allocPrint(a, "{d}", .{page});
        const j = if (sort) |s|
            try c.send(a, "GET", path, &.{ .{ "accountId", account }, .{ "page", page_s }, .{ "sort", s } }, null, true, failure)
        else
            try c.send(a, "GET", path, &.{ .{ "accountId", account }, .{ "page", page_s } }, null, true, failure);
        return models.borrowingPage(a, j, kind, page);
    }

    // MARK: Holds

    pub fn placeHold(c: *Client, a: Allocator, metadata_id: []const u8, material_type: []const u8, pickup_branch: ?[]const u8, failure: *Failure) Error!void {
        const p = try c.login(a, false, failure);
        var body: std.Io.Writer.Allocating = .init(a);
        std.json.Stringify.value(.{
            .metadataId = metadata_id,
            .materialType = material_type,
            .accountId = p.accountId,
            .enableSingleClickHolds = false,
            .materialParams = .{ .errorMessageLocale = c.locale(a), .branchId = pickup_branch orelse p.preferredPickup },
        }, .{ .emit_null_optional_fields = false }, &body.writer) catch return error.OutOfMemory;
        const j = try c.send(a, "POST", "holds", &.{}, body.written(), true, failure);
        if (j.get("failures").at(0).get("message").nonEmpty(a) orelse j.path("error.message").nonEmpty(a)) |m| {
            failure.* = .{ .kind = "unexpected", .message = m };
            return error.Unexpected;
        }
    }

    pub const HoldRef = struct { id: []const u8, metadataId: []const u8 };
    pub const Refusal = struct { holdId: []const u8, reason: []const u8 };

    /// Cancels holds and returns the ones the library refused, with its reason
    /// (some libraries don't allow cancelling holds that are ready for pickup).
    pub fn cancelHolds(c: *Client, a: Allocator, holds: []const HoldRef, failure: *Failure) Error![]const Refusal {
        const p = try c.login(a, false, failure);
        var hold_ids: std.ArrayList([]const u8) = .empty;
        var metadata_ids: std.ArrayList([]const u8) = .empty;
        for (holds) |h| {
            try hold_ids.append(a, h.id);
            try metadata_ids.append(a, h.metadataId);
        }
        var body: std.Io.Writer.Allocating = .init(a);
        std.json.Stringify.value(.{ .accountId = p.accountId, .holdIds = hold_ids.items, .metadataIds = metadata_ids.items }, .{}, &body.writer) catch return error.OutOfMemory;
        const j = try c.send(a, "DELETE", "holds", &.{}, body.written(), true, failure);
        const failures = j.get("failures").items();
        var refused: std.ArrayList(Refusal) = .empty;
        for (failures) |fv| {
            const f = J.of(fv);
            const reason = f.get("message").nonEmpty(a) orelse "The library didn’t cancel this hold.";
            const id = f.get("id").str(a) orelse f.get("holdId").str(a) orelse f.get("holdsId").str(a);
            var matched: ?HoldRef = null;
            if (id) |i| for (holds) |h| if (std.mem.eql(u8, h.id, i)) {
                matched = h;
            };
            if (matched) |h| {
                try refused.append(a, .{ .holdId = h.id, .reason = reason });
            } else if (failures.len == 1 and holds.len == 1) {
                try refused.append(a, .{ .holdId = holds[0].id, .reason = reason });
            } else {
                // Can't tell which hold failed: treat the whole request as refused.
                refused.clearRetainingCapacity();
                for (holds) |h| try refused.append(a, .{ .holdId = h.id, .reason = reason });
                return refused.items;
            }
        }
        return refused.items;
    }

    // MARK: Settings
    //
    // Account settings have no gateway endpoints; they are the Rails forms under /account/*
    // on the library's web host (same session cookies as the gateway login).

    pub const Settings = struct { email: ?[]const u8, pickup: ?[]const u8, language: ?[]const u8 };

    /// Current values as shown on the account settings pages.
    pub fn accountSettings(c: *Client, a: Allocator, failure: *Failure) Error!Settings {
        const email = try c.accountForm(a, "account/email", "/account/contact_information", failure);
        const pickup = try c.accountForm(a, "account/pickup_location", "/account/preferred_branches", failure);
        const language = try c.accountForm(a, "account/language", "/account/user_lang", failure);
        return .{
            .email = email.fields(a).get("user_email"),
            .pickup = pickup.fields(a).get("first_preference"),
            .language = language.fields(a).get("user_lang"),
        };
    }

    /// Sets the first preferred pickup location (used for new holds).
    pub fn setDefaultPickupLocation(c: *Client, a: Allocator, branch_id: []const u8, failure: *Failure) Error!void {
        const form = try c.accountForm(a, "account/pickup_location", "/account/preferred_branches", failure);
        var values: std.ArrayList(struct { []const u8, []const u8 }) = .empty;
        try values.append(a, .{ "first_preference", branch_id });
        // A branch can only appear once in the preference list.
        var current = form.fields(a);
        for ([_][]const u8{ "second_preference", "third_preference" }) |key| {
            if (current.get(key)) |v| if (std.mem.eql(u8, v, branch_id)) try values.append(a, .{ key, "" });
        }
        try c.submitAccountForm(a, form, values.items, failure);
        c.updatePatron("preferredPickup", branch_id);
    }

    pub fn changeLanguage(c: *Client, a: Allocator, code: []const u8, failure: *Failure) Error!void {
        const form = try c.accountForm(a, "account/language", "/account/user_lang", failure);
        try c.submitAccountForm(a, form, &.{.{ "user_lang", code }}, failure);
        c.setLanguage(code);
    }

    /// Turns the library's record of this account's borrowing history on or off (a gateway
    /// setting, unlike the Rails forms above).
    pub fn setBorrowingHistory(c: *Client, a: Allocator, enabled: bool, failure: *Failure) Error!void {
        const p = try c.login(a, false, failure);
        const path = try std.fmt.allocPrint(a, "accounts/{d}/settings/borrowingHistorySetting", .{p.accountId});
        _ = try c.send(a, "PUT", path, &.{}, if (enabled) "{\"enabled\":true}" else "{\"enabled\":false}", true, failure);
        c.updatePatron("borrowingHistoryEnabled", @as(?bool, enabled));
    }

    pub fn changeEmail(c: *Client, a: Allocator, email: []const u8, failure: *Failure) Error!void {
        const form = try c.accountForm(a, "account/email", "/account/contact_information", failure);
        try c.submitAccountForm(a, form, &.{.{ "user_email", email }}, failure);
        c.updatePatron("email", email);
    }

    /// Changes the PIN/password. The app must then save the new password, so automatic
    /// re-login keeps working.
    pub fn changePassword(c: *Client, a: Allocator, current: []const u8, new: []const u8, failure: *Failure) Error!void {
        const form = try c.accountForm(a, "account/password", "/account/change_pin", failure);
        try c.submitAccountForm(a, form, &.{ .{ "old_password", current }, .{ "new_password", new }, .{ "new_password_confirm", new } }, failure);
    }
};

/// The page's `<title>` for HTML, otherwise a name for the gateway endpoint.
pub fn fetchTitle(a: Allocator, url: []const u8, body: []const u8) []const u8 {
    if (html.title(a, body)) |t| return t;
    // Gateway paths look like /v2/libraries/{subdomain}/{endpoint}/…
    const path = html.urlPath(url);
    var parts: std.ArrayList([]const u8) = .empty;
    var it = std.mem.tokenizeScalar(u8, path, '/');
    while (it.next()) |p| parts.append(a, p) catch {};
    var rest = parts.items;
    for (parts.items, 0..) |p, i| if (std.mem.eql(u8, p, "libraries")) {
        rest = parts.items[@min(parts.items.len, i + 2)..];
        break;
    };
    if (rest.len == 0) return "";
    const first = rest[0];
    const eq = std.mem.eql;
    if (eq(u8, first, "bibs")) return if (eq(u8, rest[rest.len - 1], "availability")) "Availability" else "Search";
    if (eq(u8, first, "catalogbibs")) return "Item Details";
    if (eq(u8, first, "locations")) return "Locations";
    if (eq(u8, first, "holds")) return "Holds";
    if (eq(u8, first, "checkouts")) return "Checked Out";
    if (eq(u8, first, "borrowinghistory")) return "Borrowing History";
    if (eq(u8, first, "sessions")) return "Sign In";
    if (eq(u8, first, "accounts") or eq(u8, first, "users")) return "Account Settings";
    return std.mem.join(a, "/", rest) catch first;
}

fn statusText(status: u16) []const u8 {
    return switch (status) {
        400 => "Bad Request",
        401 => "Unauthorized",
        403 => "Forbidden",
        404 => "Not Found",
        409 => "Conflict",
        422 => "Unprocessable Content",
        429 => "Too Many Requests",
        500 => "Internal Server Error",
        502 => "Bad Gateway",
        503 => "Service Unavailable",
        504 => "Gateway Timeout",
        else => "The library returned an error.",
    };
}

/// Form and query encoding: unreserved characters as is, everything else (including `+`) as %XX.
pub fn percentEncode(a: Allocator, out: *std.ArrayList(u8), s: []const u8) !void {
    for (s) |ch| {
        if (std.ascii.isAlphanumeric(ch) or ch == '-' or ch == '_' or ch == '.' or ch == '~') {
            try out.append(a, ch);
        } else {
            try out.print(a, "%{X:0>2}", .{ch});
        }
    }
}

test "fetch titles" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("Availability", fetchTitle(a, "https://gateway.bibliocommons.com/v2/libraries/wccls/bibs/S1C1/availability?locale=en", ""));
    try std.testing.expectEqualStrings("Holds", fetchTitle(a, "https://gateway.bibliocommons.com/v2/libraries/wccls/holds?page=1", "{}"));
    try std.testing.expectEqualStrings("Email", fetchTitle(a, "https://wccls.bibliocommons.com/account/email", "<title>Email</title>"));
    var out: std.ArrayList(u8) = .empty;
    try percentEncode(a, &out, "a b+c&é");
    try std.testing.expectEqualStrings("a%20b%2Bc%26%C3%A9", out.items);
}
