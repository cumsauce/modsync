//! dvui rendering for modsync: one frame function plus the widgets' layout.
//! dvui is immediate-mode — widgets are rebuilt every frame — so all
//! persistent state (text buffers, launcher discovery, statuses) lives in
//! `App`; this file only builds widgets and forwards user actions to it.

const std = @import("std");
const dvui = @import("dvui");
const app_mod = @import("app.zig");

const App = app_mod.App;

// ---------------------------------------------------------------------------
// Palette — "modsync" dark theme with a purple/fuchsia accent.
// ---------------------------------------------------------------------------

/// #A855F7 purple-500 — primary (solid) button fill, focus, ghost text.
const accent: dvui.Color = .{ .r = 168, .g = 85, .b = 247, .a = 255 };
/// #7E22CE purple-700 — control borders (deep outline of the accent fill).
const accent_deep: dvui.Color = .{ .r = 126, .g = 34, .b = 206, .a = 255 };
/// #E879F9 fuchsia-400 — status/info text accent + the "modsync" wordmark.
const fuchsia: dvui.Color = .{ .r = 232, .g = 121, .b = 249, .a = 255 };
/// #F43F5E rose-500 — danger (Remove) button fill.
const danger: dvui.Color = .{ .r = 244, .g = 63, .b = 94, .a = 255 };

/// Semantic colors confirmed against `Options.zig` (`color_text: ?ColorOrGradient`)
/// and `Gradient.zig` (`ColorOrGradient = union(enum) { color: Color, ... }`).
const err_color: dvui.Color = .{ .r = 251, .g = 113, .b = 133, .a = 255 };
const installed_color: dvui.Color = .{ .r = 134, .g = 239, .b = 172, .a = 255 };
const idle_color: dvui.Color = .{ .r = 148, .g = 148, .b = 160, .a = 255 };
const status_color: dvui.Color = fuchsia;

/// modsync's theme: `adwaita_dark` supplies the structure — `Theme.font_*`
/// have no defaults, so a builtin is the only safe base — and we layer the
/// purple/fuchsia palette on top.
///
/// `t.corner = .round(2)` is the requested 2px rounding: widget corners
/// default to `Corner.theme(-1)` and `CornerRect.finalize` resolves that
/// against `theme.corner`, so every button/control picks up 2px corners
/// automatically. Cards override with an explicit 8px corner per-widget.
///
/// `fill_hover`/`fill_press` are left `null` on the styles: with
/// `dark == true` dvui derives them from the base fill (+10 / −20
/// lightness), so hover/press come for free on the accent.
fn modsyncTheme() dvui.Theme {
    var t = dvui.Theme.builtin.adwaita_dark;

    t.name = "modsync";
    t.dark = true;
    t.corner = .round(2);

    // Page background (the `content` style base) + base text.
    t.fill = .{ .r = 16, .g = 14, .b = 24, .a = 255 };
    t.fill_hover = .{ .r = 26, .g = 22, .b = 38, .a = 255 };
    t.fill_press = .{ .r = 10, .g = 8, .b = 18, .a = 255 };
    t.text = .{ .r = 236, .g = 233, .b = 245, .a = 255 };
    t.border = .{ .r = 48, .g = 42, .b = 66, .a = 255 };
    t.focus = accent;
    t.text_select = accent;

    // Panel/card background.
    t.window = .{
        .fill = .{ .r = 27, .g = 24, .b = 40, .a = 255 },
        .text = t.text,
        .border = t.border,
    };

    // Primary controls — solid accent fill (Refresh all, focus rings).
    t.control = .{
        .fill = accent,
        .text = dvui.Color.white,
        .border = accent_deep,
    };

    t.highlight = .{
        .fill = accent,
        .text = dvui.Color.white,
    };

    // Danger (Remove).
    t.err = .{
        .fill = danger,
        .text = dvui.Color.white,
        .border = danger,
    };

    return t;
}

/// Render one frame. Called from `main.zig`'s `frameFn` with the long-lived
/// App (owned by a global in `main.zig`, so no allocation happens here).
pub fn render(app: *App) !dvui.App.Result {
    // Re-applied every frame: `themeSet` is a plain assignment plus embedded
    // font registration and is only valid between Window.begin/end, which is
    // exactly where frameFn runs. Building the theme is a small struct copy.
    dvui.themeSet(modsyncTheme());

    // `.content` paints the scroll viewport with the dark page background
    // (`t.fill`); each section below sits in its own `.window` card.
    var scroll = dvui.scrollArea(@src(), .{}, .{ .expand = .both, .style = .content });
    defer scroll.deinit();

    dvui.label(@src(), "modsync", .{}, .{
        .font = .theme(.title),
        .color_text = .{ .color = fuchsia },
    });

    // One card per section: panel bg, 1px border, 8px corners, padding.
    // Each `dvui.box(@src(), ...)` is its own source location, so the four
    // cards are distinct widget ids (and the sections' widgets become
    // children of different parents).
    {
        var card = dvui.box(@src(), .{}, .{
            .expand = .horizontal,
            .background = true,
            .style = .window,
            .border = dvui.Rect.all(1),
            .corners = dvui.CornerRect.all(8),
            .padding = dvui.Rect.all(10),
            .margin = dvui.Rect.all(6),
        });
        defer card.deinit();
        launchersSection(app);
    }
    {
        var card = dvui.box(@src(), .{}, .{
            .expand = .horizontal,
            .background = true,
            .style = .window,
            .border = dvui.Rect.all(1),
            .corners = dvui.CornerRect.all(8),
            .padding = dvui.Rect.all(10),
            .margin = dvui.Rect.all(6),
        });
        defer card.deinit();
        minecraftDirSection(app);
    }
    {
        var card = dvui.box(@src(), .{}, .{
            .expand = .horizontal,
            .background = true,
            .style = .window,
            .border = dvui.Rect.all(1),
            .corners = dvui.CornerRect.all(8),
            .padding = dvui.Rect.all(10),
            .margin = dvui.Rect.all(6),
        });
        defer card.deinit();
        trackedModsSection(app);
    }
    {
        var card = dvui.box(@src(), .{}, .{
            .expand = .horizontal,
            .background = true,
            .style = .window,
            .border = dvui.Rect.all(1),
            .corners = dvui.CornerRect.all(8),
            .padding = dvui.Rect.all(10),
            .margin = dvui.Rect.all(6),
        });
        defer card.deinit();
        addRepoSection(app);
    }

    return .ok;
}

