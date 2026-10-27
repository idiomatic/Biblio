const std = @import("std");

/// zig build            the Biblio GNOME app (needs gtk4, libadwaita-1 and libsecret-1 via pkg-config)
/// zig build run        run it
/// zig build check -Dtarget=x86_64-linux-gnu -Dheaders=/path/to/sysroot
///                      type-check against extracted -dev package headers, without linking
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const headers = b.option([]const u8, "headers", "Sysroot holding GTK, libadwaita and libsecret headers (for `check`)");

    const c = b.addTranslateC(.{
        .root_source_file = b.path("src/c.h"),
        .target = target,
        .optimize = optimize,
    });
    if (headers) |root| {
        const dirs = [_][]const u8{
            "usr/include/gtk-4.0",                          "usr/include/libadwaita-1",  "usr/include/libsecret-1",
            "usr/include/glib-2.0",                         "usr/include/cairo",         "usr/include/pango-1.0",
            "usr/include/harfbuzz",                         "usr/include/gdk-pixbuf-2.0", "usr/include/graphene-1.0",
            "usr/include/freetype2",                        "usr/include/fribidi",       "usr/include/pixman-1",
            "usr/include/appstream",                        "usr/include/libpng16",      "usr/include",
            "usr/lib/x86_64-linux-gnu/glib-2.0/include",    "usr/lib/x86_64-linux-gnu/graphene-1.0/include",
        };
        for (dirs) |d| c.addIncludePath(.{ .cwd_relative = b.pathJoin(&.{ root, d }) });
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
    if (headers != null) return;

    for ([_][]const u8{ "gtk4", "libadwaita-1", "libsecret-1" }) |lib| mod.linkSystemLibrary(lib, .{});

    const exe = b.addExecutable(.{ .name = "biblio-gnome", .root_module = mod });
    b.installArtifact(exe);
    b.installFile("data/com.rbrian.Biblio.desktop", "share/applications/com.rbrian.Biblio.desktop");
    b.installFile("data/com.rbrian.Biblio.metainfo.xml", "share/metainfo/com.rbrian.Biblio.metainfo.xml");

    const run = b.addRunArtifact(exe);
    b.step("run", "Run Biblio").dependOn(&run.step);
}
