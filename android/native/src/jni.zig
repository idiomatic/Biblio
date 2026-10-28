//! JNI entry points for the Android app's `com.rbrian.biblio.core.Core`, over libbiblio's
//! typed interface.
//!
//! Each operation has its own native method taking Java strings and numbers. Results come back
//! as the app's Kotlin model objects, built here from libbiblio's C structs with each class's
//! primary constructor; failures are thrown as `Core.Failure`. Strings cross as UTF-16 (JNI's
//! "modified UTF-8" differs for characters outside the BMP). The JNIEnv functions are called by
//! their fixed slot in the JNI function table rather than through jni.h.

const std = @import("std");
const biblio = @import("biblio");
const capi = biblio.capi;

const JNIEnv = *const *const [229]?*const anyopaque;
const jobject = ?*anyopaque;
const jclass = ?*anyopaque;
const jstring = ?*anyopaque;
const jarray = ?*anyopaque;
const jmethodID = ?*anyopaque;
const jlong = i64;
const jint = i32;
const jboolean = u8;

const jvalue = extern union { z: jboolean, i: jint, j: jlong, d: f64, l: jobject };

// Slots in JNINativeInterface (stable since JNI 1.2).
const FindClass = 6;
const Throw = 13;
const NewGlobalRef = 21;
const DeleteLocalRef = 23;
const NewObjectA = 30;
const GetMethodID = 33;
const CallObjectMethodA = 36;
const CallBooleanMethodA = 39;
const GetStaticMethodID = 113;
const CallStaticObjectMethodA = 116;
const NewString = 163;
const GetStringLength = 164;
const GetArrayLength = 171;
const NewObjectArray = 172;
const GetObjectArrayElement = 173;
const NewByteArray = 176;
const NewIntArray = 179;
const NewDoubleArray = 182;
const GetByteArrayRegion = 200;
const SetByteArrayRegion = 208;
const SetIntArrayRegion = 211;
const SetDoubleArrayRegion = 214;
const GetStringRegion = 220;
const ExceptionCheck = 228;

fn slot(env: JNIEnv, comptime index: usize, comptime F: type) F {
    return @ptrCast(@alignCast(env.*.*[index].?));
}

const gpa = biblio.sync.allocator;

// MARK: Clients

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

fn handleOf(client: jlong) ?*biblio.Handle {
    return if (client == 0) null else @as(*Client, @ptrFromInt(@as(usize, @intCast(client)))).handle;
}

fn bytesFromJava(env: JNIEnv, array: jarray, a: std.mem.Allocator) ?[:0]u8 {
    const len = slot(env, GetArrayLength, *const fn (JNIEnv, jarray) callconv(.c) jint)(env, array);
    const out = a.allocSentinel(u8, @intCast(len), 0) catch return null;
    slot(env, GetByteArrayRegion, *const fn (JNIEnv, jarray, jint, jint, [*]u8) callconv(.c) void)(env, array, 0, len, out.ptr);
    return out;
}

