const std = @import("std");

/// zig build           libbiblio (../core) as zig-out/lib/PLATFORM/libbiblio.a, with the BiblioCore
///                     module in zig-out/include, which the Biblio Xcode project links; Xcode runs
///                     it with -Dplatform=$PLATFORM_NAME before compiling. A Debug configuration
///                     (CONFIGURATION=Debug, as Xcode sets) builds ReleaseSafe, others ReleaseFast.
/// zig build libs      just the static libraries, one per platform and architecture
///
/// Every step is cached, and installing rewrites only files whose contents changed, so with nothing
/// new Xcode finds the library untouched.
pub fn build(b: *std.Build) void {
    const debug = std.mem.eql(u8, b.graph.environ_map.get("CONFIGURATION") orelse "Release", "Debug");
    const optimize = b.option(std.builtin.OptimizeMode, "optimize", "Optimize mode (default: ReleaseSafe for Debug, else ReleaseFast)") orelse
        @as(std.builtin.OptimizeMode, if (debug) .ReleaseSafe else .ReleaseFast);

    const targets = [_]struct { name: []const u8, query: std.Target.Query }{
        .{ .name = "macos-arm64", .query = .{ .cpu_arch = .aarch64, .os_tag = .macos } },
        .{ .name = "macos-x86_64", .query = .{ .cpu_arch = .x86_64, .os_tag = .macos } },
        .{ .name = "ios-arm64", .query = .{ .cpu_arch = .aarch64, .os_tag = .ios } },
        .{ .name = "ios-sim-arm64", .query = .{ .cpu_arch = .aarch64, .os_tag = .ios, .abi = .simulator } },
        .{ .name = "ios-sim-x86_64", .query = .{ .cpu_arch = .x86_64, .os_tag = .ios, .abi = .simulator } },
    };
    const only = b.option([]const u8, "platform", "Install only this Xcode platform: macosx, iphoneos, or iphonesimulator (default: all)");
    const libs_step = b.step("libs", "Build the static libraries for macOS, iOS, and the iOS simulator");
    var libs: [targets.len]*std.Build.Step.Compile = undefined;
    for (targets, &libs) |t, *slot| {
        const lib = b.addLibrary(.{
            .name = "biblio",
            .linkage = .static,
            .root_module = b.createModule(.{
                .root_source_file = b.path("../core/src/root.zig"),
                .target = b.resolveTargetQuery(t.query),
                .optimize = optimize,
                // Apple platforms always have libSystem; on iOS the core's locks use its pthreads.
                .link_libc = true,
            }),
        });
        lib.bundle_compiler_rt = true;
        slot.* = lib;
        const install = b.addInstallArtifact(lib, .{ .dest_dir = .{ .override = .{ .custom = b.fmt("libs/{s}", .{t.name}) } } });
        libs_step.dependOn(&install.step);
    }

    // One library per Xcode platform (PLATFORM_NAME), beside the module map Swift imports. Plain
    // files, unlike an XCFramework, need not exist before Xcode plans a build, so a clean build
    // recovers by running this first.
    const platforms = [_]struct { name: []const u8, lib: std.Build.LazyPath }{
        .{ .name = "macosx", .lib = fat(b, libs[0], libs[1]) },
        .{ .name = "iphoneos", .lib = libs[2].getEmittedBin() },
        .{ .name = "iphonesimulator", .lib = fat(b, libs[3], libs[4]) },
    };
    for (platforms) |p| {
        if (only) |name| if (!std.mem.eql(u8, name, p.name)) continue;
        b.getInstallStep().dependOn(&b.addInstallFile(p.lib, b.fmt("lib/{s}/libbiblio.a", .{p.name})).step);
    }
    b.getInstallStep().dependOn(&b.addInstallFile(b.path("../core/include/biblio.h"), "include/biblio.h").step);
    const modulemap = b.addWriteFiles().add("module.modulemap",
        \\module BiblioCore {
        \\    header "biblio.h"
        \\    export *
        \\}
        \\
    );
    b.getInstallStep().dependOn(&b.addInstallFile(modulemap, "include/module.modulemap").step);
}

/// One library for both architectures of an Apple platform.
fn fat(b: *std.Build, arm64: *std.Build.Step.Compile, x86_64: *std.Build.Step.Compile) std.Build.LazyPath {
    const lipo = b.addSystemCommand(&.{ "lipo", "-create" });
    lipo.addFileArg(arm64.getEmittedBin());
    lipo.addFileArg(x86_64.getEmittedBin());
    lipo.addArg("-output");
    return lipo.addOutputFileArg("libbiblio.a");
}
