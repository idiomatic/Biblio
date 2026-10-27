const std = @import("std");

/// Builds libbiblio_jni.so for each Android ABI into ../app/src/main/jniLibs, which Gradle
/// packages. Gradle runs this before each build (see app/build.gradle.kts).
pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .safe });
    const abis = [_]struct { abi: []const u8, query: std.Target.Query }{
        .{ .abi = "arm64-v8a", .query = .{ .cpu_arch = .aarch64, .os_tag = .linux, .abi = .android, .android_api_level = 29 } },
        .{ .abi = "x86_64", .query = .{ .cpu_arch = .x86_64, .os_tag = .linux, .abi = .android, .android_api_level = 29 } },
    };
    for (abis) |t| {
        const target = b.resolveTargetQuery(t.query);
        const core = b.createModule(.{ .root_source_file = b.path("../../core/src/root.zig"), .target = target, .optimize = optimize });
        const mod = b.createModule(.{ .root_source_file = b.path("src/jni.zig"), .target = target, .optimize = optimize });
        mod.addImport("biblio", core);
        const lib = b.addLibrary(.{ .name = "biblio_jni", .linkage = .dynamic, .root_module = mod });
        const install = b.addInstallArtifact(lib, .{ .dest_dir = .{ .override = .{ .custom = b.fmt("../../app/src/main/jniLibs/{s}", .{t.abi}) } } });
        b.getInstallStep().dependOn(&install.step);
    }
}
