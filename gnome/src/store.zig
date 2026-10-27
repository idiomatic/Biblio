//! Added libraries and their usernames, saved as JSON in the user's config directory.
//! Passwords live in the Secret Service (GNOME Keyring), one item per library and username.

const std = @import("std");
const gtk = @import("gtk.zig");
const c = gtk.c;

const gpa = std.heap.c_allocator;

/// Libraries as the core describes them (`libraryInfo`), each with a `users` array.
/// Values live in `arena`, which only grows; the list is small and edited rarely.
var arena_state = std.heap.ArenaAllocator.init(gpa);
pub var libraries: std.ArrayList(std.json.Value) = .empty;
var loaded = false;

fn arena() std.mem.Allocator {
    return arena_state.allocator();
}

fn path(a: std.mem.Allocator) ![:0]const u8 {
    const dir = std.mem.span(c.g_get_user_config_dir());
    return std.fmt.allocPrintSentinel(a, "{s}/biblio/libraries.json", .{dir}, 0);
}

pub fn load() void {
    if (loaded) return;
    loaded = true;
    const p = path(arena()) catch return;
    var contents: [*c]c.gchar = null;
    var len: c.gsize = 0;
    if (c.g_file_get_contents(p.ptr, &contents, &len, null) == 0) return;
    defer c.g_free(contents);
    const v = std.json.parseFromSliceLeaky(std.json.Value, arena(), arena().dupe(u8, contents[0..len]) catch return, .{}) catch return;
    if (v != .array) return;
    for (v.array.items) |lib| if (lib == .object) libraries.append(gpa, lib) catch {};
}

fn save() void {
    const p = path(arena()) catch return;
    const dir = std.fs.path.dirname(p) orelse return;
    _ = c.g_mkdir_with_parents(gtk.z(arena(), dir), 0o700);
    const text = std.json.Stringify.valueAlloc(gpa, libraries.items, .{ .whitespace = .indent_2 }) catch return;
    defer gpa.free(text);
    _ = c.g_file_set_contents(p.ptr, text.ptr, @intCast(text.len), null);
}

pub fn subdomain(lib: std.json.Value) []const u8 {
    return if (lib.object.get("subdomain")) |s| if (s == .string) s.string else "" else "";
}

pub fn name(lib: std.json.Value) []const u8 {
    return if (lib.object.get("name")) |s| if (s == .string) s.string else subdomain(lib) else subdomain(lib);
}

pub fn shortName(lib: std.json.Value) []const u8 {
    return if (lib.object.get("shortName")) |s| if (s == .string) s.string else name(lib) else name(lib);
}

pub fn users(lib: std.json.Value) []const std.json.Value {
    const u = lib.object.get("users") orelse return &.{};
    return if (u == .array) u.array.items else &.{};
}

pub fn find(sub: []const u8) ?usize {
    for (libraries.items, 0..) |lib, i| if (std.mem.eql(u8, subdomain(lib), sub)) return i;
    return null;
}

/// Adds a library from a `libraryInfo` result (deep-copied), or updates it, keeping its users.
pub fn upsert(info: std.json.Value) void {
    var copy = deepCopy(info) catch return;
    if (find(subdomain(copy))) |i| {
        copy.object.put(arena(), "users", libraries.items[i].object.get("users") orelse .{ .array = .init(arena()) }) catch {};
        libraries.items[i] = copy;
    } else {
        copy.object.put(arena(), "users", .{ .array = .init(arena()) }) catch {};
        libraries.append(gpa, copy) catch {};
    }
    save();
}

/// Removes a library and its saved passwords.
pub fn remove(sub: []const u8) void {
    const i = find(sub) orelse return;
    for (users(libraries.items[i])) |u| if (u == .string) clearPassword(sub, u.string);
    _ = libraries.orderedRemove(i);
    save();
}

pub fn addUser(sub: []const u8, username: []const u8) void {
    const i = find(sub) orelse return;
    for (users(libraries.items[i])) |u| if (u == .string and std.mem.eql(u8, u.string, username)) return;
    var list = std.json.Array.init(arena());
    for (users(libraries.items[i])) |u| list.append(u) catch {};
    list.append(.{ .string = arena().dupe(u8, username) catch return }) catch {};
    libraries.items[i].object.put(arena(), "users", .{ .array = list }) catch {};
    save();
}

