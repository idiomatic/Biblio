//! The typed C interface: one function per operation, with C arguments and C structs in place
//! of JSON. See include/biblio.h for the declarations and docs/core.md for the contract.
//!
//! Results come back through an out-parameter as a single allocation owned by the result
//! (strings and arrays included), freed with that type's `biblio_<type>_free`. Failures return
//! a `biblio_result` code and, if the caller passes a `biblio_error`, a message for people.

const std = @import("std");
const Allocator = std.mem.Allocator;
const root = @import("root.zig");
const models = @import("models.zig");
const library = @import("library.zig");
const html = @import("html.zig");
const client_mod = @import("client.zig");
const Client = client_mod.Client;
const Failure = client_mod.Failure;
const sync = @import("sync.zig");

const gpa = sync.allocator;
const Handle = root.Handle;

// MARK: Types

pub const Result = enum(c_int) {
    ok = 0,
    sign_in_required,
    missing_credentials,
    login_failed,
    http,
    network,
    unexpected,
    not_a_library,
    bad_request,
    out_of_memory,

    fn fromKind(kind: []const u8) Result {
        const map = std.StaticStringMap(Result).initComptime(.{
            .{ "signInRequired", .sign_in_required }, .{ "missingCredentials", .missing_credentials },
            .{ "loginFailed", .login_failed },         .{ "http", .http },
            .{ "network", .network },                  .{ "notALibrary", .not_a_library },
            .{ "badRequest", .bad_request },           .{ "outOfMemory", .out_of_memory },
        });
        return map.get(kind) orelse .unexpected;
    }
};

pub const Error = extern struct {
    kind: Result = .ok,
    /// The HTTP status for `http` errors, else 0.
    status: c_int = 0,
    /// For people; allocated with biblio_alloc. Free with biblio_error_clear.
    message: ?[*:0]u8 = null,
};

pub const Pair = extern struct { key: [*:0]const u8, value: [*:0]const u8 };
const Str = [*:0]const u8;
const OptStr = ?[*:0]const u8;

pub const Bib = extern struct {
    id: Str,
    title: Str,
    subtitle: OptStr,
    authors: [*]const Str,
    authors_count: usize,
    format: Str,
    publication_date: OptStr,
    edition: OptStr,
    call_number: OptStr,
    summary: OptStr,
    jacket_small: OptStr,
    jacket_large: OptStr,
    material_type: Str,
    holdable: bool,
    status: OptStr,
    held_copies: i64,
    available_copies: i64,
    total_copies: i64,
    on_order_copies: i64,
};

pub const Hold = extern struct {
    id: Str,
    metadata_id: Str,
    status: Str,
    has_position: bool,
    position: i64,
    pickup_location: OptStr,
    expiry_date: OptStr,
    pickup_by_date: OptStr,
    suspend_end_date: OptStr,
    can_cancel: bool,
};

pub const Checkout = extern struct {
    id: Str,
    metadata_id: Str,
    status: OptStr,
    due_date: OptStr,
    checkout_date: OptStr,
    has_times_renewed: bool,
    times_renewed: i64,
};

pub const HistoryEntry = extern struct {
    id: Str,
    metadata_id: Str,
    checkout_date: OptStr,
    returned_date: OptStr,
};

pub const AccountStatus = extern struct {
    kind: Str,
    ready: bool,
    has_position: bool,
    position: i64,
    due: OptStr,
};

pub const ListEntry = extern struct {
    id: Str,
    bib: Bib,
    kind: Str,
    server_index: i64,
    hold: ?*const Hold,
    checkout: ?*const Checkout,
    history: ?*const HistoryEntry,
    account_status: ?*const AccountStatus,
};

pub const FacetValue = extern struct { value: Str, count: i64 };
pub const Facet = extern struct { id: Str, values: [*]const FacetValue, values_count: usize };

pub const ListPage = extern struct {
    owner: ?*anyopaque,
    entries: [*]const ListEntry,
    entries_count: usize,
    page: i64,
    pages: i64,
    count: i64,
    page_size: i64,
    facets: [*]const Facet,
    facets_count: usize,
    sort_options: [*]const Str,
    sort_options_count: usize,
    applied_sort: OptStr,
};

