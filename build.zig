const std = @import("std");

/// zig build cross          cross-compile the core for Linux, Windows, and Android, plus the GNOME app for Linux
/// -Dsysroots=DIR           where cross builds keep Debian sysroots, relative to here (default .zig-cache/sysroots)
pub fn build(b: *std.Build) void {
    const sysroots = b.option([]const u8, "sysroots", "Directory for Debian sysroots") orelse ".zig-cache/sysroots";
    const optimize = b.option([]const u8, "optimize", "Optimize mode for cross builds (default ReleaseSmall)") orelse "ReleaseSmall";
    const opt = b.fmt("-Doptimize={s}", .{optimize});

    // Cross-compile: Zig links for every target from any host, so no VM is needed.
    // Each command runs from the project root; paths are relative to it.
    const cross = b.step("cross", "Cross-compile the core and the GNOME app for other platforms");
    const core_targets = [_][]const u8{
        "aarch64-linux-gnu",  "x86_64-linux-gnu",      "aarch64-windows-gnu",
        "x86_64-windows-gnu", "aarch64-linux-android",
    };
    for (core_targets) |t| {
        const run = b.addSystemCommand(&.{ "sh", "-c", b.fmt("R=$PWD; cd core && '{s}' build -Dtarget={s} {s} --prefix \"$R/zig-out/cross/core-{s}\"", .{ b.graph.zig_exe, t, opt, t }) });
        cross.dependOn(&run.step);
    }
    const linux_arches = [_]struct { zig: []const u8, deb: []const u8 }{
        .{ .zig = "aarch64", .deb = "arm64" },
        .{ .zig = "x86_64", .deb = "amd64" },
    };
    for (linux_arches) |a| {
        const root = b.fmt("{s}/{s}", .{ sysroots, a.deb });
        const fetch = b.addSystemCommand(&.{ "sh", "-c", b.fmt("[ -d '{s}/root/usr/include' ] || sh gnome/debian-sysroot.sh {s} '{s}' >/dev/null", .{ root, a.deb, root }) });
        const run = b.addSystemCommand(&.{ "sh", "-c", b.fmt("R=$PWD; cd gnome && '{s}' build -Dtarget={s}-linux-gnu -Dsysroot=\"$R/{s}/root\" {s} --prefix \"$R/zig-out/cross/gnome-{s}-linux-gnu\"", .{ b.graph.zig_exe, a.zig, root, opt, a.zig }) });
        run.step.dependOn(&fetch.step);
        cross.dependOn(&run.step);
    }
}
