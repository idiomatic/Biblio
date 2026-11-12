const std = @import("std");

/// zig build           libbiblio (../core) as zig-out/BiblioCore.xcframework, which the Biblio
///                     Xcode project links; Xcode runs it before compiling. A Debug configuration
///                     (CONFIGURATION=Debug, as Xcode sets) builds ReleaseSafe, others ReleaseFast.
/// zig build libs      just the static libraries, one per platform and architecture
///
/// Every step is cached, and installing rewrites only files whose contents changed, so with nothing
/// new Xcode finds the framework untouched.
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

    const macos = fat(b, libs[0], libs[1]);
    const ios_sim = fat(b, libs[3], libs[4]);
    const headers = b.addWriteFiles();
    _ = headers.addCopyFile(b.path("../core/include/biblio.h"), "biblio.h");
    _ = headers.add("module.modulemap",
        \\module BiblioCore {
        \\    header "biblio.h"
        \\    export *
        \\}
        \\
    );
    // xcodebuild refuses an existing output, so it writes inside a fresh directory.
    const package = b.addSystemCommand(&.{ "sh", "-c", "out=\"$1\"; shift; xcodebuild -create-xcframework \"$@\" -output \"$out/BiblioCore.xcframework\" >/dev/null", "_" });
    const out = package.addOutputDirectoryArg("xcframework");
    for ([_]std.Build.LazyPath{ macos, libs[2].getEmittedBin(), ios_sim }) |lib| {
        package.addArg("-library");
        package.addFileArg(lib);
        package.addArg("-headers");
        package.addDirectoryArg(headers.getDirectory());
    }
    b.getInstallStep().dependOn(&b.addInstallDirectory(.{
        .source_dir = out.path(b, "BiblioCore.xcframework"),
        .install_dir = .prefix,
        .install_subdir = "BiblioCore.xcframework",
    }).step);
}

/// One library for both architectures of an Apple platform.
fn fat(b: *std.Build, arm64: *std.Build.Step.Compile, x86_64: *std.Build.Step.Compile) std.Build.LazyPath {
    const lipo = b.addSystemCommand(&.{ "lipo", "-create" });
    lipo.addFileArg(arm64.getEmittedBin());
    lipo.addFileArg(x86_64.getEmittedBin());
    lipo.addArg("-output");
    return lipo.addOutputFileArg("libbiblio.a");
}
