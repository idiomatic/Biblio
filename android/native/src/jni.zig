//! JNI entry points for the Android app's `com.rbrian.biblio.core.Core`, over libbiblio.
//!
//! Requests and responses cross as UTF-8 byte arrays (JNI's own strings are "modified UTF-8",
//! which differs for characters outside the BMP). Only four JNIEnv functions are needed, so
//! they are called by their fixed slot in the JNI function table rather than through jni.h.

const std = @import("std");
const biblio = @import("biblio");

const JNIEnv = *const *const [229]?*const anyopaque;
const jobject = ?*anyopaque;
const jbyteArray = ?*anyopaque;
const jlong = i64;

// Slots in JNINativeInterface (stable since JNI 1.1).
const GetArrayLength = 171;
const NewByteArray = 176;
const GetByteArrayRegion = 200;
const SetByteArrayRegion = 208;

fn slot(env: JNIEnv, comptime index: usize, comptime F: type) F {
    return @ptrCast(@alignCast(env.*.*[index].?));
}

fn bytesFromJava(env: JNIEnv, array: jbyteArray, a: std.mem.Allocator) ?[:0]u8 {
    const len = slot(env, GetArrayLength, *const fn (JNIEnv, jbyteArray) callconv(.c) i32)(env, array);
    const out = a.allocSentinel(u8, @intCast(len), 0) catch return null;
    slot(env, GetByteArrayRegion, *const fn (JNIEnv, jbyteArray, i32, i32, [*]u8) callconv(.c) void)(env, array, 0, len, out.ptr);
    return out;
}

fn bytesToJava(env: JNIEnv, bytes: []const u8) jbyteArray {
    const len: i32 = @intCast(bytes.len);
    const array = slot(env, NewByteArray, *const fn (JNIEnv, i32) callconv(.c) jbyteArray)(env, len);
    if (array == null) return null;
    slot(env, SetByteArrayRegion, *const fn (JNIEnv, jbyteArray, i32, i32, [*]const u8) callconv(.c) void)(env, array, 0, len, bytes.ptr);
    return array;
}

const gpa = biblio.sync.allocator;

/// A core client plus the password it signs in with, which the app decrypts from the
/// Android Keystore when it opens the account.
const Client = struct {
    handle: ?*biblio.Handle,
    mutex: biblio.sync.Mutex = .{},
    password: ?[]u8 = null,

    fn setPassword(c: *Client, password: ?[]const u8) void {
        c.mutex.lock();
        defer c.mutex.unlock();
        if (c.password) |p| {
            std.crypto.secureZero(u8, p);
            gpa.free(p);
        }
        c.password = if (password) |p| gpa.dupe(u8, p) catch null else null;
    }
};

fn passwordFor(ctx: ?*anyopaque, _: [*:0]const u8, _: [*:0]const u8) callconv(.c) ?[*:0]u8 {
    const c: *Client = @ptrCast(@alignCast(ctx.?));
    c.mutex.lock();
    defer c.mutex.unlock();
    const p = c.password orelse return null;
    const out = biblio.biblio_alloc(p.len + 1) orelse return null;
    @memcpy(out[0..p.len], p);
    out[p.len] = 0;
    return @ptrCast(out);
}

/// Core.nativeNewClient(subdomain: ByteArray, username: ByteArray, password: ByteArray?): Long
export fn Java_com_rbrian_biblio_core_Core_nativeNewClient(env: JNIEnv, _: jobject, subdomain: jbyteArray, username: jbyteArray, password: jbyteArray) jlong {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const sd = bytesFromJava(env, subdomain, a) orelse return 0;
    const un = bytesFromJava(env, username, a) orelse return 0;
    const c = gpa.create(Client) catch return 0;
    c.* = .{ .handle = null };
    if (password != null) {
        if (bytesFromJava(env, password, a)) |p| {
            c.setPassword(p);
            std.crypto.secureZero(u8, p);
        }
    }
    c.handle = biblio.biblio_client_new(sd.ptr, un.ptr, passwordFor, c);
    return @intCast(@intFromPtr(c));
}

/// Core.nativeSetPassword(client: Long, password: ByteArray) — after the password changes.
export fn Java_com_rbrian_biblio_core_Core_nativeSetPassword(env: JNIEnv, _: jobject, client: jlong, password: jbyteArray) void {
    if (client == 0) return;
    const c: *Client = @ptrFromInt(@as(usize, @intCast(client)));
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const p = bytesFromJava(env, password, arena.allocator()) orelse return;
    c.setPassword(p);
    std.crypto.secureZero(u8, p);
}

export fn Java_com_rbrian_biblio_core_Core_nativeFreeClient(_: JNIEnv, _: jobject, client: jlong) void {
    if (client == 0) return;
    const c: *Client = @ptrFromInt(@as(usize, @intCast(client)));
    biblio.biblio_client_free(c.handle);
    c.setPassword(null);
    gpa.destroy(c);
}

/// Core.nativeCall(client: Long, request: ByteArray): ByteArray — blocks; call off the main thread.
export fn Java_com_rbrian_biblio_core_Core_nativeCall(env: JNIEnv, _: jobject, client: jlong, request: jbyteArray) jbyteArray {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const req = bytesFromJava(env, request, arena.allocator()) orelse return null;
    const handle: ?*biblio.Handle = if (client == 0) null else @as(*Client, @ptrFromInt(@as(usize, @intCast(client)))).handle;
    const out = biblio.biblio_call(handle, req.ptr) orelse return null;
    defer biblio.biblio_free(out);
    return bytesToJava(env, std.mem.span(out));
}
