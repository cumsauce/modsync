const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // On Windows/MSVC we link a prebuilt webview static lib (see below) and must
    // NOT pull in Zig's bundled libc++ — it conflicts with MSVC's STL. When
    // linking a prebuilt lib, C++ is already compiled, so Zig needs no C++ stdlib.
    const webview_prebuilt_lib = b.option([]const u8, "webview-prebuilt-lib", "Path to a prebuilt webview static lib (Windows/MSVC)");

    const mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        // Zig 0.17: linkLibC()/linkLibCpp() were removed from Build.Module;
        // libc/libc++ are now module creation options (std/Build/Module.zig).
        .link_libc = true,
        .link_libcpp = webview_prebuilt_lib == null,
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

    // On Windows/MSVC we can't let Zig compile the C++ impl itself: Zig's
    // bundled libc++ conflicts with MSVC's STL headers. So CI compiles
    // webview_impl.cc into a static lib with `cl.exe` and passes its path here
    // via -Dwebview-prebuilt-lib=<path>. When set, Zig only links it and never
    // compiles C++, sidestepping the libc++ clash entirely.
    if (webview_prebuilt_lib) |p| {
        mod.addObjectFile(.{ .cwd_relative = p });
    } else {
        mod.addCSourceFile(.{
            .file = b.path("lib/webview/webview_impl.cc"),
            .flags = &.{ "-std=c++17", "-DWEBVIEW_STATIC" },
        });
    }

    // On Windows the win32_edge backend includes <WebView2.h>, which ships in
    // Microsoft's WebView2 SDK (a NuGet package), not in the tree. CI extracts
    // it and passes its include dir here: -Dwebview2-sdk=<path>/build/native/include
    const webview2_sdk = b.option([]const u8, "webview2-sdk", "Path to the WebView2 SDK native include dir (Windows)");
    if (target.result.os.tag == .windows) {
        if (webview2_sdk) |p| {
            mod.addIncludePath(.{ .cwd_relative = p });
        }
        // WebView2.h transitively includes <EventToken.h> etc. from the Windows
        // SDK. Pass -Dwinsdk-um / -Dwinsdk-shared / -Dwinsdk-winrt when those
        // aren't already on the default include path.
        for ([_][]const u8{ "winsdk-um", "winsdk-shared", "winsdk-winrt" }) |opt_name| {
            if (b.option([]const u8, opt_name, "Windows SDK include dir")) |p| {
                mod.addIncludePath(.{ .cwd_relative = p });
            }
        }
    }

    // Native webview backends per OS (all vendored under
    // lib/webview/webview/detail/backends/). Each needs that platform's system
    // libraries, so binaries must be built on the target OS — Zig cannot
    // cross-compile the GTK/WebView2 headers from macOS.
    switch (target.result.os.tag) {
        .macos => {
            mod.linkFramework("WebKit", .{});
            mod.linkFramework("Cocoa", .{});
            mod.linkSystemLibrary("objc", .{});
        },
        .linux => {
            // webkit2gtk is what the gtk_webkitgtk backend targets. These are
            // the libs upstream webview links; exact -dev names confirmed by CI.
            mod.linkSystemLibrary("webkit2gtk-4.1", .{});
            mod.linkSystemLibrary("javascriptcoregtk-4.1", .{});
            mod.linkSystemLibrary("gtk-3", .{});
            mod.linkSystemLibrary("gobject-2.0", .{});
            mod.linkSystemLibrary("glib-2.0", .{});
            mod.linkSystemLibrary("pthread", .{});
        },
        .windows => {
            // win32_edge backend: COM/OLE for the WebView2 loader; the WebView2
            // runtime itself is loaded dynamically at run time.
            mod.linkSystemLibrary("ole32", .{});
            mod.linkSystemLibrary("oleaut32", .{});
            mod.linkSystemLibrary("user32", .{});
            mod.linkSystemLibrary("gdi32", .{});
            mod.linkSystemLibrary("advapi32", .{});
            mod.linkSystemLibrary("shell32", .{});
            mod.linkSystemLibrary("shlwapi", .{});
            mod.linkSystemLibrary("version", .{});
            // NOTE: do NOT explicitly link the CRT (ucrt/vcruntime/msvcprt) —
            // Zig's msvc mode provides it via the detected libc installation.
            // The prebuilt webview lib's C++ runtime symbols resolve against
            // that same CRT.
        },
        else => {},
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
