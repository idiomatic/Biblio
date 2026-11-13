const std = @import("std");

/// Builds libbiblio_jni.so for each Android ABI into ../app/src/main/jniLibs, which Gradle
/// packages. Gradle runs this before each build (see app/build.gradle.kts), passing its minSdk as
/// -Dapi and the NDK's location as -Dndk; the libraries link the NDK's bionic (libc.so, libm.so,
/// libdl.so). Without -Dndk, ANDROID_NDK_HOME, or ANDROID_HOME/ndk/NDK_VERSION, the build stops.
/// `zig build test` tests the shim on this machine.
const ndk_version = "29.0.14206865";

pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .safe });
    const api = b.option(u32, "api", "Android API level to target (default 29, Gradle's minSdk)") orelse 29;
    const abis = [_]struct { abi: []const u8, triple: []const u8, query: std.Target.Query }{
        .{ .abi = "arm64-v8a", .triple = "aarch64-linux-android", .query = .{ .cpu_arch = .aarch64, .os_tag = .linux, .abi = .android, .android_api_level = api } },
        .{ .abi = "x86_64", .triple = "x86_64-linux-android", .query = .{ .cpu_arch = .x86_64, .os_tag = .linux, .abi = .android, .android_api_level = api } },
    };
    const sysroot = ndkSysroot(b);
    const missing = b.addFail("the Android NDK was not found: pass -Dndk=PATH, or set ANDROID_NDK_HOME, or install \"ndk;" ++ ndk_version ++ "\" under ANDROID_HOME");
    const libc_files = b.addWriteFiles();
    for (abis) |t| {
        const target = b.resolveTargetQuery(t.query);
        const core = b.createModule(.{ .root_source_file = b.path("../../core/src/root.zig"), .target = target, .optimize = optimize, .link_libc = true });
        const mod = b.createModule(.{ .root_source_file = b.path("src/jni.zig"), .target = target, .optimize = optimize, .link_libc = true });
        mod.addImport("biblio", core);
        const lib = b.addLibrary(.{ .name = "biblio_jni", .linkage = .dynamic, .root_module = mod });
        if (sysroot) |root| {
            lib.setLibCFile(libc_files.add(b.fmt("libc-{s}.txt", .{t.abi}), b.fmt(
                \\include_dir={0s}/usr/include
                \\sys_include_dir={0s}/usr/include/{1s}
                \\crt_dir={0s}/usr/lib/{1s}/{2d}
                \\msvc_lib_dir=
                \\kernel32_lib_dir=
                \\gcc_dir={0s}/usr/lib/{1s}/{2d}
                \\darwin_sdk_dir=
                \\
            , .{ root, t.triple, api })));
        } else lib.step.dependOn(&missing.step);
        const install = b.addInstallArtifact(lib, .{ .dest_dir = .{ .override = .{ .custom = b.fmt("../../app/src/main/jniLibs/{s}", .{t.abi}) } } });
        b.getInstallStep().dependOn(&install.step);
    }

    // zig build test: the shim's conversions, on this machine against a stand-in JVM.
    const host = b.graph.host;
    const core = b.createModule(.{ .root_source_file = b.path("../../core/src/root.zig"), .target = host, .link_libc = true });
    const mod = b.createModule(.{ .root_source_file = b.path("src/jni.zig"), .target = host, .link_libc = true });
    mod.addImport("biblio", core);
    const tests = b.addTest(.{ .root_module = mod });
    b.step("test", "Test the JNI conversions").dependOn(&b.addRunArtifact(tests).step);
}

/// The NDK's sysroot: from -Dndk, else ANDROID_NDK_HOME, else the pinned version under
/// ANDROID_HOME; null if there is none.
fn ndkSysroot(b: *std.Build) ?[]const u8 {
    const root = b.option([]const u8, "ndk", "Android NDK directory (default ANDROID_NDK_HOME, else ANDROID_HOME/ndk/" ++ ndk_version ++ ")") orelse
        b.graph.environ_map.get("ANDROID_NDK_HOME") orelse
        if (b.graph.environ_map.get("ANDROID_HOME")) |sdk| b.fmt("{s}/ndk/{s}", .{ sdk, ndk_version }) else return null;
    const host = switch (b.graph.host.result.os.tag) {
        .macos => "darwin-x86_64",
        .windows => "windows-x86_64",
        else => "linux-x86_64",
    };
    const sysroot = b.fmt("{s}/toolchains/llvm/prebuilt/{s}/sysroot", .{ root, host });
    std.Io.Dir.accessAbsolute(b.graph.io, sysroot, .{}) catch return null;
    return sysroot;
}
