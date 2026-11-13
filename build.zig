const std = @import("std");

/// zig build cross          cross-compile the core for Linux, Windows, and Android, plus the GNOME app for Linux,
///                          into zig-out/cross
/// -Dsysroots=DIR           where cross builds keep Debian sysroots, relative to here (default .zig-cache/sysroots)
pub fn build(b: *std.Build) void {
    const sysroots = b.option([]const u8, "sysroots", "Directory for Debian sysroots") orelse ".zig-cache/sysroots";
    const optimize = b.option(std.builtin.OptimizeMode, "optimize", "Optimize mode for cross builds (default small)") orelse .small;
    const opt = b.fmt("-Doptimize={t}", .{optimize});
    const sysroots_path = if (std.fs.path.isAbsolute(sysroots)) b.graph.cwdRelativePath(sysroots) else b.path(sysroots);

    // Cross-compile: Zig links for every target from any host, so no VM is needed. Fetching the
    // GNOME app's Debian sysroots needs a POSIX shell.
    const cross = b.step("cross", "Cross-compile the core and the GNOME app for other platforms");
    const core_targets = [_][]const u8{
        "aarch64-linux-gnu",  "x86_64-linux-gnu",      "aarch64-windows-gnu",
        "x86_64-windows-gnu", "aarch64-linux-android",
    };
    for (core_targets) |t| {
        const run = b.addSystemCommand(&.{ b.graph.zig_exe, "build", b.fmt("-Dtarget={s}", .{t}), opt, "--build-file" });
        run.addFileArg(b.path("core/build.zig"));
        run.addArg("--prefix");
        run.addDirectoryArg2(b.graph.path(.install_prefix, b.fmt("cross/core-{s}", .{t})), .{});
        cross.dependOn(&run.step);
    }
    const linux_arches = [_]struct { zig: []const u8, deb: []const u8 }{
        .{ .zig = "aarch64", .deb = "arm64" },
        .{ .zig = "x86_64", .deb = "amd64" },
    };
    for (linux_arches) |a| {
        const root = sysroots_path.path(b, a.deb);
        // The script returns at once when an earlier run finished (it leaves a `complete` file).
        const fetch = b.addSystemCommand(&.{"sh"});
        fetch.addFileArg(b.path("gnome/debian-sysroot.sh"));
        fetch.addArg(a.deb);
        fetch.addDirectoryArg2(root, .{});
        fetch.expectExitCode(0);
        fetch.has_side_effects = true;
        const run = b.addSystemCommand(&.{ b.graph.zig_exe, "build", b.fmt("-Dtarget={s}-linux-gnu", .{a.zig}), opt, "--build-file" });
        run.addFileArg(b.path("gnome/build.zig"));
        run.addDirectoryArg2(root.path(b, "root"), .{ .prefix = "-Dsysroot=" });
        run.addArg("--prefix");
        run.addDirectoryArg2(b.graph.path(.install_prefix, b.fmt("cross/gnome-{s}-linux-gnu", .{a.zig})), .{});
        run.step.dependOn(&fetch.step);
        cross.dependOn(&run.step);
    }
}
