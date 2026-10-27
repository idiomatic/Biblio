//! Calls into libbiblio off the main thread and delivers results back on the GTK main loop.

const std = @import("std");
const biblio = @import("biblio");
const gtk = @import("gtk.zig");
const c = gtk.c;
const store = @import("store.zig");

pub const gpa = std.heap.c_allocator;
pub const Client = biblio.Handle;

/// A finished call. `value` (the result) and `message` live in `arena` until the callback returns,
/// unless the callback takes the arena with `keep()`.
pub const Result = struct {
    arena: *std.heap.ArenaAllocator,
    ok: bool,
    value: std.json.Value,
    message: []const u8,
    kept: bool = false,

    /// Keeps the result's memory alive after the callback; free it with `release`.
    pub fn keep(r: *Result) *std.heap.ArenaAllocator {
        r.kept = true;
        return r.arena;
    }

    pub fn get(r: Result, key: []const u8) ?std.json.Value {
        return switch (r.value) {
            .object => |o| o.get(key),
            else => null,
        };
    }
};

pub fn release(arena: *std.heap.ArenaAllocator) void {
    arena.deinit();
    gpa.destroy(arena);
}

pub const Callback = *const fn (ctx: ?*anyopaque, result: *Result) void;

const Job = struct {
    client: ?*Client,
    request: [:0]u8,
    callback: Callback,
    ctx: ?*anyopaque,
    response: ?[*:0]u8 = null,
};

/// Runs `request` (any value that serializes to a JSON object) in the background.
pub fn call(handle: ?*Client, request: anytype, callback: Callback, ctx: ?*anyopaque) void {
    const text = std.json.Stringify.valueAlloc(gpa, request, .{ .emit_null_optional_fields = false }) catch return;
    defer gpa.free(text);
    const job = gpa.create(Job) catch return;
    job.* = .{
        .client = handle,
        .request = gpa.dupeSentinel(u8, text, 0) catch return,
        .callback = callback,
        .ctx = ctx,
    };
    const thread = std.Thread.spawn(.{}, run, .{job}) catch {
        job.response = null;
        gtk.idle(deliver, job);
        return;
    };
    thread.detach();
}

fn run(job: *Job) void {
    job.response = biblio.biblio_call(job.client, job.request.ptr);
    gtk.idle(deliver, job);
}

fn deliver(data: ?*anyopaque) callconv(.c) c.gboolean {
    const job: *Job = @ptrCast(@alignCast(data.?));
    defer {
        if (job.response) |r| biblio.biblio_free(r);
        gpa.free(job.request);
        gpa.destroy(job);
    }
    const arena = gpa.create(std.heap.ArenaAllocator) catch return 0;
    arena.* = .init(gpa);
    var result: Result = .{ .arena = arena, .ok = false, .value = .null, .message = "Biblio couldn’t reach its library engine." };
    if (job.response) |r| {
        const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), std.mem.span(r), .{}) catch .null;
        if (parsed == .object) {
            const o = parsed.object;
            result.ok = if (o.get("ok")) |v| v == .bool and v.bool else false;
            result.value = o.get("result") orelse .null;
            if (o.get("error")) |e| if (e == .object) if (e.object.get("message")) |m| if (m == .string) {
                result.message = m.string;
            };
        }
    }
    job.callback(job.ctx, &result);
    if (!result.kept) release(arena);
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

pub fn str(v: ?std.json.Value, key: []const u8) ?[]const u8 {
    const val = v orelse return null;
    if (val != .object) return null;
    const f = val.object.get(key) orelse return null;
    return switch (f) {
        .string => |s| s,
        else => null,
    };
}

pub fn int(v: ?std.json.Value, key: []const u8) ?i64 {
    const val = v orelse return null;
    if (val != .object) return null;
    const f = val.object.get(key) orelse return null;
    return switch (f) {
        .integer => |i| i,
        .float => |x| @intFromFloat(x),
        else => null,
    };
}

pub fn boolean(v: ?std.json.Value, key: []const u8) ?bool {
    const val = v orelse return null;
    if (val != .object) return null;
    const f = val.object.get(key) orelse return null;
    return if (f == .bool) f.bool else null;
}

pub fn field(v: ?std.json.Value, key: []const u8) ?std.json.Value {
    const val = v orelse return null;
    if (val != .object) return null;
    const f = val.object.get(key) orelse return null;
    return if (f == .null) null else f;
}

pub fn items(v: ?std.json.Value) []const std.json.Value {
    const val = v orelse return &.{};
    return if (val == .array) val.array.items else &.{};
}

/// Runs a call that needs no network synchronously (display helpers such as formatName).
pub fn now(a: std.mem.Allocator, request: anytype) ?std.json.Value {
    const text = std.json.Stringify.valueAlloc(a, request, .{ .emit_null_optional_fields = false }) catch return null;
    const z = a.dupeSentinel(u8, text, 0) catch return null;
    const out = biblio.biblio_call(null, z.ptr) orelse return null;
    defer biblio.biblio_free(out);
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, a, a.dupe(u8, std.mem.span(out)) catch return null, .{}) catch return null;
    return field(parsed, "result");
}