pub const Copy = extern struct {
    id: Str,
    branch: Str,
    status: Str,
    is_available: bool,
    collection: OptStr,
    call_number: OptStr,
    due_date: OptStr,
    is_on_order: bool,
    kind: Str,
};
pub const CopyList = extern struct { owner: ?*anyopaque, items: [*]const Copy, items_count: usize };

pub const DetailField = extern struct { label: Str, values: [*]const Str, values_count: usize };
pub const DetailList = extern struct { owner: ?*anyopaque, items: [*]const DetailField, items_count: usize };

pub const Location = extern struct { id: Str, name: Str };
pub const LocationList = extern struct { owner: ?*anyopaque, items: [*]const Location, items_count: usize };

pub const Patron = extern struct {
    owner: ?*anyopaque,
    user_id: i64,
    account_id: i64,
    name: Str,
    email: OptStr,
    language: Str,
    barcode: OptStr,
    preferred_pickup: OptStr,
    has_borrowing_history_enabled: bool,
    borrowing_history_enabled: bool,
};

pub const LibraryInfo = extern struct {
    owner: ?*anyopaque,
    subdomain: Str,
    name: Str,
    short_name: OptStr,
    primary_color: OptStr,
    website: OptStr,
    labels: [*]const Pair,
    labels_count: usize,
    languages: [*]const Str,
    languages_count: usize,
    users: [*]const Str,
    users_count: usize,
};

pub const DirectoryEntry = extern struct { name: Str, website: OptStr, region: OptStr, logo: OptStr };
pub const DirectoryPage = extern struct { owner: ?*anyopaque, entries: [*]const DirectoryEntry, entries_count: usize, next: OptStr };

pub const Refusal = extern struct { hold_id: Str, reason: Str };
pub const RefusalList = extern struct { owner: ?*anyopaque, items: [*]const Refusal, items_count: usize };

pub const AccountSettings = extern struct { owner: ?*anyopaque, email: OptStr, pickup: OptStr, language: OptStr };

pub const FetchStatus = extern struct { owner: ?*anyopaque, active: u32, title: OptStr, url: OptStr, bytes: u64 };

pub const SearchQuery = extern struct {
    query: Str,
    /// "smart" (NULL) or "bl".
    search_type: OptStr = null,
    filters: ?[*]const Pair = null,
    filter_count: usize = 0,
    /// 1-based; 0 means 1.
    page: i64 = 0,
    sort: OptStr = null,
    format: OptStr = null,
};

pub const HoldRef = extern struct { id: Str, metadata_id: Str };

// MARK: Converting Zig results to C structs

/// "metadata_id" → "metadataId"
fn camelCase(comptime name: []const u8) []const u8 {
    comptime var out: []const u8 = "";
    comptime var upper = false;
    inline for (name) |ch| {
        if (ch == '_') {
            upper = true;
        } else {
            out = out ++ [_]u8{if (upper) std.ascii.toUpper(ch) else ch};
            upper = false;
        }
    }
    return out;
}

fn length(v: anytype) usize {
    const V = @TypeOf(v);
    if (V == std.json.ArrayHashMap([]const u8)) return v.map.count();
    return v.len;
}

/// Converts a Zig struct to the C struct with the same fields in snake_case. Strings gain a NUL;
/// slices become a pointer plus `<name>_count`; optional numbers and booleans set `has_<name>`;
/// optional structs become nullable pointers.
fn convert(comptime Ext: type, a: Allocator, src: anytype) Allocator.Error!Ext {
    var out: Ext = undefined;
    const info = @typeInfo(Ext).@"struct";
    inline for (info.field_names, info.field_types) |name, T| {
        if (comptime std.mem.eql(u8, name, "owner")) {
            out.owner = null;
        } else if (comptime std.mem.startsWith(u8, name, "has_") or std.mem.endsWith(u8, name, "_count")) {
            // Set with the field they describe.
        } else {
            const v = @field(src, camelCase(name));
            @field(out, name) = try value(T, a, v);
            if (@hasField(Ext, "has_" ++ name)) @field(out, "has_" ++ name) = v != null;
            if (@hasField(Ext, name ++ "_count")) @field(out, name ++ "_count") = length(v);
        }
    }
    return out;
}

