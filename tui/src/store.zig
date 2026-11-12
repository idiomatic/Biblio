//! Added libraries and their usernames, saved as JSON in $XDG_CONFIG_HOME/biblio/tui.json
//! (or ~/.config/biblio/tui.json). Passwords are never saved: the app asks for one when it
//! signs in and keeps it in memory only while that account is open.
//!
//! What each user borrowed before (the core's borrowed index) is a cache, kept private in
//! $XDG_CACHE_HOME/biblio/borrowed/SUBDOMAIN/USERNAME.json (or ~/.cache/…), where backups
//! don't look, and deleted with the user or library.

const std = @import("std");
const LibraryInfo = @import("biblio").models.LibraryInfo;

const private_dir: std.Io.File.Permissions = .fromMode(0o700);
const private_file: std.Io.File.Permissions = .fromMode(0o600);

pub const Store = struct {
    io: std.Io,
    /// Holds every library ever loaded or added; it only grows, and the list is small.
    arena: std.heap.ArenaAllocator,
    path: []const u8,
    /// The borrowed indexes' directory.
    borrowed_dir: []const u8 = "",
    libraries: std.ArrayList(LibraryInfo) = .empty,

    pub fn load(io: std.Io, gpa: std.mem.Allocator, env: *const std.process.Environ.Map) Store {
        var s: Store = .{ .io = io, .arena = .init(gpa), .path = "" };
        const a = s.arena.allocator();
        s.path = if (env.get("XDG_CONFIG_HOME")) |dir|
            std.fs.path.join(a, &.{ dir, "biblio", "tui.json" }) catch ""
        else
            std.fs.path.join(a, &.{ env.get("HOME") orelse ".", ".config", "biblio", "tui.json" }) catch "";
        s.borrowed_dir = if (env.get("XDG_CACHE_HOME")) |dir|
            std.fs.path.join(a, &.{ dir, "biblio", "borrowed" }) catch ""
        else
            std.fs.path.join(a, &.{ env.get("HOME") orelse ".", ".cache", "biblio", "borrowed" }) catch "";
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
        const lib = s.libraries.orderedRemove(index);
        s.save();
        const dir = std.fs.path.join(s.arena.allocator(), &.{ s.borrowed_dir, lib.subdomain }) catch return;
        std.Io.Dir.cwd().deleteTree(s.io, dir) catch {};
    }

    // Borrowed indexes

    /// A user's borrowed index file, its username escaped to a file name.
    pub fn borrowedPath(s: *const Store, a: std.mem.Allocator, subdomain: []const u8, username: []const u8) []const u8 {
        var name: std.ArrayList(u8) = .empty;
        for (username, 0..) |c, i| {
            if (std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or (c == '.' and i > 0))
                name.append(a, c) catch return ""
            else
                name.print(a, "%{X:0>2}", .{c}) catch return "";
        }
        name.appendSlice(a, ".json") catch return "";
        return std.fs.path.join(a, &.{ s.borrowed_dir, subdomain, name.items }) catch "";
    }

    pub fn readBorrowed(s: *const Store, a: std.mem.Allocator, path: []const u8) ?[]u8 {
        if (path.len == 0) return null;
        return std.Io.Dir.cwd().readFileAlloc(s.io, path, a, .limited(64 << 20)) catch null;
    }

    /// Writes a borrowed index readable only by the user, in directories only they can enter.
    pub fn writeBorrowed(s: *const Store, path: []const u8, data: []const u8) void {
        if (path.len == 0) return;
        const cwd = std.Io.Dir.cwd();
        const library_dir = std.fs.path.dirname(path) orelse return;
        if (std.fs.path.dirname(s.borrowed_dir)) |parent| cwd.createDirPath(s.io, parent) catch {};
        for ([_][]const u8{ s.borrowed_dir, library_dir }) |dir| cwd.createDir(s.io, dir, private_dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return,
        };
        cwd.writeFile(s.io, .{ .sub_path = path, .data = data, .flags = .{ .permissions = private_file } }) catch {};
    }

    pub fn deleteBorrowed(s: *const Store, path: []const u8) void {
        if (path.len == 0) return;
        std.Io.Dir.cwd().deleteFile(s.io, path) catch {};
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
        s.deleteBorrowed(s.borrowedPath(a, lib.subdomain, username));
    }
};
