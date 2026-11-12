const std = @import("std");

/// zig build                 libbiblio (static and shared) and the biblio CLI for the host
/// zig build test            unit and fixture tests
/// zig build -Dtarget=aarch64-linux-android -Doptimize=safe   one platform's library
/// zig build apple           static libraries for macOS, iOS and the iOS simulator (see ../apple/)
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // The mock library (src/mock.zig) uses libc outside Windows, and is compiled out of release builds.
    const mock_libc = target.result.os.tag == .linux and (optimize == .debug or optimize == .safe);

    const lib_mod = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = if (mock_libc) true else null,
    });

    const static = b.addLibrary(.{ .name = "biblio", .root_module = lib_mod, .linkage = .static });
    static.installHeader(b.path("include/biblio.h"), "biblio.h");
    b.installArtifact(static);

    const shared_mod = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = if (mock_libc) true else null,
    });
    const shared = b.addLibrary(.{ .name = "biblio", .root_module = shared_mod, .linkage = .dynamic });
    b.installArtifact(shared);

    const cli_mod = b.createModule(.{
        .root_source_file = b.path("cli/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = if (mock_libc) true else null,
    });
    cli_mod.addImport("biblio", lib_mod);
    const cli = b.addExecutable(.{ .name = "biblio", .root_module = cli_mod });
    b.installArtifact(cli);

    const run = b.addRunArtifact(cli);
    b.step("run", "Run the biblio CLI").dependOn(&run.step);

    const tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    }) });
    b.step("test", "Run unit and fixture tests").dependOn(&b.addRunArtifact(tests).step);

    // Apple platforms: one static library per SDK, combined into an XCFramework by apple/build-xcframework.sh.
    const apple = b.step("apple", "Build static libraries for macOS, iOS and the iOS simulator");
    const apple_targets = [_]struct { name: []const u8, query: std.Target.Query }{
        .{ .name = "macos-arm64", .query = .{ .cpu_arch = .aarch64, .os_tag = .macos } },
        .{ .name = "macos-x86_64", .query = .{ .cpu_arch = .x86_64, .os_tag = .macos } },
        .{ .name = "ios-arm64", .query = .{ .cpu_arch = .aarch64, .os_tag = .ios } },
        .{ .name = "ios-sim-arm64", .query = .{ .cpu_arch = .aarch64, .os_tag = .ios, .abi = .simulator } },
        .{ .name = "ios-sim-x86_64", .query = .{ .cpu_arch = .x86_64, .os_tag = .ios, .abi = .simulator } },
    };
    for (apple_targets) |t| {
        const lib = b.addLibrary(.{
            .name = "biblio",
            .linkage = .static,
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/root.zig"),
                .target = b.resolveTargetQuery(t.query),
                .optimize = if (optimize == .debug) .safe else optimize,
                // Apple platforms always have libSystem; on iOS the core's locks use its pthreads.
                .link_libc = true,
            }),
        });
        lib.bundle_compiler_rt = true;
        const install = b.addInstallArtifact(lib, .{ .dest_dir = .{ .override = .{ .custom = b.fmt("apple/{s}", .{t.name}) } } });
        apple.dependOn(&install.step);
    }
}
