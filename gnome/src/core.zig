//! Calls libbiblio's typed interface off the main thread and delivers results back on the
//! GTK main loop.

const std = @import("std");
const biblio = @import("biblio");
const gtk = @import("gtk.zig");
const c = gtk.c;
const store = @import("store.zig");

pub const capi = biblio.capi;
pub const gpa = std.heap.c_allocator;
pub const Client = biblio.Handle;

/// A finished call. `value` (the result struct, if the call has one) lives until the callback
/// returns, unless the callback takes it with `keep()`.
pub const Result = struct {
    ok: bool,
    message: []const u8,
    value: ?*anyopaque = null,
    /// Image bytes from `fetchImage`, or the string a string-returning function gave.
    bytes: []const u8 = &.{},
    /// What `fetchIcon` found.
    icon: biblio.icon.Kind = .none,
    kept: bool = false,

    /// The result struct, such as `capi.ListPage`.
    pub fn get(r: *const Result, comptime T: type) ?*T {
        return @ptrCast(@alignCast(r.value));
    }

    /// Keeps the result struct after the callback; free it with `release`.
    pub fn keep(r: *Result, comptime T: type) ?*T {
        r.kept = r.value != null;
        return r.get(T);
    }
};

/// Frees a result struct kept with `Result.keep`.
pub fn release(value: ?*anyopaque) void {
    capi.free(value);
}

pub const Callback = *const fn (ctx: ?*anyopaque, result: *Result) void;

/// One call in the background. Arguments are copied into the job (with `z` and `create`) so
/// they outlive the caller's memory.
pub const Job = struct {
    arena: std.heap.ArenaAllocator,
    callback: Callback,
    ctx: ?*anyopaque,
    result: capi.Result = .ok,
    err: capi.Error = .{},
    value: ?*anyopaque = null,
    bytes: ?[*]u8 = null,
    len: usize = 0,
    icon: biblio.icon.Kind = .none,

    pub fn create(callback: Callback, ctx: ?*anyopaque) ?*Job {
        const j = gpa.create(Job) catch return null;
        j.* = .{ .arena = .init(gpa), .callback = callback, .ctx = ctx };
        return j;
    }

    pub fn a(j: *Job) std.mem.Allocator {
        return j.arena.allocator();
    }

    /// A copy of `s` with a NUL, for a string argument.
    pub fn z(j: *Job, s: []const u8) [*:0]const u8 {
        const copied = j.a().dupeSentinel(u8, s, 0) catch return "";
        return copied.ptr;
    }

    pub fn optZ(j: *Job, s: ?[]const u8) ?[*:0]const u8 {
        return if (s) |v| j.z(v) else null;
    }

    /// A copy of `value`, for a struct argument passed by pointer.
    pub fn new(j: *Job, value: anytype) ?*const @TypeOf(value) {
        const p = j.a().create(@TypeOf(value)) catch return null;
        p.* = value;
        return p;
    }

    /// Runs `f`, a typed libbiblio function, with `args` (every argument before its result and
    /// error out-parameters) on a worker thread. Functions that return a string instead (such
    /// as `biblio_resolve_subdomain`) succeed when it isn't NULL.
    pub fn start(j: *Job, comptime f: anytype, args: anytype) void {
        const Run = struct {
            fn run(job: *Job, call_args: @TypeOf(args)) void {
                const info = @typeInfo(@TypeOf(f)).@"fn";
                const params = info.param_types;
                if (info.return_type.? == ?[*:0]u8) {
                    const s = @call(.auto, f, call_args);
                    job.result = if (s == null) .unexpected else .ok;
                    if (s) |p| {
                        job.bytes = p;
                        job.len = std.mem.len(p);
                    }
                } else if (params.len == call_args.len + 2) {
                    // ?*?*T: the result out-parameter.
                    const Out = @typeInfo(@typeInfo(params[call_args.len].?).optional.child).pointer.child;
                    var out: Out = null;
                    job.result = @call(.auto, f, call_args ++ .{ &out, &job.err });
                    job.value = out;
                } else {
                    job.result = @call(.auto, f, call_args ++ .{&job.err});
                }
                gtk.idle(deliver, job);
            }
        };
        j.spawn(Run.run, .{ j, args });
    }

    /// Fetches image bytes through the core (paced like other library requests).
    pub fn fetchImage(j: *Job, url: []const u8) void {
        const Run = struct {
            fn run(job: *Job, u: [*:0]const u8) void {
                job.result = capi.biblio_fetch_image(u, &job.bytes, &job.len, &job.err);
                gtk.idle(deliver, job);
            }
        };
        j.spawn(Run.run, .{ j, j.z(url) });
    }

    /// Looks up a library's icon through the core (see `biblio_library_icon`): its kind in
    /// `Result.icon` and its bytes in `Result.bytes`.
    pub fn fetchIcon(j: *Job, website: ?[]const u8, subdomain: ?[]const u8, logo: ?[]const u8) void {
        const Run = struct {
            fn run(job: *Job, w: ?[*:0]const u8, s: ?[*:0]const u8, l: ?[*:0]const u8) void {
                job.icon = capi.biblio_library_icon(w, s, l, &job.bytes, &job.len);
                gtk.idle(deliver, job);
            }
        };
        j.spawn(Run.run, .{ j, j.optZ(website), j.optZ(subdomain), j.optZ(logo) });
    }

    fn spawn(j: *Job, comptime run: anytype, args: anytype) void {
        const thread = std.Thread.spawn(.{}, run, args) catch {
            j.result = .out_of_memory;
            gtk.idle(deliver, j);
            return;
        };
        thread.detach();
    }
};