/// Header row: a title on the left, a spacer, then an action button pushed
/// to the right edge. `src` is the caller's `@src()` — dvui derives widget
/// ids from it, so every call site must be a distinct source location (a
/// helper's own `@src()` would collide when called more than once per frame).
///
/// `primary` picks the button hierarchy: the main CTA is a solid accent
/// button, everything else is a ghost/outline button (accent text, 1px
/// border, no fill).
fn sectionHead(
    src: std.builtin.SourceLocation,
    comptime title: []const u8,
    button_label: []const u8,
    grayed: bool,
    primary: bool,
) bool {
    var head = dvui.box(src, .{ .dir = .horizontal }, .{ .expand = .horizontal });
    defer head.deinit();

    dvui.label(@src(), title, .{}, .{ .font = .theme(.heading), .gravity_y = 0.5 });

    var spacer = dvui.box(@src(), .{}, .{ .expand = .horizontal });
    defer spacer.deinit();

    if (primary) {
        // Solid accent CTA (Refresh all); the border is the deep-purple
        // `control.border` so the button reads crisply on the card.
        return dvui.button(@src(), button_label, .{ .grayed = grayed }, .{
            .border = dvui.Rect.all(1),
        });
    }
    // Secondary ghost/outline button.
    return dvui.button(@src(), button_label, .{ .grayed = grayed }, .{
        .background = false,
        .border = dvui.Rect.all(1),
        .color_text = .{ .color = accent },
    });
}

/// 1. Detected launcher profiles + Rescan. `app.launchers` is only ever
/// written on this (GUI) thread, so no locking is needed here.
fn launchersSection(app: *App) void {
    if (sectionHead(@src(), "Launchers", "Rescan", false, false)) {
        app.rescanLaunchers() catch {};
    }

    if (app.launchers) |*d| {
        if (d.profiles.len == 0) {
            dvui.labelNoFmt(@src(), "No launcher profiles detected", .{}, .{
                .color_text = .{ .color = idle_color },
            });
        }
        // Same @src() every iteration, so each row needs a unique id_extra.
        for (d.profiles, 0..) |p, i| {
            var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .id_extra = i });
            defer row.deinit();

            dvui.label(@src(), "{s}: {s}", .{ @tagName(p.kind), p.name }, .{ .gravity_y = 0.5 });

            var spacer = dvui.box(@src(), .{}, .{ .expand = .horizontal });
            defer spacer.deinit();

            if (dvui.button(@src(), "Use", .{}, .{
                .background = false,
                .border = dvui.Rect.all(1),
                .color_text = .{ .color = accent },
            })) {
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
    dvui.label(@src(), "Minecraft folder", .{}, .{ .font = .theme(.heading) });

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

    if (dvui.button(@src(), "Save", .{}, .{
        .background = false,
        .border = dvui.Rect.all(1),
        .color_text = .{ .color = accent },
    })) {
        _ = app.setMinecraftDir(te.textGet()) catch false;
    }
}

/// 3. Tracked mods: refresh/restore actions + one row per cfg.repos entry.
fn trackedModsSection(app: *App) void {
    const refreshing = app.refreshing.load(.acquire);
    if (sectionHead(@src(), "Tracked mods", if (refreshing) "Refreshing…" else "Refresh all", refreshing, true)) {
        // The button is grayed while a worker runs, and startRefresh also
        // guards double-spawn atomically, so a stray click is a no-op.
        app.startRefresh();
    }
    if (dvui.button(@src(), "Restore defaults", .{}, .{
        .background = false,
        .border = dvui.Rect.all(1),
        .color_text = .{ .color = accent },
    })) {
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
            dvui.labelNoFmt(@src(), "No tracked repos — add one below.", .{}, .{
                .color_text = .{ .color = idle_color },
            });
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

            if (dvui.button(@src(), "Remove", .{}, .{ .style = .err })) {
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
    dvui.label(@src(), "Add repo", .{}, .{ .font = .theme(.heading) });

    var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
    defer row.deinit();

    var te = dvui.textEntry(@src(), .{
        .text = .{ .array_list = .{ .backing = &app.ui.add_buf, .allocator = app.allocator } },
        .placeholder = "owner/name",
    }, .{ .expand = .horizontal });
    defer te.deinit();

    if (dvui.button(@src(), "Add", .{}, .{
        .background = false,
        .border = dvui.Rect.all(1),
        .color_text = .{ .color = accent },
    })) {
        const spec = te.textGet();
        if (spec.len > 0 and (app.addRepo(spec) catch false)) {
            te.textSet("", false);
        }
    }
}