fn value(comptime D: type, a: Allocator, v: anytype) Allocator.Error!D {
    const V = @TypeOf(v);
    if (D == Str) return (try a.dupeSentinel(u8, v, 0)).ptr;
    if (D == OptStr) {
        if (V == []const u8) return (try a.dupeSentinel(u8, v, 0)).ptr;
        return if (v) |s| (try a.dupeSentinel(u8, s, 0)).ptr else null;
    }
    if (D == bool) return if (V == ?bool) v orelse false else v;
    if (D == i64 or D == u32 or D == u64) {
        return if (@typeInfo(V) == .optional) @intCast(v orelse 0) else @intCast(v);
    }
    if (D == [*]const Str) {
        const out = try a.alloc(Str, v.len);
        for (v, 0..) |s, i| out[i] = (try a.dupeSentinel(u8, s, 0)).ptr;
        return out.ptr;
    }
    if (D == [*]const Pair) {
        const out = try a.alloc(Pair, v.map.count());
        var it = v.map.iterator();
        var i: usize = 0;
        while (it.next()) |e| : (i += 1) {
            out[i] = .{ .key = (try a.dupeSentinel(u8, e.key_ptr.*, 0)).ptr, .value = (try a.dupeSentinel(u8, e.value_ptr.*, 0)).ptr };
        }
        return out.ptr;
    }
    switch (@typeInfo(D)) {
        .@"struct" => return convert(D, a, v),
        .pointer => |p| {
            const E = p.child;
            if (p.size == .many) {
                const out = try a.alloc(E, v.len);
                for (v, 0..) |item, i| out[i] = try convert(E, a, item);
                return out.ptr;
            }
        },
        .optional => |o| {
            const E = @typeInfo(o.child).pointer.child;
            const item = v orelse return null;
            const out = try a.create(E);
            out.* = try convert(E, a, item);
            return out;
        },
        else => {},
    }
    @compileError("no conversion from " ++ @typeName(V) ++ " to " ++ @typeName(D));
}

/// Builds a result in its own arena (recorded in `owner`) and hands it to the caller. A slice
/// becomes a list type's `items`.
fn deliver(comptime Ext: type, src: anytype, out: ?*?*Ext, err: ?*Error) Result {
    if (@hasField(Ext, "items") and @typeInfo(@TypeOf(src)) == .pointer) return deliver(Ext, .{ .items = src }, out, err);
    const arena = gpa.create(std.heap.ArenaAllocator) catch return outOfMemory(err);
    arena.* = .init(gpa);
    const result = arena.allocator().create(Ext) catch return releaseAnd(arena, err);
    result.* = convert(Ext, arena.allocator(), src) catch return releaseAnd(arena, err);
    result.owner = arena;
    if (out) |o| o.* = result else freeOwned(result);
    return .ok;
}

fn releaseAnd(arena: *std.heap.ArenaAllocator, err: ?*Error) Result {
    arena.deinit();
    gpa.destroy(arena);
    return outOfMemory(err);
}

fn freeOwned(result: ?*anyopaque) void {
    const p = result orelse return;
    // Every result struct starts with its `owner` arena.
    const owner: *?*anyopaque = @ptrCast(@alignCast(p));
    const arena: *std.heap.ArenaAllocator = @ptrCast(@alignCast(owner.* orelse return));
    arena.deinit();
    gpa.destroy(arena);
}

fn fail(err: ?*Error, f: Failure) Result {
    const kind = Result.fromKind(f.kind);
    if (err) |e| e.* = .{ .kind = kind, .status = if (f.status) |s| s else 0, .message = root.hostString(f.message) };
    return kind;
}

fn outOfMemory(err: ?*Error) Result {
    return fail(err, .{ .kind = "outOfMemory", .message = "Out of memory." });
}

fn badRequest(err: ?*Error, message: []const u8) Result {
    return fail(err, .{ .kind = "badRequest", .message = message });
}

fn opt(s: OptStr) ?[]const u8 {
    return if (s) |p| std.mem.span(p) else null;
}

fn labelsFrom(a: Allocator, labels: ?[*]const Pair, count: usize) std.json.Value {
    var map: std.json.ObjectMap = .empty;
    if (labels) |l| for (l[0..count]) |p| {
        map.put(a, std.mem.span(p.key), .{ .string = std.mem.span(p.value) }) catch {};
    };
    return .{ .object = map };
}

