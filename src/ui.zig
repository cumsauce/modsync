//! dvui rendering for modsync: one frame function plus the widgets' layout.
//! dvui is immediate-mode — widgets are rebuilt every frame — so all
//! persistent state (text buffers, launcher discovery, statuses) lives in
//! `App`; this file only builds widgets and forwards user actions to it.

const std = @import("std");
const dvui = @import("dvui");
const app_mod = @import("app.zig");

const App = app_mod.App;

/// Colors confirmed against `Options.zig` (`color_text: ?ColorOrGradient`)
/// and `Gradient.zig` (`ColorOrGradient = union(enum) { color: Color, ... }`).
const err_color: dvui.Color = .{ .r = 200, .g = 60, .b = 60, .a = 250 };
const installed_color: dvui.Color = .{ .r = 90, .g = 160, .b = 90, .a = 250 };
const idle_color: dvui.Color = .{ .r = 140, .g = 140, .b = 140, .a = 250 };
const status_color: dvui.Color = .{ .r = 80, .g = 130, .b = 200, .a = 250 };

/// Render one frame. Called from `main.zig`'s `frameFn` with the long-lived
/// App (owned by a global in `main.zig`, so no allocation happens here).
pub fn render(app: *App) !dvui.App.Result {
    var scroll = dvui.scrollArea(@src(), .{}, .{ .expand = .both, .style = .window });
    defer scroll.deinit();

    dvui.label(@src(), "modsync", .{}, .{ .font = .theme(.title) });

    launchersSection(app);
    _ = dvui.separator(@src(), .{ .expand = .horizontal });

    minecraftDirSection(app);
    _ = dvui.separator(@src(), .{ .expand = .horizontal });

    trackedModsSection(app);
    _ = dvui.separator(@src(), .{ .expand = .horizontal });

    addRepoSection(app);

    return .ok;
}

/// Header row: a title on the left, a spacer, then an action button pushed
/// to the right edge. `src` is the caller's `@src()` — dvui derives widget
/// ids from it, so every call site must be a distinct source location (a
/// helper's own `@src()` would collide when called more than once per frame).
fn sectionHead(
    src: std.builtin.SourceLocation,
    comptime title: []const u8,
    button_label: []const u8,
    grayed: bool,
) bool {
    var head = dvui.box(src, .{ .dir = .horizontal }, .{ .expand = .horizontal });
    defer head.deinit();

    dvui.label(@src(), title, .{}, .{ .font = .theme(.title), .gravity_y = 0.5 });

    var spacer = dvui.box(@src(), .{}, .{ .expand = .horizontal });
    defer spacer.deinit();

    return dvui.button(@src(), button_label, .{ .grayed = grayed }, .{});
}

/// 1. Detected launcher profiles + Rescan. `app.launchers` is only ever
/// written on this (GUI) thread, so no locking is needed here.
fn launchersSection(app: *App) void {
    if (sectionHead(@src(), "Launchers", "Rescan", false)) {
        app.rescanLaunchers() catch {};
    }

    if (app.launchers) |*d| {
        if (d.profiles.len == 0) {
            dvui.labelNoFmt(@src(), "No launcher profiles detected", .{}, .{});
        }
        // Same @src() every iteration, so each row needs a unique id_extra.
        for (d.profiles, 0..) |p, i| {
            var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .id_extra = i });
            defer row.deinit();

            dvui.label(@src(), "{s}: {s}", .{ @tagName(p.kind), p.name }, .{ .gravity_y = 0.5 });

            var spacer = dvui.box(@src(), .{}, .{ .expand = .horizontal });
            defer spacer.deinit();

            if (dvui.button(@src(), "Use", .{}, .{})) {
                if (app.selectProfile(p.gameDir) catch false) {
                    // Folder changed: re-seed the textEntry below this frame.
                    app.ui.mc_dir_dirty = true;
                }
            }
        }
        for (d.errors, 0..) |err, i| {
            dvui.label(@src(), "error: {s}", .{err}, .{
                .color_text = .{ .color = err_color },
                .id_extra = i,
            });
        }
    }
}

