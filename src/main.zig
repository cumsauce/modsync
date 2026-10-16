const std = @import("std");
const dvui = @import("dvui");

const config = @import("config.zig");
const app_mod = @import("app.zig");
const ui = @import("ui.zig");

pub const dvui_app: dvui.App = .{
    .config = .{
        .options = .{
            .size = .{ .w = 560.0, .h = 760.0 },
            .min_size = .{ .w = 360.0, .h = 420.0 },
            .title = "modsync",
        },
    },
    .frameFn = appFrame,
    .initFn = appInit,
    .deinitFn = appDeinit,
};

pub const main = dvui.App.main;
pub const panic = dvui.App.panic;
pub const std_options: std.Options = .{ .logFn = dvui.App.logFn };

/// The App lives for the whole process (dvui's mainloop owns the window, we
/// own the state); a plain optional keeps init/frame/deinit together. The
/// refresh worker holds a `*App` into this global, which never moves.
var g_app: ?app_mod.App = null;

/// Runs before the first full frame, between `Window.begin`/`Window.end`
/// (window + backend are already initialised, so dvui functions are usable).
pub fn appInit(win: *dvui.Window) !void {
    const alloc = win.gpa;

    // Make the seed list discoverable/editable on first run.
    config.writeDefaultsIfAbsent();

    // Load the saved config, or build one from the seed repos
    // (`<config-dir>/defaults.json`, else the embedded list).
    const loaded: ?config.Config = try config.load(alloc);
    defer if (loaded) |cfg| config.freeConfig(alloc, cfg);

    var app = try app_mod.App.initFromLoaded(alloc, loaded);
    // Hand the refresh worker a way to wake this window.
    app.win = win;
    app.wake = wakeUi;
    g_app = app;
}

/// Called from the refresh worker (background thread) to make the GUI thread
/// redraw; `win` is the `*dvui.Window` stored opaquely in `App.win`.
fn wakeUi(win: ?*anyopaque) void {
    if (win) |wp| {
        const w: *dvui.Window = @ptrCast(@alignCast(wp));
        dvui.refresh(w, @src(), null);
    }
}

/// Runs when the app exits, before the dvui window is torn down.
pub fn appDeinit(win: *dvui.Window) void {
    _ = win;
    if (g_app) |*app| {
        // The refresh worker calls dvui.refresh(win) and touches app.cfg —
        // drain it before the window (and our state) go away.
        app.drainRefresh();
        app.deinit();
        g_app = null;
    }
}

fn appFrame() !dvui.App.Result {
    const app = if (g_app) |*a| a else return .close;
    return ui.render(app);
}

test {
    _ = @import("net.zig");
    _ = @import("config.zig");
    _ = @import("github.zig");
    _ = @import("install.zig");
    _ = @import("app.zig");
    _ = @import("launcher.zig");
}

test "wio backend exports are linked into the test binary" {
    // The wio backend's platform file (macos.zig) provides the C-ABI exports
    // (`wioClose`, `wioDraw`, ...) that its own macos.m objects call. Those
    // exports are only emitted once wio.zig's top-level `comptime { _ = backend; }`
    // runs, which requires the wio module to be analyzed. The unit-test binary
    // never reaches the GUI code paths, so this test forces that analysis —
    // otherwise the link fails on undefined `_wio*` symbols.
    const wio = @import("wio-backend");
    comptime {
        _ = wio.backend;
    }
}
