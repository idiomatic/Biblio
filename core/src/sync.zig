//! Locks, waiting and clocks for the core, without threading an `Io` through every call.
//!
//! Zig 0.17's `std.Io.Threaded` does not compile for iOS-family targets (its process
//! spawning refers to a field iOS lacks), so there the core uses pthreads directly and
//! relies on the app's HTTP stack. Everywhere else it uses `std.Io`.

const std = @import("std");
const builtin = @import("builtin");

pub const has_std_io = switch (builtin.os.tag) {
    .ios, .tvos, .visionos, .watchos => false,
    else => true,
};

const Threaded = if (has_std_io) std.Io.Threaded else void;
var threaded: Threaded = undefined;
/// 0: not set up, 1: being set up by another thread, 2: ready.
var init_state: std.atomic.Value(u8) = .init(0);

/// The process-wide `Io`, created on first use.
pub fn io() std.Io {
    if (!has_std_io) @compileError("std.Io is unavailable on this target");
    if (init_state.load(.acquire) != 2) {
        if (init_state.cmpxchgStrong(0, 1, .acquire, .acquire) == null) {
            threaded = .init(allocator, .{});
            init_state.store(2, .release);
        } else {
            while (init_state.load(.acquire) != 2) std.atomic.spinLoopHint();
        }
    }
    return threaded.io();
}

pub const allocator: std.mem.Allocator = if (builtin.link_libc) std.heap.c_allocator else std.heap.smp_allocator;

pub const Mutex = if (has_std_io) struct {
    m: std.Io.Mutex = .init,

    pub fn lock(self: *@This()) void {
        self.m.lockUncancelable(io());
    }
    pub fn unlock(self: *@This()) void {
        self.m.unlock(io());
    }
} else struct {
    m: std.c.pthread_mutex_t = .{},

    pub fn lock(self: *@This()) void {
        _ = std.c.pthread_mutex_lock(&self.m);
    }
    pub fn unlock(self: *@This()) void {
        _ = std.c.pthread_mutex_unlock(&self.m);
    }
};

pub const Condition = if (has_std_io) struct {
    c: std.Io.Condition = .init,

    pub fn wait(self: *@This(), mutex: *Mutex) void {
        self.c.waitUncancelable(io(), &mutex.m);
    }
    pub fn signal(self: *@This()) void {
        self.c.signal(io());
    }
} else struct {
    c: std.c.pthread_cond_t = .{},

    pub fn wait(self: *@This(), mutex: *Mutex) void {
        _ = std.c.pthread_cond_wait(&self.c, &mutex.m);
    }
    pub fn signal(self: *@This()) void {
        _ = std.c.pthread_cond_signal(&self.c);
    }
};

/// Monotonic nanoseconds.
pub fn now() i96 {
    if (has_std_io) return std.Io.Clock.awake.now(io()).nanoseconds;
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.MONOTONIC, &ts);
    return @as(i96, ts.sec) * std.time.ns_per_s + ts.nsec;
}

pub fn sleep(ns: u64) void {
    if (has_std_io) {
        io().sleep(.fromNanoseconds(@intCast(ns)), .awake) catch {};
        return;
    }
    var ts: std.c.timespec = .{ .sec = @intCast(ns / std.time.ns_per_s), .nsec = @intCast(ns % std.time.ns_per_s) };
    while (std.c.nanosleep(&ts, &ts) != 0) {}
}