/// Core.nativeNewClient(subdomain: ByteArray, username: ByteArray, password: ByteArray?): Long
export fn Java_com_rbrian_biblio_core_Core_nativeNewClient(env: JNIEnv, _: jclass, subdomain: jarray, username: jarray, password: jarray) jlong {
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
export fn Java_com_rbrian_biblio_core_Core_nativeSetPassword(env: JNIEnv, _: jclass, client: jlong, password: jarray) void {
    if (client == 0) return;
    const c: *Client = @ptrFromInt(@as(usize, @intCast(client)));
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const p = bytesFromJava(env, password, arena.allocator()) orelse return;
    c.setPassword(p);
    std.crypto.secureZero(u8, p);
}

export fn Java_com_rbrian_biblio_core_Core_nativeFreeClient(_: JNIEnv, _: jclass, client: jlong) void {
    if (client == 0) return;
    const c: *Client = @ptrFromInt(@as(usize, @intCast(client)));
    biblio.biblio_client_free(c.handle);
    c.setPassword(null);
    gpa.destroy(c);
}

// MARK: Calls

/// One native call: its arguments' memory, the core's error, and conversions to Java.
const Call = struct {
    env: JNIEnv,
    arena: std.heap.ArenaAllocator,
    err: capi.Error = .{},

    fn init(env: JNIEnv) Call {
        return .{ .env = env, .arena = .init(gpa) };
    }

    fn deinit(call: *Call) void {
        capi.biblio_error_clear(&call.err);
        call.arena.deinit();
    }

    fn a(call: *Call) std.mem.Allocator {
        return call.arena.allocator();
    }

    // Arguments

    fn str(call: *Call, s: jstring) [*:0]const u8 {
        return call.optStr(s) orelse "";
    }

    fn optStr(call: *Call, s: jstring) ?[*:0]const u8 {
        if (s == null) return null;
        const env = call.env;
        const len = slot(env, GetStringLength, *const fn (JNIEnv, jstring) callconv(.c) jint)(env, s);
        const units = call.a().alloc(u16, @intCast(len)) catch return "";
        slot(env, GetStringRegion, *const fn (JNIEnv, jstring, jint, jint, [*]u16) callconv(.c) void)(env, s, 0, len, units.ptr);
        const utf8 = std.unicode.utf16LeToUtf8AllocZ(call.a(), units) catch return "";
        return utf8.ptr;
    }

    /// A String[] as C strings.
    fn strings(call: *Call, array: jarray) []const [*:0]const u8 {
        if (array == null) return &.{};
        const env = call.env;
        const len = slot(env, GetArrayLength, *const fn (JNIEnv, jarray) callconv(.c) jint)(env, array);
        const out = call.a().alloc([*:0]const u8, @intCast(len)) catch return &.{};
        for (out, 0..) |*s, i| {
            const item = slot(env, GetObjectArrayElement, *const fn (JNIEnv, jarray, jint) callconv(.c) jobject)(env, array, @intCast(i));
            s.* = call.str(item);
            call.deleteLocal(item);
        }
        return out;
    }

    /// Pairs from a String[] of alternating keys and values.
    fn pairs(call: *Call, array: jarray) []const capi.Pair {
        const s = call.strings(array);
        const out = call.a().alloc(capi.Pair, s.len / 2) catch return &.{};
        for (out, 0..) |*p, i| p.* = .{ .key = s[2 * i], .value = s[2 * i + 1] };
        return out;
    }

    // Results

    /// Throws the core's error as a `Core.Failure` unless the call succeeded.
    fn check(call: *Call, result: capi.Result) bool {
        if (result == .ok) return true;
        const env = call.env;
        const message = if (call.err.message) |m| std.mem.span(m) else "Something went wrong.";
        const kind = call.string(kindName(result));
        const text = call.string(message);
        const status = if (call.err.status != 0) call.boxed("java/lang/Integer", "(I)Ljava/lang/Integer;", .{ .i = call.err.status }) else null;
        var args = [_]jvalue{ .{ .l = kind }, .{ .l = text }, .{ .l = status } };
        const m = call.method("com/rbrian/biblio/core/Core$Failure", "<init>", "(Ljava/lang/String;Ljava/lang/String;Ljava/lang/Integer;)V", false);
        const failure = call.new(m, &args);
        for (args) |v| call.deleteLocal(v.l);
        if (failure != null) _ = slot(env, Throw, *const fn (JNIEnv, jobject) callconv(.c) jint)(env, failure);
        return false;
    }

    /// Runs `f`, a libbiblio function, with `args` (every argument before its result and
    /// error), and returns the result as its Kotlin model (a java.util.List for a list type).
    fn fetch(call: *Call, comptime f: anytype, args: anytype) jobject {
        const params = @typeInfo(@TypeOf(f)).@"fn".param_types;
        const T = @typeInfo(@typeInfo(@typeInfo(params[args.len].?).optional.child).pointer.child).optional.child;
        var out: ?T = null;
        const result = @call(.auto, f, args ++ .{ &out, &call.err });
        defer capi.free(out);
        if (!call.check(result)) return null;
        const value = out orelse return null;
        return if (@hasField(@TypeOf(value.*), "items")) call.list(value.items[0..value.items_count]) else call.object(value.*);
    }

    /// Looks up a class's method once (on the calling Java thread, so FindClass sees the app's
    /// class loader) and keeps it.
    fn method(call: *Call, comptime class: [:0]const u8, comptime name: [:0]const u8, comptime sig: [:0]const u8, comptime static: bool) Method {
        // Naming the method makes a separate cache for each one.
        const Cache = struct {
            const key = class ++ "." ++ name ++ sig ++ (if (static) " static" else "");
            var value: Method = .{ .class = null, .id = null };
        };
        method_lock.lock();
        defer method_lock.unlock();
        if (Cache.value.id != null or call.pending()) return Cache.value;
        const env = call.env;
        const local = slot(env, FindClass, *const fn (JNIEnv, [*:0]const u8) callconv(.c) jclass)(env, class.ptr);
        if (local == null) return Cache.value;
        defer call.deleteLocal(local);
        const lookup = slot(env, if (static) GetStaticMethodID else GetMethodID, *const fn (JNIEnv, jclass, [*:0]const u8, [*:0]const u8) callconv(.c) jmethodID);
        const id = lookup(env, local, name.ptr, sig.ptr);
        if (id == null) return Cache.value;
        Cache.value = .{ .class = slot(env, NewGlobalRef, *const fn (JNIEnv, jobject) callconv(.c) jobject)(env, local), .id = id };
        return Cache.value;
    }

    fn pending(call: *Call) bool {
        return slot(call.env, ExceptionCheck, *const fn (JNIEnv) callconv(.c) jboolean)(call.env) != 0;
    }

    fn deleteLocal(call: *Call, ref: jobject) void {
        if (ref != null) slot(call.env, DeleteLocalRef, *const fn (JNIEnv, jobject) callconv(.c) void)(call.env, ref);
    }

    fn new(call: *Call, m: Method, args: [*]const jvalue) jobject {
        if (m.class == null or m.id == null or call.pending()) return null;
        return slot(call.env, NewObjectA, *const fn (JNIEnv, jclass, jmethodID, [*]const jvalue) callconv(.c) jobject)(call.env, m.class, m.id, args);
    }

    fn string(call: *Call, s: []const u8) jstring {
        if (call.pending()) return null;
        const units = std.unicode.utf8ToUtf16LeAlloc(call.a(), s) catch call.a().alloc(u16, 0) catch return null;
        return slot(call.env, NewString, *const fn (JNIEnv, [*]const u16, jint) callconv(.c) jstring)(call.env, units.ptr, @intCast(units.len));
    }

    /// A string the core allocated, as a Java string (null for NULL); frees it.
    fn taken(call: *Call, s: ?[*:0]u8) jstring {
        const p = s orelse return null;
        defer biblio.biblio_free(p);
        return call.string(std.mem.span(p));
    }

    fn optString(call: *Call, s: ?[*:0]const u8) jstring {
        return if (s) |p| call.string(std.mem.span(p)) else null;
    }

    fn boxed(call: *Call, comptime class: [:0]const u8, comptime sig: [:0]const u8, v: jvalue) jobject {
        const m = call.method(class, "valueOf", sig, true);
        if (m.class == null or m.id == null or call.pending()) return null;
        var args = [_]jvalue{v};
        return slot(call.env, CallStaticObjectMethodA, *const fn (JNIEnv, jclass, jmethodID, [*]const jvalue) callconv(.c) jobject)(call.env, m.class, m.id, &args);
    }

    fn doubles(call: *Call, values: []const f64) jarray {
        const env = call.env;
        const array = slot(env, NewDoubleArray, *const fn (JNIEnv, jint) callconv(.c) jarray)(env, @intCast(values.len));
        if (array == null) return null;
        slot(env, SetDoubleArrayRegion, *const fn (JNIEnv, jarray, jint, jint, [*]const f64) callconv(.c) void)(env, array, 0, @intCast(values.len), values.ptr);
        return array;
    }

    fn ints(call: *Call, values: []const i32) jarray {
        const env = call.env;
        const array = slot(env, NewIntArray, *const fn (JNIEnv, jint) callconv(.c) jarray)(env, @intCast(values.len));
        if (array == null) return null;
        slot(env, SetIntArrayRegion, *const fn (JNIEnv, jarray, jint, jint, [*]const i32) callconv(.c) void)(env, array, 0, @intCast(values.len), values.ptr);
        return array;
    }

    fn bytes(call: *Call, values: []const u8) jarray {
        const env = call.env;
        const array = slot(env, NewByteArray, *const fn (JNIEnv, jint) callconv(.c) jarray)(env, @intCast(values.len));
        if (array == null) return null;
        slot(env, SetByteArrayRegion, *const fn (JNIEnv, jarray, jint, jint, [*]const u8) callconv(.c) void)(env, array, 0, @intCast(values.len), values.ptr);
        return array;
    }

    /// A java.util.ArrayList of converted items.
    fn list(call: *Call, values: anytype) jobject {
        var size = [_]jvalue{.{ .i = @intCast(values.len) }};
        const out = call.new(call.method("java/util/ArrayList", "<init>", "(I)V", false), &size) orelse return null;
        const add = call.method("java/util/ArrayList", "add", "(Ljava/lang/Object;)Z", false);
        for (values) |v| {
            const item = call.object(v);
            var args = [_]jvalue{.{ .l = item }};
            if (!call.pending()) _ = slot(call.env, CallBooleanMethodA, *const fn (JNIEnv, jobject, jmethodID, [*]const jvalue) callconv(.c) jboolean)(call.env, out, add.id, &args);
            call.deleteLocal(item);
        }
        return out;
    }

    /// A java.util.HashMap of the library's labels.
    fn map(call: *Call, values: []const capi.Pair) jobject {
        var size = [_]jvalue{.{ .i = @intCast(values.len) }};
        const out = call.new(call.method("java/util/HashMap", "<init>", "(I)V", false), &size) orelse return null;
        const put = call.method("java/util/HashMap", "put", "(Ljava/lang/Object;Ljava/lang/Object;)Ljava/lang/Object;", false);
        for (values) |p| {
            var args = [_]jvalue{ .{ .l = call.string(std.mem.span(p.key)) }, .{ .l = call.string(std.mem.span(p.value)) } };
            if (!call.pending()) call.deleteLocal(slot(call.env, CallObjectMethodA, *const fn (JNIEnv, jobject, jmethodID, [*]const jvalue) callconv(.c) jobject)(call.env, out, put.id, &args));
            for (args) |v| call.deleteLocal(v.l);
        }
        return out;
    }

    /// The Kotlin model for a libbiblio struct (a string for C strings), built with its primary
    /// constructor, whose parameters follow the struct's fields.
    fn object(call: *Call, value: anytype) jobject {
        const T = @TypeOf(value);
        if (T == [*:0]const u8) return call.string(std.mem.span(value));
        const info = @typeInfo(T).@"struct";
        var args: [parameterCount(T)]jvalue = undefined;
        var locals: [args.len]jobject = @splat(null);
        var i: usize = 0;
        inline for (info.field_names, info.field_types) |name, F| {
            if (comptime !isParameter(T, name)) continue;
            const v = @field(value, name);
            if (F == [*:0]const u8) {
                locals[i] = call.string(std.mem.span(v));
                args[i] = .{ .l = locals[i] };
            } else if (F == ?[*:0]const u8) {
                locals[i] = call.optString(v);
                args[i] = .{ .l = locals[i] };
            } else if (F == bool and @hasField(T, "has_" ++ name)) {
                locals[i] = if (@field(value, "has_" ++ name)) call.boxed("java/lang/Boolean", "(Z)Ljava/lang/Boolean;", .{ .z = @intFromBool(v) }) else null;
                args[i] = .{ .l = locals[i] };
            } else if (F == bool) {
                args[i] = .{ .z = @intFromBool(v) };
            } else if (F == i64 and @hasField(T, "has_" ++ name)) {
                locals[i] = if (@field(value, "has_" ++ name)) call.boxed("java/lang/Integer", "(I)Ljava/lang/Integer;", .{ .i = @intCast(v) }) else null;
                args[i] = .{ .l = locals[i] };
            } else if (F == i64) {
                args[i] = if (comptime isLong(name)) .{ .j = v } else .{ .i = @intCast(v) };
            } else if (F == [*]const capi.Pair) {
                locals[i] = call.map(v[0..@field(value, name ++ "_count")]);
                args[i] = .{ .l = locals[i] };
            } else if (@typeInfo(F) == .pointer) {
                // An array with a `<name>_count`.
                locals[i] = call.list(v[0..@field(value, name ++ "_count")]);
                args[i] = .{ .l = locals[i] };
            } else if (@typeInfo(F) == .optional) {
                locals[i] = if (v) |p| call.object(p.*) else null;
                args[i] = .{ .l = locals[i] };
            } else {
                locals[i] = call.object(v);
                args[i] = .{ .l = locals[i] };
            }
            i += 1;
        }
        defer for (locals) |l| call.deleteLocal(l);
        return call.new(call.method(className(T), "<init>", constructor(T), false), &args);
    }
};

/// The Kotlin model class (in com.rbrian.biblio.core) for each libbiblio struct.
fn className(comptime T: type) [:0]const u8 {
    const names = .{
        .{ capi.Bib, "Bib" },                     .{ capi.Hold, "Hold" },                   .{ capi.Checkout, "Checkout" },
        .{ capi.HistoryEntry, "HistoryEntry" },   .{ capi.AccountStatus, "AccountStatus" }, .{ capi.ListEntry, "ListEntry" },
        .{ capi.FacetValue, "FacetValue" },       .{ capi.Facet, "Facet" },                 .{ capi.ListPage, "ListPage" },
        .{ capi.Copy, "CopyAvailability" },       .{ capi.DetailField, "DetailField" },     .{ capi.Location, "Location" },
        .{ capi.Patron, "Patron" },               .{ capi.LibraryInfo, "LibraryInfo" },     .{ capi.DirectoryEntry, "DirectoryEntry" },
        .{ capi.DirectoryPage, "DirectoryPage" }, .{ capi.Refusal, "Refusal" },
    };
    inline for (names) |n| if (n[0] == T) return "com/rbrian/biblio/core/" ++ n[1];
    @compileError("no Kotlin model for " ++ @typeName(T));
}

/// Fields that become constructor parameters: not `owner`, `has_…` or `…_count`, which
/// describe other fields.
fn isParameter(comptime T: type, comptime name: []const u8) bool {
    _ = T;
    return !std.mem.eql(u8, name, "owner") and !std.mem.startsWith(u8, name, "has_") and !std.mem.endsWith(u8, name, "_count");
}

fn parameterCount(comptime T: type) usize {
    var n: usize = 0;
    for (@typeInfo(T).@"struct".field_names) |name| {
        if (isParameter(T, name)) n += 1;
    }
    return n;
}

/// Kotlin `Long` fields; other integers are `Int`.
fn isLong(comptime name: []const u8) bool {
    return std.mem.eql(u8, name, "user_id") or std.mem.eql(u8, name, "account_id");
}

/// The JVM signature of the model's primary constructor (call at comptime).
fn constructor(comptime T: type) [:0]const u8 {
    const info = @typeInfo(T).@"struct";
    var sig: []const u8 = "(";
    for (info.field_names, info.field_types) |name, F| {
        if (!isParameter(T, name)) continue;
        const has = @hasField(T, "has_" ++ name);
        sig = sig ++ if (F == [*:0]const u8 or F == ?[*:0]const u8)
            "Ljava/lang/String;"
        else if (F == bool)
            (if (has) "Ljava/lang/Boolean;" else "Z")
        else if (F == i64)
            (if (has) "Ljava/lang/Integer;" else if (isLong(name)) "J" else "I")
        else if (F == [*]const capi.Pair)
            "Ljava/util/Map;"
        else if (@typeInfo(F) == .pointer)
            "Ljava/util/List;"
        else if (@typeInfo(F) == .optional)
            "L" ++ className(@typeInfo(@typeInfo(F).optional.child).pointer.child) ++ ";"
        else
            "L" ++ className(F) ++ ";";
    }
    return sig ++ ")V";
}

/// A Java class and one of its methods, looked up once and kept for the life of the app.
const Method = struct { class: jclass, id: jmethodID };

var method_lock: biblio.sync.Mutex = .{};

fn kindName(result: capi.Result) []const u8 {
    return switch (result) {
        .ok => "ok",
        .sign_in_required => "signInRequired",
        .missing_credentials => "missingCredentials",
        .login_failed => "loginFailed",
        .http => "http",
        .network => "network",
        .unexpected => "unexpected",
        .not_a_library => "notALibrary",
        .bad_request => "badRequest",
        .out_of_memory => "outOfMemory",
    };
}

// MARK: Library operations (no client)

/// Core.nativeLibraryInfo(subdomain: String): LibraryInfo
export fn Java_com_rbrian_biblio_core_Core_nativeLibraryInfo(env: JNIEnv, _: jclass, subdomain: jstring) jobject {
    var call = Call.init(env);
    defer call.deinit();
    return call.fetch(capi.biblio_library_info, .{call.str(subdomain)});
}

/// Core.nativeDirectoryPage(url: String?): DirectoryPage
export fn Java_com_rbrian_biblio_core_Core_nativeDirectoryPage(env: JNIEnv, _: jclass, url: jstring) jobject {
    var call = Call.init(env);
    defer call.deinit();
    return call.fetch(capi.biblio_directory_page, .{call.optStr(url)});
}

/// Core.nativeResolveSubdomain(name: String, website: String?): String?
export fn Java_com_rbrian_biblio_core_Core_nativeResolveSubdomain(env: JNIEnv, _: jclass, name: jstring, website: jstring) jstring {
    var call = Call.init(env);
    defer call.deinit();
    return call.taken(capi.biblio_resolve_subdomain(call.str(name), call.optStr(website)));
}

/// Core.nativeSubdomainFrom(input: String): String?
export fn Java_com_rbrian_biblio_core_Core_nativeSubdomainFrom(env: JNIEnv, _: jclass, input: jstring) jstring {
    var call = Call.init(env);
    defer call.deinit();
    return call.taken(capi.biblio_subdomain_from(call.str(input)));
}

/// Core.nativeFormatName(code: String, labels: Array<String>): String — labels alternate keys and values.
export fn Java_com_rbrian_biblio_core_Core_nativeFormatName(env: JNIEnv, _: jclass, code: jstring, labels: jarray) jstring {
    var call = Call.init(env);
    defer call.deinit();
    const pairs = call.pairs(labels);
    return call.taken(capi.biblio_format_name(call.str(code), pairs.ptr, pairs.len));
}

/// Core.nativeSortName(id: String, labels: Array<String>): String
export fn Java_com_rbrian_biblio_core_Core_nativeSortName(env: JNIEnv, _: jclass, id: jstring, labels: jarray) jstring {
    var call = Call.init(env);
    defer call.deinit();
    const pairs = call.pairs(labels);
    return call.taken(capi.biblio_sort_name(call.str(id), pairs.ptr, pairs.len));
}

/// Core.nativeCodabar(value: String): DoubleArray?
export fn Java_com_rbrian_biblio_core_Core_nativeCodabar(env: JNIEnv, _: jclass, value: jstring) jarray {
    var call = Call.init(env);
    defer call.deinit();
    var count: usize = 0;
    const widths = capi.biblio_codabar(call.str(value), &count) orelse return null;
    defer biblio.biblio_free(widths);
    return call.doubles(widths[0..count]);
}

/// Core.nativeFetchImage(url: String): ByteArray
export fn Java_com_rbrian_biblio_core_Core_nativeFetchImage(env: JNIEnv, _: jclass, url: jstring) jarray {
    var call = Call.init(env);
    defer call.deinit();
    var data: ?[*]u8 = null;
    var len: usize = 0;
    const result = capi.biblio_fetch_image(call.str(url), &data, &len, &call.err);
    defer if (data) |d| biblio.biblio_free(d);
    if (!call.check(result)) return null;
    return call.bytes(if (data) |d| d[0..len] else &.{});
}

/// Core.nativeLibraryIcon(website: String?, subdomain: String?, logo: String?): ByteArray? —
/// the icon's kind (1 square, 2 logo) as the first byte, then the image; null if none.
export fn Java_com_rbrian_biblio_core_Core_nativeLibraryIcon(env: JNIEnv, _: jclass, website: jstring, subdomain: jstring, logo: jstring) jarray {
    var call = Call.init(env);
    defer call.deinit();
    var data: ?[*]u8 = null;
    var len: usize = 0;
    const kind = capi.biblio_library_icon(call.optStr(website), call.optStr(subdomain), call.optStr(logo), &data, &len);
    defer if (data) |d| biblio.biblio_free(d);
    const image = data orelse return null;
    const out = call.a().alloc(u8, len + 1) catch return null;
    out[0] = @intCast(@backingInt(kind));
    @memcpy(out[1..], image[0..len]);
    return call.bytes(out);
}

/// Core.nativeLogoBounds(pixels: ByteArray, width: Int, height: Int, stride: Int, channels: Int): IntArray?
export fn Java_com_rbrian_biblio_core_Core_nativeLogoBounds(env: JNIEnv, _: jclass, pixels: jarray, width: jint, height: jint, stride: jint, channels: jint) jarray {
    var call = Call.init(env);
    defer call.deinit();
    const p = bytesFromJava(env, pixels, call.a()) orelse return null;
    if (width <= 0 or height <= 0 or stride <= 0 or channels <= 0) return null;
    const w: usize = @intCast(width);
    const h: usize = @intCast(height);
    const st: usize = @intCast(stride);
    const ch: usize = @intCast(channels);
    if (p.len < (h - 1) * st + w * ch) return null;
    var b: [4]usize = undefined;
    if (!capi.biblio_logo_bounds(p.ptr, w, h, st, ch, &b)) return null;
    return call.ints(&.{ @intCast(b[0]), @intCast(b[1]), @intCast(b[2]), @intCast(b[3]) });
}

// MARK: Client operations

/// Core.nativeLogin(client: Long, force: Boolean): Patron
export fn Java_com_rbrian_biblio_core_Core_nativeLogin(env: JNIEnv, _: jclass, client: jlong, force: jboolean) jobject {
    var call = Call.init(env);
    defer call.deinit();
    return call.fetch(capi.biblio_login, .{ handleOf(client), force != 0 });
}

/// Core.nativePatron(client: Long): Patron? — the patron from the last sign-in.
export fn Java_com_rbrian_biblio_core_Core_nativePatron(env: JNIEnv, _: jclass, client: jlong) jobject {
    var call = Call.init(env);
    defer call.deinit();
    return call.fetch(capi.biblio_patron, .{handleOf(client)});
}

/// Core.nativeSearch(client: Long, query: String, searchType: String?, filters: Array<String>,
/// page: Int, sort: String?, format: String?): ListPage — filters alternate keys and values.
export fn Java_com_rbrian_biblio_core_Core_nativeSearch(env: JNIEnv, _: jclass, client: jlong, query: jstring, search_type: jstring, filters: jarray, page: jint, sort: jstring, format: jstring) jobject {
    var call = Call.init(env);
    defer call.deinit();
    const pairs = call.pairs(filters);
    const q: capi.SearchQuery = .{
        .query = call.str(query),
        .search_type = call.optStr(search_type),
        .filters = pairs.ptr,
        .filter_count = pairs.len,
        .page = page,
        .sort = call.optStr(sort),
        .format = call.optStr(format),
    };
    return call.fetch(capi.biblio_search, .{ handleOf(client), &q });
}

/// Core.nativeHolds(client: Long, page: Int, sort: String?): ListPage
export fn Java_com_rbrian_biblio_core_Core_nativeHolds(env: JNIEnv, _: jclass, client: jlong, page: jint, sort: jstring) jobject {
    var call = Call.init(env);
    defer call.deinit();
    return call.fetch(capi.biblio_holds, .{ handleOf(client), page, call.optStr(sort) });
}

/// Core.nativeCheckouts(client: Long, page: Int, sort: String?): ListPage
export fn Java_com_rbrian_biblio_core_Core_nativeCheckouts(env: JNIEnv, _: jclass, client: jlong, page: jint, sort: jstring) jobject {
    var call = Call.init(env);
    defer call.deinit();
    return call.fetch(capi.biblio_checkouts, .{ handleOf(client), page, call.optStr(sort) });
}

/// Core.nativeHistory(client: Long, page: Int, sort: String?): ListPage
export fn Java_com_rbrian_biblio_core_Core_nativeHistory(env: JNIEnv, _: jclass, client: jlong, page: jint, sort: jstring) jobject {
    var call = Call.init(env);
    defer call.deinit();
    return call.fetch(capi.biblio_history, .{ handleOf(client), page, call.optStr(sort) });
}

/// Core.nativeAvailability(client: Long, metadataId: String): List<CopyAvailability>
export fn Java_com_rbrian_biblio_core_Core_nativeAvailability(env: JNIEnv, _: jclass, client: jlong, metadata_id: jstring) jobject {
    var call = Call.init(env);
    defer call.deinit();
    return call.fetch(capi.biblio_availability, .{ handleOf(client), call.str(metadata_id) });
}

/// Core.nativeDetails(client: Long, metadataId: String): List<DetailField>
export fn Java_com_rbrian_biblio_core_Core_nativeDetails(env: JNIEnv, _: jclass, client: jlong, metadata_id: jstring) jobject {
    var call = Call.init(env);
    defer call.deinit();
    return call.fetch(capi.biblio_details, .{ handleOf(client), call.str(metadata_id) });
}

/// Core.nativeLocations(client: Long): List<Location>
export fn Java_com_rbrian_biblio_core_Core_nativeLocations(env: JNIEnv, _: jclass, client: jlong) jobject {
    var call = Call.init(env);
    defer call.deinit();
    return call.fetch(capi.biblio_locations, .{handleOf(client)});
}

/// Core.nativePlaceHold(client: Long, metadataId: String, materialType: String?, pickupBranch: String?)
export fn Java_com_rbrian_biblio_core_Core_nativePlaceHold(env: JNIEnv, _: jclass, client: jlong, metadata_id: jstring, material_type: jstring, pickup_branch: jstring) void {
    var call = Call.init(env);
    defer call.deinit();
    _ = call.check(capi.biblio_place_hold(handleOf(client), call.str(metadata_id), call.optStr(material_type), call.optStr(pickup_branch), &call.err));
}

/// Core.nativeCancelHolds(client: Long, holds: Array<String>): List<Refusal> — holds alternate
/// id and metadataId; the result lists the holds the library declined to cancel.
export fn Java_com_rbrian_biblio_core_Core_nativeCancelHolds(env: JNIEnv, _: jclass, client: jlong, holds: jarray) jobject {
    var call = Call.init(env);
    defer call.deinit();
    const pairs = call.pairs(holds);
    const refs = call.a().alloc(capi.HoldRef, pairs.len) catch return null;
    for (refs, pairs) |*r, p| r.* = .{ .id = p.key, .metadata_id = p.value };
    return call.fetch(capi.biblio_cancel_holds, .{ handleOf(client), refs.ptr, refs.len });
}

/// Core.nativeSetPickup(client: Long, branchId: String)
export fn Java_com_rbrian_biblio_core_Core_nativeSetPickup(env: JNIEnv, _: jclass, client: jlong, branch_id: jstring) void {
    var call = Call.init(env);
    defer call.deinit();
    _ = call.check(capi.biblio_set_pickup(handleOf(client), call.str(branch_id), &call.err));
}

/// Core.nativeSetLanguage(client: Long, code: String)
export fn Java_com_rbrian_biblio_core_Core_nativeSetLanguage(env: JNIEnv, _: jclass, client: jlong, code: jstring) void {
    var call = Call.init(env);
    defer call.deinit();
    _ = call.check(capi.biblio_set_language(handleOf(client), call.str(code), &call.err));
}

/// Core.nativeSetBorrowingHistory(client: Long, enabled: Boolean)
export fn Java_com_rbrian_biblio_core_Core_nativeSetBorrowingHistory(env: JNIEnv, _: jclass, client: jlong, enabled: jboolean) void {
    var call = Call.init(env);
    defer call.deinit();
    _ = call.check(capi.biblio_set_borrowing_history(handleOf(client), enabled != 0, &call.err));
}

/// Core.nativeChangeEmail(client: Long, email: String)
export fn Java_com_rbrian_biblio_core_Core_nativeChangeEmail(env: JNIEnv, _: jclass, client: jlong, email: jstring) void {
    var call = Call.init(env);
    defer call.deinit();
    _ = call.check(capi.biblio_change_email(handleOf(client), call.str(email), &call.err));
}

/// Core.nativeChangePassword(client: Long, current: String, new: String)
export fn Java_com_rbrian_biblio_core_Core_nativeChangePassword(env: JNIEnv, _: jclass, client: jlong, current: jstring, new: jstring) void {
    var call = Call.init(env);
    defer call.deinit();
    const c = call.str(current);
    const n = call.str(new);
    defer {
        std.crypto.secureZero(u8, @constCast(std.mem.span(c)));
        std.crypto.secureZero(u8, @constCast(std.mem.span(n)));
    }
    _ = call.check(capi.biblio_change_password(handleOf(client), c, n, &call.err));
}

test "constructor signatures match the Kotlin models" {
    const S = "Ljava/lang/String;";
    const L = "Ljava/util/List;";
    const I = "Ljava/lang/Integer;";
    const expect = std.testing.expectEqualStrings;
    try expect("(" ++ S ++ S ++ S ++ L ++ S ++ S ++ S ++ S ++ S ++ S ++ S ++ S ++ "Z" ++ S ++ "IIII)V", comptime constructor(capi.Bib));
    try expect("(" ++ S ++ S ++ S ++ I ++ S ++ S ++ S ++ S ++ "Z)V", comptime constructor(capi.Hold));
    try expect("(" ++ S ++ S ++ S ++ S ++ S ++ I ++ ")V", comptime constructor(capi.Checkout));
    try expect("(" ++ S ++ "Z" ++ I ++ S ++ ")V", comptime constructor(capi.AccountStatus));
    try expect("(" ++ S ++ "Lcom/rbrian/biblio/core/Bib;" ++ S ++ "ILcom/rbrian/biblio/core/Hold;Lcom/rbrian/biblio/core/Checkout;" ++
        "Lcom/rbrian/biblio/core/HistoryEntry;Lcom/rbrian/biblio/core/AccountStatus;)V", comptime constructor(capi.ListEntry));
    try expect("(" ++ L ++ "IIII" ++ L ++ L ++ S ++ ")V", comptime constructor(capi.ListPage));
    try expect("(" ++ S ++ S ++ S ++ "Z" ++ S ++ S ++ S ++ "Z" ++ S ++ ")V", comptime constructor(capi.Copy));
    try expect("(JJ" ++ S ++ S ++ S ++ S ++ S ++ "Ljava/lang/Boolean;)V", comptime constructor(capi.Patron));
    try expect("(" ++ S ++ S ++ S ++ S ++ S ++ "Ljava/util/Map;" ++ L ++ L ++ ")V", comptime constructor(capi.LibraryInfo));
    try expect("(" ++ L ++ S ++ ")V", comptime constructor(capi.DirectoryPage));
    try expect("(" ++ S ++ "I)V", comptime constructor(capi.FacetValue));
    try expect("(" ++ S ++ L ++ ")V", comptime constructor(capi.Facet));
    try expect("(" ++ S ++ S ++ ")V", comptime constructor(capi.Refusal));
}

/// A stand-in for the JVM that renders each object the shim builds as text, reading
/// constructor arguments by their signature.
const FakeJvm = struct {
    const Obj = struct { text: []const u8, items: std.ArrayList([]const u8) = .empty, is_list: bool = false };
    var arena: std.heap.ArenaAllocator = undefined;
    var table: [229]?*const anyopaque = @splat(null);
    var table_ptr: *const [229]?*const anyopaque = &table;

    fn a() std.mem.Allocator {
        return arena.allocator();
    }

    fn make(text: []const u8) *Obj {
        const o = a().create(Obj) catch unreachable;
        o.* = .{ .text = text };
        return o;
    }

    fn obj(p: ?*anyopaque) *Obj {
        return @ptrCast(@alignCast(p.?));
    }

    fn render(p: ?*anyopaque) []const u8 {
        const o = obj(p orelse return "null");
        if (o.items.items.len > 0 or o.is_list) return std.fmt.allocPrint(a(), "[{s}]", .{std.mem.join(a(), ", ", o.items.items) catch unreachable}) catch unreachable;
        return o.text;
    }

    fn findClass(_: JNIEnv, name: [*:0]const u8) callconv(.c) jclass {
        return make(std.mem.span(name));
    }
    fn same(_: JNIEnv, o: jobject) callconv(.c) jobject {
        return o;
    }
    fn delete(_: JNIEnv, _: jobject) callconv(.c) void {}
    fn getMethod(_: JNIEnv, cls: jclass, name: [*:0]const u8, sig: [*:0]const u8) callconv(.c) jmethodID {
        return make(std.fmt.allocPrint(a(), "{s} {s} {s}", .{ obj(cls).text, name, sig }) catch unreachable);
    }
    fn exceptionCheck(_: JNIEnv) callconv(.c) jboolean {
        return 0;
    }
    fn newString(_: JNIEnv, units: [*]const u16, len: jint) callconv(.c) jstring {
        return make(std.fmt.allocPrint(a(), "\"{s}\"", .{std.unicode.utf16LeToUtf8Alloc(a(), units[0..@intCast(len)]) catch unreachable}) catch unreachable);
    }
    fn newObject(_: JNIEnv, cls: jclass, mid: jmethodID, args: [*]const jvalue) callconv(.c) jobject {
        const class = std.fs.path.basename(obj(cls).text);
        const desc = obj(mid).text;
        const sig = desc[std.mem.indexOfScalar(u8, desc, '(').? + 1 .. std.mem.indexOfScalar(u8, desc, ')').?];
        if (std.mem.startsWith(u8, class, "ArrayList") or std.mem.startsWith(u8, class, "HashMap")) {
            const o = make(class);
            o.is_list = true;
            return o;
        }
        var out: std.ArrayList(u8) = .empty;
        out.print(a(), "{s}(", .{class}) catch unreachable;
        var i: usize = 0;
        var k: usize = 0;
        while (k < sig.len) : (i += 1) {
            if (i > 0) out.appendSlice(a(), ", ") catch unreachable;
            switch (sig[k]) {
                'Z' => out.print(a(), "{}", .{args[i].z != 0}) catch unreachable,
                'I' => out.print(a(), "{d}", .{args[i].i}) catch unreachable,
                'J' => out.print(a(), "{d}L", .{args[i].j}) catch unreachable,
                'L' => {
                    out.appendSlice(a(), render(args[i].l)) catch unreachable;
                    k = std.mem.indexOfScalarPos(u8, sig, k, ';').?;
                },
                else => unreachable,
            }
            k += 1;
        }
        out.append(a(), ')') catch unreachable;
        return make(out.items);
    }
    fn callStatic(_: JNIEnv, _: jclass, mid: jmethodID, args: [*]const jvalue) callconv(.c) jobject {
        const boolean = std.mem.indexOf(u8, obj(mid).text, "Boolean") != null;
        return make(if (boolean) (if (args[0].z != 0) "true" else "false") else std.fmt.allocPrint(a(), "{d}", .{args[0].i}) catch unreachable);
    }
    fn add(_: JNIEnv, list: jobject, _: jmethodID, args: [*]const jvalue) callconv(.c) jboolean {
        obj(list).items.append(a(), render(args[0].l)) catch unreachable;
        return 1;
    }
    fn put(_: JNIEnv, map_: jobject, _: jmethodID, args: [*]const jvalue) callconv(.c) jobject {
        obj(map_).items.append(a(), std.fmt.allocPrint(a(), "{s}={s}", .{ render(args[0].l), render(args[1].l) }) catch unreachable) catch unreachable;
        return null;
    }

    fn env() JNIEnv {
        arena = .init(std.testing.allocator);
        table[FindClass] = &findClass;
        table[NewGlobalRef] = &same;
        table[DeleteLocalRef] = &delete;
        table[GetMethodID] = &getMethod;
        table[GetStaticMethodID] = &getMethod;
        table[ExceptionCheck] = &exceptionCheck;
        table[NewString] = &newString;
        table[NewObjectA] = &newObject;
        table[CallStaticObjectMethodA] = &callStatic;
        table[CallBooleanMethodA] = &add;
        table[CallObjectMethodA] = &put;
        return @ptrCast(&table_ptr);
    }
};

test "builds Kotlin models from C structs" {
    var call = Call.init(FakeJvm.env());
    defer call.deinit();
    defer FakeJvm.arena.deinit();
    const authors = [_][*:0]const u8{"Herbert, Frank"};
    const hold: capi.Hold = .{ .id = "h1", .metadata_id = "m1", .status = "READY_FOR_PICKUP", .has_position = true, .position = 3, .pickup_location = "Main", .expiry_date = null, .pickup_by_date = null, .suspend_end_date = null, .can_cancel = true };
    const status: capi.AccountStatus = .{ .kind = "onHold", .ready = true, .has_position = false, .position = 0, .due = null };
    const entry: capi.ListEntry = .{
        .id = "e1",
        .kind = "hold",
        .server_index = 2,
        .hold = &hold,
        .checkout = null,
        .history = null,
        .account_status = &status,
        .bib = .{ .id = "b1", .title = "Dune 🏜", .subtitle = null, .authors = &authors, .authors_count = 1, .format = "BK", .publication_date = "1965", .edition = null, .call_number = null, .summary = null, .jacket_small = null, .jacket_large = null, .material_type = "PHYSICAL", .holdable = true, .status = null, .held_copies = 1, .available_copies = 0, .total_copies = 2, .on_order_copies = 0 },
    };
    try std.testing.expectEqualStrings(
        "ListEntry(\"e1\", Bib(\"b1\", \"Dune 🏜\", null, [\"Herbert, Frank\"], \"BK\", \"1965\", null, null, null, null, null, \"PHYSICAL\", true, null, 1, 0, 2, 0), " ++
            "\"hold\", 2, Hold(\"h1\", \"m1\", \"READY_FOR_PICKUP\", 3, \"Main\", null, null, null, true), null, null, AccountStatus(\"onHold\", true, null, null))",
        FakeJvm.render(call.object(entry)),
    );
    const patron: capi.Patron = .{ .owner = null, .user_id = 1234567890123, .account_id = 7, .name = "Pat", .email = null, .language = "en", .barcode = "2", .preferred_pickup = null, .has_borrowing_history_enabled = true, .borrowing_history_enabled = false };
    try std.testing.expectEqualStrings("Patron(1234567890123L, 7L, \"Pat\", null, \"en\", \"2\", null, false)", FakeJvm.render(call.object(patron)));
    const labels = [_]capi.Pair{.{ .key = "FORMAT.bk", .value = "Book" }};
    const none = [_][*:0]const u8{};
    const info: capi.LibraryInfo = .{ .owner = null, .subdomain = "wccls", .name = "WCCLS", .short_name = null, .primary_color = null, .website = null, .labels = &labels, .labels_count = 1, .languages = &none, .languages_count = 0, .users = &none, .users_count = 0 };
    try std.testing.expectEqualStrings("LibraryInfo(\"wccls\", \"WCCLS\", null, null, null, [\"FORMAT.bk\"=\"Book\"], [], [])", FakeJvm.render(call.object(info)));
}
