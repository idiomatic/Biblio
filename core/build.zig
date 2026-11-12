const std = @import("std");

/// zig build                 libbiblio (static and shared) and the biblio CLI for the host
/// zig build test            unit and fixture tests
/// zig build -Dtarget=aarch64-linux-android -Doptimize=safe   one platform's library
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // The mock library (src/mock.zig) uses libc outside Windows, and is compiled out of release builds.
    const mock_libc = target.result.os.tag == .linux and (optimize == .debug or optimize == .safe);

    // Both libraries share one module. Each still compiles it: a shared library linked from
    // one object loses the start code a Windows DLL needs.
    const lib_mod = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = if (mock_libc) true else null,
    });

    const static = b.addLibrary(.{ .name = "biblio", .root_module = lib_mod, .linkage = .static });
    static.installHeader(b.path("include/biblio.h"), "biblio.h");
    b.installArtifact(static);

    const shared = b.addLibrary(.{ .name = "biblio", .root_module = lib_mod, .linkage = .dynamic });
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

    // With libc, for the mock library's tests; without it (where a target allows), for the
    // allocator the libraries ship with.
    const test_step = b.step("test", "Run unit and fixture tests");
    const libc_options: []const bool = if (target.result.os.tag.isDarwin()) &.{true} else &.{ true, false };
    for (libc_options) |libc| {
        const tests = b.addTest(.{ .root_module = b.createModule(.{
            .root_source_file = b.path("src/root.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = libc,
        }) });
        test_step.dependOn(&b.addRunArtifact(tests).step);
    }
}
