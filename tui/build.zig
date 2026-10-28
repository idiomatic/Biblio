const std = @import("std");

/// zig build        the Biblio terminal app (zig-out/bin/biblio-tui)
/// zig build run    run it
/// zig build test   test the terminal layer
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

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
    mod.addImport("biblio", core);

    const exe = b.addExecutable(.{ .name = "biblio-tui", .root_module = mod });
    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    b.step("run", "Run Biblio in the terminal").dependOn(&run.step);

    const tests = b.addTest(.{ .root_module = mod });
    b.step("test", "Test the terminal layer").dependOn(&b.addRunArtifact(tests).step);
}
