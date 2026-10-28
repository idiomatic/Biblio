//! Added libraries and their usernames, saved as JSON in $XDG_CONFIG_HOME/biblio/tui.json
//! (or ~/.config/biblio/tui.json). Passwords are never saved: the app asks for one when it
//! signs in and keeps it in memory only while that account is open.

const std = @import("std");
const LibraryInfo = @import("biblio").models.LibraryInfo;

pub const Store = struct {
    io: std.Io,
    /// Holds every library ever loaded or added; it only grows, and the list is small.
    arena: std.heap.ArenaAllocator,
    path: []const u8,
    libraries: std.ArrayList(LibraryInfo) = .empty,

    pub fn load(io: std.Io, gpa: std.mem.Allocator, env: *const std.process.Environ.Map) Store {
        var s: Store = .{ .io = io, .arena = .init(gpa), .path = "" };
        const a = s.arena.allocator();
        s.path = if (env.get("XDG_CONFIG_HOME")) |dir|
            std.fs.path.join(a, &.{ dir, "biblio", "tui.json" }) catch ""
        else
            std.fs.path.join(a, &.{ env.get("HOME") orelse ".", ".config", "biblio", "tui.json" }) catch "";
        const text = std.Io.Dir.cwd().readFileAlloc(io, s.path, a, .limited(1 << 20)) catch return s;
        const list = std.json.parseFromSliceLeaky([]LibraryInfo, a, text, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch return s;
        s.libraries.appendSlice(a, list) catch {};
        return s;
    }

    fn save(s: *Store) void {
        const a = s.arena.allocator();
        const text = std.json.Stringify.valueAlloc(a, s.libraries.items, .{ .whitespace = .indent_2, .emit_null_optional_fields = false }) catch return;
        if (std.fs.path.dirname(s.path)) |dir| std.Io.Dir.cwd().createDirPath(s.io, dir) catch {};
        std.Io.Dir.cwd().writeFile(s.io, .{ .sub_path = s.path, .data = text }) catch {};
    }

    pub fn find(s: *const Store, subdomain: []const u8) ?usize {
        for (s.libraries.items, 0..) |lib, i| if (std.mem.eql(u8, lib.subdomain, subdomain)) return i;
        return null;
    }

    /// Adds a library from the core's `LibraryInfo` (copied), or updates it, keeping its users.
    pub fn upsert(s: *Store, info: LibraryInfo) void {
        const a = s.arena.allocator();
        const text = std.json.Stringify.valueAlloc(a, info, .{}) catch return;
        var copy = std.json.parseFromSliceLeaky(LibraryInfo, a, text, .{ .allocate = .alloc_always }) catch return;
        if (s.find(info.subdomain)) |i| {
            copy.users = s.libraries.items[i].users;
            s.libraries.items[i] = copy;
        } else {
            copy.users = &.{};
            s.libraries.append(a, copy) catch return;
        }
        s.save();
    }

    pub fn remove(s: *Store, index: usize) void {
        _ = s.libraries.orderedRemove(index);
        s.save();
    }

    pub fn addUser(s: *Store, index: usize, username: []const u8) void {
        const a = s.arena.allocator();
        const lib = &s.libraries.items[index];
        for (lib.users) |u| if (std.mem.eql(u8, u, username)) return;
        const users = a.alloc([]const u8, lib.users.len + 1) catch return;
        @memcpy(users[0..lib.users.len], lib.users);
        users[lib.users.len] = a.dupe(u8, username) catch return;
        lib.users = users;
        s.save();
    }

    pub fn removeUser(s: *Store, index: usize, username: []const u8) void {
        const a = s.arena.allocator();
        const lib = &s.libraries.items[index];
        var users: std.ArrayList([]const u8) = .empty;
        for (lib.users) |u| if (!std.mem.eql(u8, u, username)) users.append(a, u) catch {};
        lib.users = users.items;
        s.save();
    }
};
