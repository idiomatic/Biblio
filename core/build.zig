const std = @import("std");

/// zig build                 libbiblio (static and shared) and the biblio CLI for the host
/// zig build test            unit and fixture tests
/// zig build -Dtarget=aarch64-linux-android -Doptimize=safe   one platform's library
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
}