/// 2. Minecraft folder textEntry + Save. The buffer lives in `App.ui` and is
/// only re-seeded when `mc_dir_dirty` is set (never every frame, which would
/// clobber typing).
fn minecraftDirSection(app: *App) void {
    dvui.label(@src(), "Minecraft folder", .{}, .{});

    var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
    defer row.deinit();

    var te = dvui.textEntry(@src(), .{
        .text = .{ .buffer = &app.ui.mc_dir_buf },
        .placeholder = "/path/to/.minecraft",
    }, .{ .expand = .horizontal });
    defer te.deinit();

    if (app.ui.mc_dir_dirty) {
        // cfg.minecraftDir is only ever written on this (GUI) thread, so no
        // lock is needed to read it; textSet copies into our buffer.
        te.textSet(app.cfg.minecraftDir, false);
        app.ui.mc_dir_dirty = false;
    }

    if (dvui.button(@src(), "Save", .{}, .{})) {
        _ = app.setMinecraftDir(te.textGet()) catch false;
    }
}

/// 3. Tracked mods: refresh/restore actions + one row per cfg.repos entry.
fn trackedModsSection(app: *App) void {
    const refreshing = app.refreshing.load(.acquire);
    if (sectionHead(@src(), "Tracked mods", if (refreshing) "Refreshing…" else "Refresh all", refreshing)) {
        // The button is grayed while a worker runs, and startRefresh also
        // guards double-spawn atomically, so a stray click is a no-op.
        app.startRefresh();
    }
    if (dvui.button(@src(), "Restore defaults", .{}, .{})) {
        _ = app.restoreDefaults() catch false;
    }

    var remove_spec_buf: [1024]u8 = undefined;
    var remove_spec: ?[]const u8 = null;
    {
        // One critical section for the whole list: the refresh worker
        // replaces installedVersion/status strings under the same lock, and
        // Remove's action must run after the loop (it frees the slice we are
        // iterating), so the spec is copied out while the strings are stable.
        app.mutex.lock();
        defer app.mutex.unlock();

        if (app.cfg.repos.len == 0) {
            dvui.labelNoFmt(@src(), "No tracked repos — add one below.", .{}, .{});
        }

        // Same @src() every iteration, so each row needs a unique id_extra.
        for (app.cfg.repos, 0..) |repo, i| {
            var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .id_extra = i });
            defer row.deinit();

            dvui.label(@src(), "{s}/{s}", .{ repo.owner, repo.name }, .{ .gravity_y = 0.5 });

            const version = repo.installedVersion orelse "not installed";
            dvui.labelNoFmt(@src(), version, .{}, .{
                .gravity_y = 0.5,
                .color_text = .{ .color = if (repo.installedVersion != null) installed_color else idle_color },
            });

            if (app.findStatusLocked(repo.owner, repo.name)) |status| {
                dvui.labelNoFmt(@src(), status, .{}, .{
                    .gravity_y = 0.5,
                    .color_text = .{ .color = if (std.mem.startsWith(u8, status, "error")) err_color else status_color },
                });
            }

            var spacer = dvui.box(@src(), .{}, .{ .expand = .horizontal });
            defer spacer.deinit();

            if (dvui.button(@src(), "Remove", .{}, .{})) {
                remove_spec = std.fmt.bufPrint(&remove_spec_buf, "{s}/{s}", .{ repo.owner, repo.name }) catch null;
            }
        }
    }

    if (remove_spec) |spec| {
        _ = app.removeRepo(spec) catch false;
    }
}

/// 4. Add repo: textEntry (hint "owner/name") + Add. On success the entry is
/// cleared; the backing ArrayList lives in `App.ui`.
fn addRepoSection(app: *App) void {
    dvui.label(@src(), "Add repo", .{}, .{});

    var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
    defer row.deinit();

    var te = dvui.textEntry(@src(), .{
        .text = .{ .array_list = .{ .backing = &app.ui.add_buf, .allocator = app.allocator } },
        .placeholder = "owner/name",
    }, .{ .expand = .horizontal });
    defer te.deinit();

    if (dvui.button(@src(), "Add", .{}, .{})) {
        const spec = te.textGet();
        if (spec.len > 0 and (app.addRepo(spec) catch false)) {
            te.textSet("", false);
        }
    }
}