/// Scratch memory for one call, and the client it runs on.
const Work = struct {
    arena: std.heap.ArenaAllocator,
    failure: Failure = .{ .kind = "unexpected", .message = "Something went wrong." },

    fn init() Work {
        return .{ .arena = .init(gpa) };
    }
    fn deinit(w: *Work) void {
        w.arena.deinit();
    }
    fn a(w: *Work) Allocator {
        return w.arena.allocator();
    }
};

fn clientOf(h: ?*Handle, err: ?*Error) ?*Client {
    if (h) |x| return x.client;
    _ = badRequest(err, "This operation needs a client.");
    return null;
}

// MARK: Library operations (no client)

/// The catalog subdomain for what someone typed, or NULL. Free with biblio_free.
pub export fn biblio_subdomain_from(input: Str) ?[*:0]u8 {
    var w = Work.init();
    defer w.deinit();
    return root.hostString(library.subdomainFrom(w.a(), std.mem.span(input)) orelse return null);
}

pub export fn biblio_library_info(subdomain: Str, out: ?*?*LibraryInfo, err: ?*Error) Result {
    var w = Work.init();
    defer w.deinit();
    var message: []const u8 = "The library could not be reached.";
    const info = root.lookup().info(w.a(), std.mem.span(subdomain), &message) catch |e|
        return fail(err, .{ .kind = if (e == error.Transport) "network" else "notALibrary", .message = message });
    return deliver(LibraryInfo, info, out, err);
}

pub export fn biblio_library_exists(subdomain: Str) bool {
    var w = Work.init();
    defer w.deinit();
    return root.lookup().exists(w.a(), std.mem.span(subdomain));
}

/// `url` NULL for the first page, then each page's `next` until it is NULL.
pub export fn biblio_directory_page(url: OptStr, out: ?*?*DirectoryPage, err: ?*Error) Result {
    var w = Work.init();
    defer w.deinit();
    const page = root.lookup().directoryPage(w.a(), opt(url)) catch
        return fail(err, .{ .kind = "network", .message = "The library directory could not be loaded." });
    return deliver(DirectoryPage, page, out, err);
}

/// The catalog subdomain for a directory entry, or NULL. Free with biblio_free.
pub export fn biblio_resolve_subdomain(name: Str, website: OptStr) ?[*:0]u8 {
    var w = Work.init();
    defer w.deinit();
    return root.hostString(root.lookup().resolveSubdomain(w.a(), std.mem.span(name), opt(website)) orelse return null);
}

/// Free with biblio_free. `labels` may be NULL.
pub export fn biblio_format_name(code: Str, labels: ?[*]const Pair, label_count: usize) ?[*:0]u8 {
    var w = Work.init();
    defer w.deinit();
    return root.hostString(library.formatName(w.a(), .of(labelsFrom(w.a(), labels, label_count)), std.mem.span(code)));
}

/// Free with biblio_free. `labels` may be NULL.
pub export fn biblio_sort_name(id: Str, labels: ?[*]const Pair, label_count: usize) ?[*:0]u8 {
    var w = Work.init();
    defer w.deinit();
    return root.hostString(library.sortName(w.a(), .of(labelsFrom(w.a(), labels, label_count)), std.mem.span(id)));
}

/// "#RRGGBB", or NULL if `hex` isn't a color. Free with biblio_free.
pub export fn biblio_readable_tint(hex: Str, dark: bool) ?[*:0]u8 {
    var buf: [7]u8 = undefined;
    return root.hostString(library.readableTint(std.mem.span(hex), dark, &buf) orelse return null);
}

/// Bar and space widths in narrow units, bar first, or NULL. Free with biblio_free.
pub export fn biblio_codabar(value_: Str, count: *usize) ?[*]f64 {
    var w = Work.init();
    defer w.deinit();
    const widths = models.codabar(w.a(), std.mem.span(value_)) orelse return null;
    const mem = root.biblio_alloc(@max(1, widths.len) * @sizeOf(f64)) orelse return null;
    const out: [*]f64 = @ptrCast(@alignCast(mem));
    @memcpy(out[0..widths.len], widths);
    count.* = widths.len;
    return out;
}

