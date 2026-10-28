const std = @import("std");

/// zig build            the Biblio GNOME app (needs gtk4, libadwaita-1 and libsecret-1 via pkg-config)
/// zig build run        run it
/// zig build -Dtarget=aarch64-linux-gnu -Dsysroot=/path/to/sysroot
///                      cross-compile (e.g. for a Raspberry Pi) against a Debian sysroot holding
///                      the -dev packages and the GTK, libadwaita, libsecret, GLib and cairo libraries
/// zig build check -Dtarget=x86_64-linux-gnu -Dsysroot=/path/to/sysroot
///                      type-check only; the sysroot needs just the -dev packages' headers
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const sysroot = b.option([]const u8, "sysroot", "Debian sysroot to build against instead of pkg-config (for cross-compiling)");
    // Debian's multiarch directory, such as aarch64-linux-gnu.
    const multiarch = b.fmt("{s}-linux-gnu", .{@tagName(target.result.cpu.arch)});

    const c = b.addTranslateC(.{
        .root_source_file = b.path("src/c.h"),
        .target = target,
        .optimize = optimize,
    });
    if (sysroot) |root| {
        const include = [_][]const u8{
            "gtk-4.0",   "libadwaita-1",   "libsecret-1",  "glib-2.0",  "cairo",   "pango-1.0",
            "harfbuzz",  "gdk-pixbuf-2.0", "graphene-1.0", "freetype2", "fribidi", "pixman-1",
            "appstream", "libpng16",       "",
        };
        for (include) |d| c.addIncludePath(.{ .cwd_relative = b.pathJoin(&.{ root, "usr/include", d }) });
        for ([_][]const u8{ "glib-2.0", "graphene-1.0" }) |d| {
            c.addIncludePath(.{ .cwd_relative = b.pathJoin(&.{ root, "usr/lib", multiarch, d, "include" }) });
        }
    } else {
        for ([_][]const u8{ "gtk4", "libadwaita-1", "libsecret-1" }) |lib| c.linkSystemLibrary(lib, .{});
    }

    const core = b.createModule(.{
        .root_source_file = b.path("../core/src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    const mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    mod.addImport("c", c.createModule());
    mod.addImport("biblio", core);

    const check = b.addObject(.{ .name = "biblio-gnome", .root_module = mod });
    b.step("check", "Type-check without linking").dependOn(&check.step);

    if (sysroot) |root| {
        // Link the libraries the app calls directly; their own dependencies are found on the
        // device at run time.
        mod.addLibraryPath(.{ .cwd_relative = b.pathJoin(&.{ root, "usr/lib", multiarch }) });
        for ([_][]const u8{ "gtk-4", "adwaita-1", "secret-1", "gio-2.0", "gobject-2.0", "glib-2.0", "cairo" }) |lib| {
            mod.linkSystemLibrary(lib, .{ .use_pkg_config = .no });
        }
    } else {
        for ([_][]const u8{ "gtk4", "libadwaita-1", "libsecret-1" }) |lib| mod.linkSystemLibrary(lib, .{});
    }

    const exe = b.addExecutable(.{ .name = "biblio-gnome", .root_module = mod });
    if (sysroot != null) exe.linker_allow_shlib_undefined = true;
    b.installArtifact(exe);
    b.installFile("data/com.rbrian.Biblio.desktop", "share/applications/com.rbrian.Biblio.desktop");
    b.installFile("data/com.rbrian.Biblio.metainfo.xml", "share/metainfo/com.rbrian.Biblio.metainfo.xml");

    const run = b.addRunArtifact(exe);
    b.step("run", "Run Biblio").dependOn(&run.step);
}