pub fn removeUser(sub: []const u8, username: []const u8) void {
    const i = find(sub) orelse return;
    var list = std.json.Array.init(arena());
    for (users(libraries.items[i])) |u| {
        if (!(u == .string and std.mem.eql(u8, u.string, username))) list.append(u) catch {};
    }
    libraries.items[i].object.put(arena(), "users", .{ .array = list }) catch {};
    clearPassword(sub, username);
    save();
}

fn deepCopy(v: std.json.Value) !std.json.Value {
    const text = try std.json.Stringify.valueAlloc(gpa, v, .{});
    defer gpa.free(text);
    return std.json.parseFromSliceLeaky(std.json.Value, arena(), try arena().dupe(u8, text), .{});
}

// MARK: Secret Service

var schema: c.SecretSchema = undefined;
var schema_ready = false;

fn secretSchema() *const c.SecretSchema {
    if (!schema_ready) {
        schema = std.mem.zeroes(c.SecretSchema);
        schema.name = "com.rbrian.Biblio";
        schema.flags = c.SECRET_SCHEMA_NONE;
        schema.attributes[0] = .{ .name = "subdomain", .type = c.SECRET_SCHEMA_ATTRIBUTE_STRING };
        schema.attributes[1] = .{ .name = "username", .type = c.SECRET_SCHEMA_ATTRIBUTE_STRING };
        schema_ready = true;
    }
    return &schema;
}

/// Attributes identifying one saved password. Free with g_hash_table_unref.
fn attributes(sub: [:0]const u8, username: [:0]const u8) *c.GHashTable {
    const table = c.g_hash_table_new(c.g_str_hash, c.g_str_equal).?;
    _ = c.g_hash_table_insert(table, @constCast(@ptrCast(@alignCast("subdomain"))), @constCast(@ptrCast(@alignCast(sub.ptr))));
    _ = c.g_hash_table_insert(table, @constCast(@ptrCast(@alignCast("username"))), @constCast(@ptrCast(@alignCast(username.ptr))));
    return table;
}

/// The saved password, or null. Free with `freePassword`. Called from worker threads.
pub fn lookupPassword(sub: []const u8, username: []const u8) ?[*:0]u8 {
    const s = gpa.dupeSentinel(u8, sub, 0) catch return null;
    defer gpa.free(s);
    const u = gpa.dupeSentinel(u8, username, 0) catch return null;
    defer gpa.free(u);
    const attrs = attributes(s, u);
    defer c.g_hash_table_unref(attrs);
    var err: ?*c.GError = null;
    const p = c.secret_password_lookupv_sync(secretSchema(), attrs, null, &err);
    if (err) |e| c.g_error_free(e);
    return if (p) |ptr| @ptrCast(@alignCast(ptr)) else null;
}

pub fn freePassword(p: [*:0]u8) void {
    c.secret_password_free(p);
}

pub fn storePassword(sub: []const u8, username: []const u8, password: []const u8) bool {
    var a = std.heap.ArenaAllocator.init(gpa);
    defer a.deinit();
    const s = a.allocator().dupeSentinel(u8, sub, 0) catch return false;
    const u = a.allocator().dupeSentinel(u8, username, 0) catch return false;
    const label = std.fmt.allocPrintSentinel(a.allocator(), "Biblio – {s}.bibliocommons.com ({s})", .{ sub, username }, 0) catch return false;
    const pw = a.allocator().dupeSentinel(u8, password, 0) catch return false;
    defer std.crypto.secureZero(u8, pw);
    const attrs = attributes(s, u);
    defer c.g_hash_table_unref(attrs);
    var err: ?*c.GError = null;
    const ok = c.secret_password_storev_sync(secretSchema(), attrs, c.SECRET_COLLECTION_DEFAULT, label.ptr, pw.ptr, null, &err);
    if (err) |e| c.g_error_free(e);
    return ok != 0;
}

pub fn clearPassword(sub: []const u8, username: []const u8) void {
    var a = std.heap.ArenaAllocator.init(gpa);
    defer a.deinit();
    const s = a.allocator().dupeSentinel(u8, sub, 0) catch return;
    const u = a.allocator().dupeSentinel(u8, username, 0) catch return;
    const attrs = attributes(s, u);
    defer c.g_hash_table_unref(attrs);
    _ = c.secret_password_clearv_sync(secretSchema(), attrs, null, null);
}