/// The image's bytes in `*bytes` (free with biblio_free).
pub export fn biblio_fetch_image(url: Str, bytes: *?[*]u8, len: *usize, err: ?*Error) Result {
    var w = Work.init();
    defer w.deinit();
    const res = root.lookup().fetcher.fetch(w.a(), .{ .method = "GET", .url = std.mem.span(url) }) catch
        return fail(err, .{ .kind = "network", .message = "The image could not be loaded." });
    if (res.status != 200) return fail(err, .{ .kind = "http", .status = res.status, .message = "The image could not be loaded." });
    const mem = root.biblio_alloc(@max(1, res.body.len)) orelse return outOfMemory(err);
    @memcpy(mem[0..res.body.len], res.body);
    bytes.* = mem;
    len.* = res.body.len;
    return .ok;
}

// MARK: Client operations

/// Runs `method` on the handle's client with `args` (its arguments between the allocator and
/// the failure) and delivers the result as an `Ext`, or just success for `void`.
fn fetch(comptime Ext: type, h: ?*Handle, out: ?*?*Ext, err: ?*Error, comptime method: anytype, args: anytype) Result {
    const c = clientOf(h, err) orelse return .bad_request;
    var w = Work.init();
    defer w.deinit();
    const result = @call(.auto, method, .{ c, w.a() } ++ args ++ .{&w.failure}) catch return fail(err, w.failure);
    return if (Ext == void) .ok else deliver(Ext, result, out, err);
}

fn perform(h: ?*Handle, err: ?*Error, comptime method: anytype, args: anytype) Result {
    return fetch(void, h, null, err, method, args);
}

/// `language` NULL leaves it unchanged; `sample_account` < 0 leaves it unchanged.
pub export fn biblio_configure(h: ?*Handle, language: OptStr, sample_account: c_int) void {
    const c = (h orelse return).client;
    if (opt(language)) |l| c.setLanguage(l);
    if (sample_account >= 0) c.sample_account = sample_account != 0;
}

pub export fn biblio_status(h: ?*Handle, out: ?*?*FetchStatus, err: ?*Error) Result {
    const c = clientOf(h, err) orelse return .bad_request;
    var w = Work.init();
    defer w.deinit();
    c.status_mutex.lock();
    const status = .{
        .active = c.active.load(.monotonic),
        .title = if (c.status_title) |s| w.a().dupe(u8, s) catch null else null,
        .url = if (c.status_url) |s| w.a().dupe(u8, s) catch null else null,
        .bytes = c.status_bytes,
    };
    c.status_mutex.unlock();
    return deliver(FetchStatus, status, out, err);
}

pub export fn biblio_login(h: ?*Handle, force: bool, out: ?*?*Patron, err: ?*Error) Result {
    return fetch(Patron, h, out, err, Client.login, .{force});
}

/// The patron from the last sign-in, without contacting the library; `*out` is NULL if none.
pub export fn biblio_patron(h: ?*Handle, out: ?*?*Patron, err: ?*Error) Result {
    const c = clientOf(h, err) orelse return .bad_request;
    var w = Work.init();
    defer w.deinit();
    if (c.currentPatron(w.a())) |patron| return deliver(Patron, patron, out, err);
    if (out) |o| o.* = null;
    return .ok;
}

pub export fn biblio_search(h: ?*Handle, query: ?*const SearchQuery, out: ?*?*ListPage, err: ?*Error) Result {
    const q = query orelse return badRequest(err, "Search needs a query.");
    var filters: std.json.ArrayHashMap([]const u8) = .{};
    defer filters.map.deinit(gpa);
    if (q.filters) |f| for (f[0..q.filter_count]) |p| {
        filters.map.put(gpa, std.mem.span(p.key), std.mem.span(p.value)) catch return outOfMemory(err);
    };
    return fetch(ListPage, h, out, err, Client.search, .{Client.SearchQuery{
        .query = std.mem.span(q.query),
        .searchType = opt(q.search_type) orelse "smart",
        .filters = filters,
        .page = @max(1, q.page),
        .sort = opt(q.sort),
        .format = opt(q.format),
    }});
}

pub export fn biblio_availability(h: ?*Handle, metadata_id: Str, out: ?*?*CopyList, err: ?*Error) Result {
    return fetch(CopyList, h, out, err, Client.availability, .{std.mem.span(metadata_id)});
}

pub export fn biblio_details(h: ?*Handle, metadata_id: Str, out: ?*?*DetailList, err: ?*Error) Result {
    return fetch(DetailList, h, out, err, Client.detailFields, .{std.mem.span(metadata_id)});
}

pub export fn biblio_locations(h: ?*Handle, out: ?*?*LocationList, err: ?*Error) Result {
    return fetch(LocationList, h, out, err, Client.locations, .{});
}

