//! A local log of the servers answering 429 or 5xx, as libbiblio saw them, kept across launches
//! in the user's state directory so a report can show how often it happens. Nothing is sent
//! anywhere: someone has to copy the report (About's Copy Diagnostic Log). Entries carry the
//! masked path and timing, never an account.

const std = @import("std");
const gtk = @import("gtk.zig");
const c = gtk.c;
const biblio = @import("biblio");
const capi = biblio.capi;

const gpa = std.heap.c_allocator;
const max_entries = 50;

/// The core's running total when this launch last merged, so only new incidents count.
var seen_total: i64 = 0;

fn path(a: std.mem.Allocator) ![:0]const u8 {
    const dir = std.mem.span(c.g_get_user_state_dir());
    return std.fmt.allocPrintSentinel(a, "{s}/biblio/throttle-log.json", .{dir}, 0);
}

const Saved = struct {
    total: i64 = 0,
    recent: std.ArrayList(std.json.Value) = .empty,
};

fn intOf(v: ?std.json.Value) i64 {
    return if (v) |value| switch (value) {
        .integer => |i| i,
        else => 0,
    } else 0;
}

fn load(a: std.mem.Allocator) Saved {
    var saved: Saved = .{};
    const p = path(a) catch return saved;
    var contents: [*c]c.gchar = null;
    var len: c.gsize = 0;
    if (c.g_file_get_contents(p.ptr, &contents, &len, null) == 0) return saved;
    defer c.g_free(contents);
    const v = std.json.parseFromSliceLeaky(std.json.Value, a, a.dupe(u8, contents[0..len]) catch return saved, .{}) catch return saved;
    if (v != .object) return saved;
    saved.total = intOf(v.object.get("total"));
    if (v.object.get("recent")) |recent| if (recent == .array) {
        saved.recent.appendSlice(a, recent.array.items) catch {};
    };
    return saved;
}

/// A key naming an entry, so the same incident merged twice counts once.
fn key(a: std.mem.Allocator, entry: std.json.Value) []const u8 {
    if (entry != .object) return "";
    const status = intOf(entry.object.get("status"));
    const at = intOf(entry.object.get("at"));
    const p = if (entry.object.get("path")) |v| if (v == .string) v.string else "" else "";
    return std.fmt.allocPrint(a, "{d}|{d}|{s}", .{ at, status, p }) catch "";
}

/// The core's incidents this launch, parsed in `a`.
fn current(a: std.mem.Allocator) struct { total: i64, recent: []const std.json.Value } {
    const text = capi.biblio_incidents() orelse return .{ .total = 0, .recent = &.{} };
    defer biblio.biblio_free(text);
    const v = std.json.parseFromSliceLeaky(std.json.Value, a, std.mem.span(text), .{}) catch return .{ .total = 0, .recent = &.{} };
    if (v != .object) return .{ .total = 0, .recent = &.{} };
    const recent = if (v.object.get("recent")) |r| if (r == .array) r.array.items else &.{} else &.{};
    return .{ .total = intOf(v.object.get("total")), .recent = recent };
}

/// Adds this launch's new incidents to the saved log; call when a window closes or the app quits.
pub fn sync() void {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const now = current(a);
    if (now.total <= seen_total) return;
    var saved = load(a);
    saved.total += now.total - seen_total;
    seen_total = now.total;
    var known: std.StringHashMapUnmanaged(void) = .empty;
    for (saved.recent.items) |e| known.put(a, key(a, e), {}) catch {};
    for (now.recent) |e| {
        if ((known.getOrPut(a, key(a, e)) catch continue).found_existing) continue;
        saved.recent.append(a, e) catch {};
    }
    const start = saved.recent.items.len -| max_entries;
    write(a, saved.total, saved.recent.items[start..]) catch {};
}

fn write(a: std.mem.Allocator, total: i64, recent: []const std.json.Value) !void {
    const p = try path(a);
    const dir = std.fs.path.dirname(p) orelse return;
    _ = c.g_mkdir_with_parents(gtk.z(a, dir), 0o700);
    var object: std.json.ObjectMap = .empty;
    try object.put(a, "total", .{ .integer = total });
    var array = std.json.Array.init(a);
    try array.appendSlice(recent);
    try object.put(a, "recent", .{ .array = array });
    const text = try std.json.Stringify.valueAlloc(a, std.json.Value{ .object = object }, .{ .whitespace = .indent_2 });
    _ = c.g_file_set_contents_full(p.ptr, text.ptr, @intCast(text.len), c.G_FILE_SET_CONTENTS_CONSISTENT, 0o600, null);
}

/// A JSON report: the app version, how many times in all, and the latest entries.
pub fn report(a: std.mem.Allocator) []const u8 {
    sync();
    const saved = load(a);
    var object: std.json.ObjectMap = .empty;
    const app = std.fmt.allocPrint(a, "Biblio {s}", .{std.mem.span(biblio.biblio_version())}) catch "Biblio";
    object.put(a, "app", .{ .string = app }) catch {};
    object.put(a, "total", .{ .integer = saved.total }) catch {};
    var array = std.json.Array.init(a);
    array.appendSlice(saved.recent.items) catch {};
    object.put(a, "recent", .{ .array = array }) catch {};
    return std.json.Stringify.valueAlloc(a, std.json.Value{ .object = object }, .{ .whitespace = .indent_2 }) catch "{}";
}

/// Puts the report on the clipboard.
pub fn copyReport() void {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const text = report(arena.allocator());
    const display = c.gdk_display_get_default() orelse return;
    c.gdk_clipboard_set_text(c.gdk_display_get_clipboard(display), gtk.z(arena.allocator(), text));
}