fn deliver(data: ?*anyopaque) callconv(.c) c.gboolean {
    const job: *Job = @ptrCast(@alignCast(data.?));
    defer {
        if (job.bytes) |b| biblio.biblio_free(b);
        capi.biblio_error_clear(&job.err);
        job.arena.deinit();
        gpa.destroy(job);
    }
    var result: Result = .{
        .ok = job.result == .ok,
        .message = if (job.err.message) |m| std.mem.span(m) else "Biblio couldn’t reach its library engine.",
        .value = job.value,
        .bytes = if (job.bytes) |b| b[0..job.len] else &.{},
        .icon = job.icon,
    };
    job.callback(job.ctx, &result);
    if (!result.kept) release(result.value);
    return 0; // G_SOURCE_REMOVE
}

/// Creates a client whose password comes from the Secret Service.
pub fn client(subdomain: []const u8, username: []const u8) ?*Client {
    const sd = gpa.dupeSentinel(u8, subdomain, 0) catch return null;
    defer gpa.free(sd);
    const un = gpa.dupeSentinel(u8, username, 0) catch return null;
    defer gpa.free(un);
    return biblio.biblio_client_new(sd.ptr, un.ptr, password, null);
}

fn password(_: ?*anyopaque, subdomain: [*:0]const u8, username: [*:0]const u8) callconv(.c) ?[*:0]u8 {
    const secret = store.lookupPassword(std.mem.span(subdomain), std.mem.span(username)) orelse return null;
    defer store.freePassword(secret);
    const s = std.mem.span(secret);
    const out = biblio.biblio_alloc(s.len + 1) orelse return null;
    @memcpy(out[0..s.len], s);
    out[s.len] = 0;
    return @ptrCast(@alignCast(out));
}

// MARK: Reading results

/// A C string from a result as a slice.
pub fn str(s: ?[*:0]const u8) ?[]const u8 {
    return if (s) |p| std.mem.span(p) else null;
}

/// A result array as a slice.
pub fn items(comptime T: type, ptr: [*]const T, count: usize) []const T {
    return if (count == 0) &.{} else ptr[0..count];
}

/// A deep copy of a result struct (or any value made of its parts) into `a`, so it outlives
/// the result it came from.
pub fn copy(a: std.mem.Allocator, value: anytype) @TypeOf(value) {
    const T = @TypeOf(value);
    if (T == [*:0]const u8) {
        const copied = a.dupeSentinel(u8, std.mem.span(value), 0) catch return "";
        return copied.ptr;
    }
    switch (@typeInfo(T)) {
        .@"struct" => |info| {
            var out = value;
            inline for (info.field_names, info.field_types) |name, F| {
                if (comptime std.mem.eql(u8, name, "owner")) {
                    out.owner = null;
                } else if (comptime std.mem.endsWith(u8, name, "_count")) {
                    // Set with its array.
                } else if (@typeInfo(F) == .pointer and @typeInfo(F).pointer.size == .many and F != [*:0]const u8) {
                    // An array with a `<name>_count`.
                    const E = @typeInfo(F).pointer.child;
                    const src = items(E, @field(value, name), @field(value, name ++ "_count"));
                    const dst: []E = a.alloc(E, src.len) catch &.{};
                    for (dst, src) |*d, s| d.* = copy(a, s);
                    @field(out, name) = dst.ptr;
                    @field(out, name ++ "_count") = dst.len;
                } else {
                    @field(out, name) = copy(a, @field(value, name));
                }
            }
            return out;
        },
        .optional => return if (value) |v| copy(a, v) else null,
        .pointer => |p| {
            // A single nested struct.
            const dst = a.create(p.child) catch return value;
            dst.* = copy(a, value.*);
            return dst;
        },
        else => return value,
    }
}

// MARK: Display helpers (no network)

/// The library's name for a format code ("Blu-ray Disc"), copied into `a`.
pub fn formatName(a: std.mem.Allocator, code: []const u8, labels: []const capi.Pair) []const u8 {
    const z = a.dupeSentinel(u8, code, 0) catch return code;
    return take(a, capi.biblio_format_name(z.ptr, labels.ptr, labels.len)) orelse code;
}

pub fn sortName(a: std.mem.Allocator, id: []const u8, labels: []const capi.Pair) []const u8 {
    const z = a.dupeSentinel(u8, id, 0) catch return id;
    return take(a, capi.biblio_sort_name(z.ptr, labels.ptr, labels.len)) orelse id;
}

/// "wccls" from "WCCLS", "https://smpl.bibliocommons.com/", ...
pub fn subdomainFrom(a: std.mem.Allocator, input: []const u8) ?[]const u8 {
    const z = a.dupeSentinel(u8, input, 0) catch return null;
    return take(a, capi.biblio_subdomain_from(z.ptr));
}

/// Codabar bar and space widths, bar first; empty if the value can't be encoded.
pub fn codabar(a: std.mem.Allocator, value: []const u8) []const f64 {
    const z = a.dupeSentinel(u8, value, 0) catch return &.{};
    var count: usize = 0;
    const widths = capi.biblio_codabar(z.ptr, &count) orelse return &.{};
    defer biblio.biblio_free(widths);
    return a.dupe(f64, widths[0..count]) catch &.{};
}

/// Copies a string the core allocated into `a` and frees it.
fn take(a: std.mem.Allocator, s: ?[*:0]u8) ?[]const u8 {
    const p = s orelse return null;
    defer biblio.biblio_free(p);
    return a.dupe(u8, std.mem.span(p)) catch null;
}