/// `page` is 1-based (0 means 1); `sort` may be NULL.
pub export fn biblio_holds(h: ?*Handle, page: i64, sort: OptStr, out: ?*?*ListPage, err: ?*Error) Result {
    return fetch(ListPage, h, out, err, Client.borrowing, .{ models.BorrowingKind.holds, @max(1, page), opt(sort) });
}

pub export fn biblio_checkouts(h: ?*Handle, page: i64, sort: OptStr, out: ?*?*ListPage, err: ?*Error) Result {
    return fetch(ListPage, h, out, err, Client.borrowing, .{ models.BorrowingKind.checkouts, @max(1, page), opt(sort) });
}

pub export fn biblio_history(h: ?*Handle, page: i64, sort: OptStr, out: ?*?*ListPage, err: ?*Error) Result {
    return fetch(ListPage, h, out, err, Client.borrowing, .{ models.BorrowingKind.history, @max(1, page), opt(sort) });
}

/// `material_type` NULL means "PHYSICAL"; `pickup_branch` NULL uses the account's preferred branch.
pub export fn biblio_place_hold(h: ?*Handle, metadata_id: Str, material_type: OptStr, pickup_branch: OptStr, err: ?*Error) Result {
    return perform(h, err, Client.placeHold, .{ std.mem.span(metadata_id), opt(material_type) orelse "PHYSICAL", opt(pickup_branch) });
}

/// On success `*refused` lists the holds the library declined to cancel (often empty).
pub export fn biblio_cancel_holds(h: ?*Handle, holds: [*]const HoldRef, count: usize, refused: ?*?*RefusalList, err: ?*Error) Result {
    const refs = gpa.alloc(Client.HoldRef, count) catch return outOfMemory(err);
    defer gpa.free(refs);
    for (refs, holds[0..count]) |*r, ref| r.* = .{ .id = std.mem.span(ref.id), .metadataId = std.mem.span(ref.metadata_id) };
    return fetch(RefusalList, h, refused, err, Client.cancelHolds, .{refs});
}

pub export fn biblio_account_settings(h: ?*Handle, out: ?*?*AccountSettings, err: ?*Error) Result {
    return fetch(AccountSettings, h, out, err, Client.accountSettings, .{});
}

pub export fn biblio_set_pickup(h: ?*Handle, branch_id: Str, err: ?*Error) Result {
    return perform(h, err, Client.setDefaultPickupLocation, .{std.mem.span(branch_id)});
}

pub export fn biblio_set_language(h: ?*Handle, code: Str, err: ?*Error) Result {
    return perform(h, err, Client.changeLanguage, .{std.mem.span(code)});
}

pub export fn biblio_set_borrowing_history(h: ?*Handle, enabled: bool, err: ?*Error) Result {
    return perform(h, err, Client.setBorrowingHistory, .{enabled});
}

pub export fn biblio_change_email(h: ?*Handle, email: Str, err: ?*Error) Result {
    return perform(h, err, Client.changeEmail, .{std.mem.span(email)});
}

/// The app must then save the new password.
pub export fn biblio_change_password(h: ?*Handle, current: Str, new: Str, err: ?*Error) Result {
    return perform(h, err, Client.changePassword, .{ std.mem.span(current), std.mem.span(new) });
}

// MARK: Freeing

/// Frees any result struct (what `biblio_<type>_free` does), for Zig callers.
pub fn free(result: anytype) void {
    freeOwned(result);
}

pub export fn biblio_error_clear(err: ?*Error) void {
    const e = err orelse return;
    if (e.message) |m| root.biblio_free(m);
    e.* = .{};
}

comptime {
    const results = .{
        .{ "library_info", LibraryInfo },     .{ "directory_page", DirectoryPage }, .{ "fetch_status", FetchStatus },
        .{ "patron", Patron },                .{ "list_page", ListPage },           .{ "copy_list", CopyList },
        .{ "detail_list", DetailList },       .{ "location_list", LocationList },   .{ "refusal_list", RefusalList },
        .{ "account_settings", AccountSettings },
    };
    for (results) |r| {
        const T = r[1];
        const Free = struct {
            fn free(p: ?*T) callconv(.c) void {
                freeOwned(p);
            }
        };
        @export(&Free.free, .{ .name = "biblio_" ++ r[0] ++ "_free" });
    }
}

