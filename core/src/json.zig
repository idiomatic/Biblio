//! Lenient reading of gateway JSON. The responses are large, loosely specified and vary
//! between libraries, so parsers read only the fields they need, and a missing or
//! mistyped field reads as null instead of failing.

const std = @import("std");
const Value = std.json.Value;

pub const J = struct {
    v: ?Value,

    pub const null_: J = .{ .v = null };

    pub fn of(v: Value) J {
        return .{ .v = v };
    }

    pub fn get(self: J, key: []const u8) J {
        const v = self.v orelse return null_;
        return switch (v) {
            .object => |o| .{ .v = o.get(key) },
            else => null_,
        };
    }

    pub fn at(self: J, index: usize) J {
        const v = self.v orelse return null_;
        return switch (v) {
            .array => |a| if (index < a.items.len) .{ .v = a.items[index] } else null_,
            else => null_,
        };
    }

    /// Follows a dotted path, e.g. `json.path("catalogSearch.pagination.pages")`.
    pub fn path(self: J, dotted: []const u8) J {
        var out = self;
        var it = std.mem.splitScalar(u8, dotted, '.');
        while (it.next()) |key| out = out.get(key);
        return out;
    }

    pub fn isNull(self: J) bool {
        const v = self.v orelse return true;
        return v == .null;
    }

    /// Strings as is; numbers and booleans as their text (ids are sometimes numbers).
    /// Numbers are formatted into `buf`-free static storage via the arena passed in.
    pub fn str(self: J, arena: std.mem.Allocator) ?[]const u8 {
        const v = self.v orelse return null;
        return switch (v) {
            .string => |s| s,
            .number_string => |s| s,
            .integer => |i| std.fmt.allocPrint(arena, "{d}", .{i}) catch null,
            .float => |f| if (f == @round(f) and @abs(f) < 1e15)
                std.fmt.allocPrint(arena, "{d}", .{@as(i64, @intFromFloat(f))}) catch null
            else
                std.fmt.allocPrint(arena, "{d}", .{f}) catch null,
            .bool => |b| if (b) "true" else "false",
            else => null,
        };
    }

    /// Like `str`, trimmed, and null when empty.
    pub fn nonEmpty(self: J, arena: std.mem.Allocator) ?[]const u8 {
        const s = self.str(arena) orelse return null;
        const t = std.mem.trim(u8, s, " \t\r\n");
        return if (t.len == 0) null else t;
    }

    pub fn int(self: J) ?i64 {
        const v = self.v orelse return null;
        return switch (v) {
            .integer => |i| i,
            .float => |f| if (std.math.isFinite(f)) @as(i64, @intFromFloat(f)) else null,
            .number_string, .string => |s| std.fmt.parseInt(i64, s, 10) catch null,
            else => null,
        };
    }

    pub fn boolean(self: J) ?bool {
        const v = self.v orelse return null;
        return switch (v) {
            .bool => |b| b,
            .string => |s| std.mem.eql(u8, s, "true"),
            else => null,
        };
    }

    pub fn items(self: J) []const Value {
        const v = self.v orelse return &.{};
        return switch (v) {
            .array => |a| a.items,
            else => &.{},
        };
    }

    pub fn object(self: J) ?std.json.ObjectMap {
        const v = self.v orelse return null;
        return switch (v) {
            .object => |o| o,
            else => null,
        };
    }

    /// The string elements of an array.
    pub fn strings(self: J, arena: std.mem.Allocator) []const []const u8 {
        var out: std.ArrayList([]const u8) = .empty;
        for (self.items()) |item| {
            if (J.of(item).str(arena)) |s| out.append(arena, s) catch {};
        }
        return out.items;
    }

    pub fn eqlStr(self: J, s: []const u8) bool {
        const v = self.v orelse return false;
        return switch (v) {
            .string => |t| std.mem.eql(u8, t, s),
            else => false,
        };
    }
};

pub fn parse(arena: std.mem.Allocator, text: []const u8) J {
    const v = std.json.parseFromSliceLeaky(Value, arena, text, .{}) catch return J.null_;
    return J.of(v);
}

/// "NEWLY_ACQUIRED" → "Newly acquired"
pub fn prettified(arena: std.mem.Allocator, s: []const u8) []const u8 {
    const out = arena.alloc(u8, s.len) catch return s;
    for (s, 0..) |c, i| {
        const d = if (c == '_') ' ' else std.ascii.toLower(c);
        out[i] = if (i == 0) std.ascii.toUpper(d) else d;
    }
    return out;
}

test "lenient access" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const j = parse(arena, "{\"a\":{\"b\":[1,\"x\",2.0]},\"n\":\" hi \",\"e\":\"\"}");
    try std.testing.expectEqual(@as(?i64, 1), j.path("a.b").at(0).int());
    try std.testing.expectEqualStrings("x", j.path("a.b").at(1).str(arena).?);
    try std.testing.expectEqualStrings("2", j.path("a.b").at(2).str(arena).?);
    try std.testing.expectEqualStrings("hi", j.get("n").nonEmpty(arena).?);
    try std.testing.expect(j.get("e").nonEmpty(arena) == null);
    try std.testing.expect(j.get("missing").get("deeper").isNull());
    try std.testing.expectEqualStrings("Newly acquired", prettified(arena, "NEWLY_ACQUIRED"));
}
