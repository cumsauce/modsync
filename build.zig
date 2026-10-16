const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        // Zig 0.17: linkLibC()/linkLibCpp() were removed from Build.Module;
        // libc/libc++ are now module creation options (std/Build/Module.zig).
        .link_libc = true,
        .link_libcpp = true,
    });

    // Zig 0.17 removed @cImport; translate the vendored webview header into a
    // Zig module instead (std/Build/Step/TranslateC.zig).
    const translate_c = b.addTranslateC(.{
        .root_source_file = b.path("src/webview_api.h"),
        .target = target,
        .optimize = optimize,
    });
    translate_c.addIncludePath(b.path("lib/webview"));
    mod.addImport("webview_api", translate_c.createModule());

    // Vendored webview C library (see lib/webview/ and TOOLCHAIN.md).
    mod.addIncludePath(b.path("lib/webview"));
    mod.addCSourceFile(.{
        .file = b.path("lib/webview/webview_impl.cc"),
        .flags = &.{ "-std=c++17", "-DWEBVIEW_STATIC" },
    });

    if (target.result.os.tag == .macos) {
        mod.linkFramework("WebKit", .{});
        mod.linkFramework("Cocoa", .{});
        mod.linkSystemLibrary("objc", .{});
    }

    const exe = b.addExecutable(.{
        .name = "modsync",
        .root_module = mod,
    });
    b.installArtifact(exe);

    // `zig build run` — run the app from the install directory.
    const run_step = b.step("run", "Run modsync");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.addPassthruArgs();

    // `zig build test` — later tasks attach their test files to this step.
    const exe_tests = b.addTest(.{
        .root_module = mod,
    });
    const run_exe_tests = b.addRunArtifact(exe_tests);
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_exe_tests.step);
}