// MARK: Tests

test "typed results own their memory" {
    var err: Error = .{};
    var info: ?*LibraryInfo = null;
    // No network: an unknown operation fails the same way, so check conversions directly.
    const src: models.LibraryInfo = .{
        .subdomain = "wccls",
        .name = "Washington County",
        .labels = blk: {
            var m: std.json.ArrayHashMap([]const u8) = .{};
            try m.map.put(std.testing.allocator, "FORMAT.bk", "Book");
            break :blk m;
        },
        .languages = &.{ "en-US", "es-ES" },
    };
    defer {
        var m = src.labels;
        m.map.deinit(std.testing.allocator);
    }
    try std.testing.expectEqual(Result.ok, deliver(LibraryInfo, src, &info, &err));
    const i = info.?;
    defer biblio_library_info_free_test(i);
    try std.testing.expectEqualStrings("wccls", std.mem.span(i.subdomain));
    try std.testing.expect(i.short_name == null);
    try std.testing.expectEqual(@as(usize, 1), i.labels_count);
    try std.testing.expectEqualStrings("Book", std.mem.span(i.labels[0].value));
    try std.testing.expectEqual(@as(usize, 2), i.languages_count);
    try std.testing.expectEqualStrings("es-ES", std.mem.span(i.languages[1]));
}

fn biblio_library_info_free_test(p: *LibraryInfo) void {
    freeOwned(p);
}

test "list pages convert nested and optional fields" {
    const hold: models.Hold = .{ .id = "H1", .metadataId = "S1", .status = "READY_FOR_PICKUP", .position = null, .canCancel = true };
    const page: models.ListPage = .{
        .entries = &.{.{
            .id = "hold-H1",
            .bib = .{ .id = "S1", .title = "Dune", .authors = &.{"Herbert, Frank"} },
            .kind = "hold",
            .serverIndex = 0,
            .hold = hold,
            .accountStatus = .{ .kind = "onHold", .ready = true },
        }},
        .page = 1,
        .pages = 1,
        .count = 1,
        .facets = &.{.{ .id = "FORMAT", .values = &.{.{ .value = "BK", .count = 3 }} }},
        .sortOptions = &.{"status"},
    };
    var out: ?*ListPage = null;
    try std.testing.expectEqual(Result.ok, deliver(ListPage, page, &out, null));
    const p = out.?;
    defer freeOwned(p);
    try std.testing.expectEqual(@as(usize, 1), p.entries_count);
    const e = p.entries[0];
    try std.testing.expectEqualStrings("Dune", std.mem.span(e.bib.title));
    try std.testing.expectEqualStrings("Herbert, Frank", std.mem.span(e.bib.authors[0]));
    try std.testing.expect(!e.hold.?.has_position);
    try std.testing.expect(e.hold.?.can_cancel);
    try std.testing.expect(e.checkout == null);
    try std.testing.expect(e.account_status.?.ready);
    try std.testing.expectEqual(@as(i64, 3), p.facets[0].values[0].count);
    try std.testing.expectEqualStrings("status", std.mem.span(p.sort_options[0]));
    try std.testing.expect(p.applied_sort == null);
}

test "library helpers" {
    const sub = biblio_subdomain_from("https://smpl.bibliocommons.com/").?;
    defer root.biblio_free(sub);
    try std.testing.expectEqualStrings("smpl", std.mem.span(sub));
    try std.testing.expect(biblio_subdomain_from("www.bibliocommons.com") == null);
    const labels = [_]Pair{.{ .key = "FORMAT.bk", .value = "Libro" }};
    const name = biblio_format_name("BK", &labels, 1).?;
    defer root.biblio_free(name);
    try std.testing.expectEqualStrings("Libro", std.mem.span(name));
    var count: usize = 0;
    const widths = biblio_codabar("1", &count).?;
    defer root.biblio_free(widths);
    try std.testing.expectEqual(@as(usize, 23), count);
    try std.testing.expectEqual(@as(f64, 2.5), widths[2]);
    var err: Error = .{};
    try std.testing.expectEqual(Result.bad_request, biblio_holds(null, 1, null, null, &err));
    defer biblio_error_clear(&err);
    try std.testing.expectEqualStrings("This operation needs a client.", std.mem.span(err.message.?));
}
