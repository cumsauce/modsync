const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Strip symbols from release builds (default on unless -Dstrip=false). Pure
    // size win, no behavioural change; debug builds keep symbols.
    const strip = b.option(bool, "strip", "Strip debug symbols (default: true for release builds)") orelse (optimize != .debug);

    // Immediate-mode UI: dvui on the pure-Zig `wio` backend (own windowing +
    // OpenGL, no SDL/GTK/WebKit). dvui/wio bring their own link flags and C
    // sources via the dependency graph, so we only wire the modules in.
    const dvui_dep = b.dependency("dvui", .{
        .target = target,
        .optimize = optimize,
        .backend = .wio,
    });

    const mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .strip = strip,
        // Zig 0.17: linkLibC() was removed from Build.Module; libc is now a
        // module creation option (std/Build/Module.zig).
        .link_libc = true,
    });
    mod.addImport("dvui", dvui_dep.module("dvui_wio"));
    mod.addImport("wio-backend", dvui_dep.module("wio"));

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

    // `zig build test` — unit tests for the pure modules (config, github,
    // install, net, launcher, app helpers).
    const exe_tests = b.addTest(.{
        .root_module = mod,
    });
    const run_exe_tests = b.addRunArtifact(exe_tests);
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_exe_tests.step);
}
