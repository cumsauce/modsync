const std = @import("std");
const Allocator = std.mem.Allocator;
const builtin = @import("builtin");

const c = @import("webview_api");

const config_mod = @import("config.zig");
const net = @import("net.zig");
const install = @import("install.zig");
const launcher = @import("launcher.zig");
const os = @import("os.zig");

const Config = config_mod.Config;
const Repo = config_mod.Repo;

/// CGRect/NSRect layout as four doubles (origin.x, origin.y, size.w, size.h).
/// Used to pass a frame to `-[NSView setFrame:]` through `objc_msgSend`.
const NSRect = extern struct { x: f64, y: f64, w: f64, h: f64 };

/// `mouseDown:` implementation for the transparent titlebar drag strip.
/// Hands the mouse-down to AppKit's window-drag routine.
fn dragMouseDown(self: ?*anyopaque, _: ?*anyopaque, event: ?*anyopaque) callconv(.c) void {
    const msgObj2 = @extern(
        *const fn (?*anyopaque, ?*anyopaque) callconv(.c) ?*anyopaque,
        .{ .name = "objc_msgSend" },
    );
    const msgObjVoid = @extern(
        *const fn (?*anyopaque, ?*anyopaque, ?*anyopaque) callconv(.c) void,
        .{ .name = "objc_msgSend" },
    );
    const s = @extern(
        *const fn ([*:0]const u8) callconv(.c) ?*anyopaque,
        .{ .name = "sel_registerName" },
    );
    const win = msgObj2(self, s("window"));
    if (win) |w| msgObjVoid(w, s("performWindowDragWithEvent:"), event);
}

// ============================================================================
// Pure launchers-JSON builder (unit-testable offline)
// ============================================================================

/// Serializable shape for one discovered launcher profile.
const ProfileJson = struct {
    kind: []const u8, // "prism" | "modrinth"
    name: []const u8,
    gameDir: []const u8,
    root: []const u8,
};

/// Serializable shape of the whole listLaunchers() response.
const LaunchersJson = struct {
    profiles: []ProfileJson,
    errors: [][]const u8,
};

/// Build the listLaunchers() response JSON from a Discovery. Caller owns.
pub fn buildLaunchersJson(allocator: Allocator, d: *const launcher.Discovery) ![]u8 {
    const out = try allocator.alloc(ProfileJson, d.profiles.len);
    defer allocator.free(out);
    for (d.profiles, out) |p, *o| {
        o.* = .{
            .kind = @tagName(p.kind),
            .name = p.name,
            .gameDir = p.gameDir,
            .root = p.root,
        };
    }
    return try std.json.Stringify.valueAlloc(allocator, LaunchersJson{
        .profiles = out,
        .errors = d.errors,
    }, .{});
}

// ============================================================================
// Pure state-JSON builder (unit-testable offline)
// ============================================================================

/// Progress stage of one repo's update. Serialized to the UI as a lowercase
/// string; `idle` means "not touched by an update yet", `success` means the
/// repo settled (up to date or freshly installed), `error` means the string in
/// `RepoStatus.error` explains what failed.
pub const RepoStage = enum {
    idle,
    checking,
    downloading,
    installing,
    success,
    failed,

    pub fn toJson(self: RepoStage) []const u8 {
        return switch (self) {
            .idle => "idle",
            .checking => "checking",
            .downloading => "downloading",
            .installing => "installing",
            .success => "success",
            .failed => "error",
        };
    }
};

/// One row of per-repo status for the UI, matched to a Config repo by
/// owner AND name (never by index).
///
/// Entries stored on `App.repo_states` OWN every non-null string
/// (`freeStatus`); entries passed to `buildStateJson` by tests are borrowed
/// views. `buildStateJson` only serializes, so it never frees either kind.
pub const RepoStatus = struct {
    owner: []const u8,
    name: []const u8,
    status: []const u8,
    /// Latest release tag seen during the fetch that produced `status`
    /// (null when the fetch failed or no refresh has run yet). Lets the UI
    /// derive outdated = installedVersion != latestVersion.
    latest: ?[]const u8 = null,
    stage: RepoStage = .idle,
    /// Detailed failure copy for the row, or null.
    err: ?[]const u8 = null,
    /// Release tag that could be installed while the repo is NOT installed
    /// (drives "Available release vX"), else null.
    available_version: ?[]const u8 = null,
    /// Cached `data:image/png;base64,...` icon read from the installed jar,
    /// or null when the repo is not installed / its jar has no PNG icon.
    icon: ?[]const u8 = null,
    /// True once `icon` has been resolved against the installed jar, so a jar
    /// without an icon is not re-read on every state push. Never serialized.
    icon_loaded: bool = false,
};

/// Emit the JSON blob the UI renders:
/// `{"minecraftDir":"...","updating":false,"repos":[{"owner":...,"name":...,
/// "installedVersion":"v0.1.3"|null,"installedJar":...|null,"status":"...",
/// "latestVersion":"v0.1.4"|null,"stage":"idle","error":null,
/// "availableVersion":null,"icon":null}, ...]}`.
/// Each entry of `statuses` is paired with the repo whose `owner` AND `name`
/// match it (linear scan — the config can mutate mid-refresh, so index
/// pairing would drift); repos with no matching status get an empty status.
/// One row per `cfg.repos` entry, in `cfg.repos` order. Everything is
/// serialized immediately, so nothing is retained past the call.
pub fn buildStateJson(allocator: Allocator, cfg: *const Config, statuses: []const RepoStatus, updating: bool) ![]u8 {
    var out = try std.ArrayList(u8).initCapacity(allocator, 256);
    errdefer out.deinit(allocator);

    try out.appendSlice(allocator, "{\"minecraftDir\":");
    try appendJsonString(allocator, &out, cfg.minecraftDir);
    try out.appendSlice(allocator, ",\"updating\":");
    try out.appendSlice(allocator, if (updating) "true" else "false");
    try out.appendSlice(allocator, ",\"repos\":[");

    for (cfg.repos, 0..) |repo, i| {
        if (i > 0) try out.appendSlice(allocator, ",");
        try out.appendSlice(allocator, "{\"owner\":");
        try appendJsonString(allocator, &out, repo.owner);
        try out.appendSlice(allocator, ",\"name\":");
        try appendJsonString(allocator, &out, repo.name);
        try out.appendSlice(allocator, ",\"installedVersion\":");
        if (repo.installedVersion) |v| {
            try appendJsonString(allocator, &out, v);
        } else {
            try out.appendSlice(allocator, "null");
        }
        try out.appendSlice(allocator, ",\"installedJar\":");
        if (repo.installedJar) |v| {
            try appendJsonString(allocator, &out, v);
        } else {
            try out.appendSlice(allocator, "null");
        }
        try out.appendSlice(allocator, ",\"status\":");
        const match: ?*const RepoStatus = blk: {
            for (statuses) |*s| {
                if (std.mem.eql(u8, s.owner, repo.owner) and std.mem.eql(u8, s.name, repo.name)) {
                    break :blk s;
                }
            }
            break :blk null;
        };
        const status: []const u8 = if (match) |m| m.status else "";
        try appendJsonString(allocator, &out, status);
        try out.appendSlice(allocator, ",\"latestVersion\":");
        if (match) |m| {
            if (m.latest) |lv| {
                try appendJsonString(allocator, &out, lv);
            } else {
                try out.appendSlice(allocator, "null");
            }
        } else {
            try out.appendSlice(allocator, "null");
        }
        try out.appendSlice(allocator, ",\"stage\":");
        try appendJsonString(allocator, &out, if (match) |m| m.stage.toJson() else RepoStage.idle.toJson());
        try out.appendSlice(allocator, ",\"error\":");
        if (match) |m| {
            if (m.err) |e| {
                try appendJsonString(allocator, &out, e);
            } else {
                try out.appendSlice(allocator, "null");
            }
        } else {
            try out.appendSlice(allocator, "null");
        }
        try out.appendSlice(allocator, ",\"availableVersion\":");
        if (match) |m| {
            if (m.available_version) |av| {
                try appendJsonString(allocator, &out, av);
            } else {
                try out.appendSlice(allocator, "null");
            }
        } else {
            try out.appendSlice(allocator, "null");
        }
        try out.appendSlice(allocator, ",\"icon\":");
        if (match) |m| {
            if (m.icon) |icon| {
                try appendJsonString(allocator, &out, icon);
            } else {
                try out.appendSlice(allocator, "null");
            }
        } else {
            try out.appendSlice(allocator, "null");
        }
        try out.appendSlice(allocator, "}");
    }

    try out.appendSlice(allocator, "]}");
    return try out.toOwnedSlice(allocator);
}

/// Append `s` as a quoted, escaped JSON string (via std.json's stringifier).
fn appendJsonString(allocator: Allocator, out: *std.ArrayList(u8), s: []const u8) !void {
    const encoded = try std.json.Stringify.valueAlloc(allocator, s, .{});
    defer allocator.free(encoded);
    try out.appendSlice(allocator, encoded);
}

// ============================================================================
// Mod-jar icons (the same PNG Minecraft shows in its mod list)
// ============================================================================

/// Largest icon we are willing to inline, in decoded PNG bytes.
const max_jar_icon_bytes: u64 = 256 * 1024;
const png_magic = [4]u8{ 0x89, 'P', 'N', 'G' };
const icon_data_url_prefix = "data:image/png;base64,";

/// Rank an archive entry as a mod icon. Lower wins:
/// 0 `assets/*/icon.png`, 1 `assets/*/logo.png`, 2 unused,
/// 3 root `icon.png`, 4 root `logo.png`, 5 root `pack.png`.
/// Returns null for everything else.
fn jarIconRank(name: []const u8) ?u8 {
    if (std.mem.eql(u8, name, "icon.png")) return 3;
    if (std.mem.eql(u8, name, "logo.png")) return 4;
    if (std.mem.eql(u8, name, "pack.png")) return 5;

    const prefix = "assets/";
    if (!std.mem.startsWith(u8, name, prefix)) return null;

    const candidates = [_]struct { suffix: []const u8, rank: u8 }{
        .{ .suffix = "/icon.png", .rank = 0 },
        .{ .suffix = "/logo.png", .rank = 1 },
    };
    for (candidates) |cand| {
        if (!std.mem.endsWith(u8, name, cand.suffix)) continue;
        if (name.len < prefix.len + cand.suffix.len) return null;
        const mid = name[prefix.len .. name.len - cand.suffix.len];
        // Exactly one namespace segment: assets/<name>/<file>.
        if (mid.len == 0 or std.mem.indexOfScalar(u8, mid, '/') != null) return null;
        return cand.rank;
    }
    return null;
}

/// Extract the best mod icon from a jar and return an allocator-owned
/// `data:image/png;base64,...` URL, or null on ANY failure. Never crashes and
/// never returns a non-PNG payload.
fn loadJarIcon(allocator: Allocator, jar_path: []const u8) ?[]u8 {
    const io = std.Io.Threaded.global_single_threaded.io();
    return loadJarIconIo(allocator, io, jar_path);
}

fn loadJarIconIo(allocator: Allocator, io: std.Io, jar_path: []const u8) ?[]u8 {
    var file = std.Io.Dir.cwd().openFile(io, jar_path, .{}) catch return null;
    defer file.close(io);

    var read_buf: [16 * 1024]u8 = undefined;
    var reader = file.reader(io, &read_buf);
    var iter = std.zip.Iterator.init(&reader) catch return null;

    var best: ?std.zip.Iterator.Entry = null;
    var best_rank: u8 = std.math.maxInt(u8);
    var name_buf: [512]u8 = undefined;

    while (iter.next() catch return null) |entry| {
        if (entry.uncompressed_size > max_jar_icon_bytes) continue;
        const name = entry.getFilename(&reader, &name_buf, .{}) catch continue;
        if (name.len == 0 or name[name.len - 1] == '/') continue; // directory
        const rank = jarIconRank(name) orelse continue;
        if (rank < best_rank) {
            best_rank = rank;
            best = entry;
        }
        if (best_rank == 0) break; // nothing outranks assets/*/icon.png
    }

    const entry = best orelse return null;

    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    entry.extractTo(&reader, &aw.writer) catch return null;
    const bytes = aw.toOwnedSlice() catch return null;
    defer allocator.free(bytes);

    if (bytes.len > max_jar_icon_bytes) return null;
    if (bytes.len < png_magic.len) return null;
    if (!std.mem.eql(u8, bytes[0..png_magic.len], &png_magic)) return null;

    const encoded_len = std.base64.standard.Encoder.calcSize(bytes.len);
    const out = allocator.alloc(u8, icon_data_url_prefix.len + encoded_len) catch return null;
    @memcpy(out[0..icon_data_url_prefix.len], icon_data_url_prefix);
    _ = std.base64.standard.Encoder.encode(out[icon_data_url_prefix.len..], bytes);
    return out;
}

// ============================================================================
// App: JS↔Zig bridge + background refresh worker
// ============================================================================

/// The embedded UI document; `@embedFile("ui.html")` resolves to `src/ui.html`
/// (relative to the module root, `src/main.zig`).
const ui_html = @embedFile("ui.html");

/// Blocking mutex over an atomic flag (std.Thread.Mutex no longer exists in
/// Zig 0.17; std.Io.Mutex needs an Io handle, which the C bind callbacks on
/// the GUI thread do not have). Critical sections here are short, so a
/// yield-loop is fine.
const SpinMutex = struct {
    locked: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    fn lock(self: *SpinMutex) void {
        while (self.locked.cmpxchgStrong(false, true, .acquire, .monotonic) != null) {
            std.Thread.yield() catch {};
        }
    }

    fn unlock(self: *SpinMutex) void {
        self.locked.store(false, .release);
    }
};

/// Exact UI copy for fixed failure classes, per the Arctic Cyan contract.
const app_error_write = "Can't write to this install. Check folder permissions.";
const app_error_download = "Couldn't download. Check your connection and retry.";
const app_error_offline = "Couldn't reach GitHub. Check your connection and retry.";
const app_error_not_found = "Repository not found or unavailable. Check owner/name.";
const app_error_no_jar = "No compatible .jar release found for this install.";

pub const App = struct {
    allocator: Allocator,
    /// Webview handle; created in `run` and used from bound callbacks and the
    /// refresh worker's dispatch calls.
    w: c.webview_t = null,
    /// Always allocator-owned (see `cloneConfig`) — never aliases the global
    /// `seeded_repos` backing `defaultRepos()`.
    cfg: Config,
    /// Guards `cfg` across the GUI thread (bind callbacks) and the refresh
    /// worker thread.
    mutex: SpinMutex = .{},
    /// True while a refresh worker is running (guards double-spawn; also read
    /// by `run`'s drain loop after `webview_run` returns). Serialized as the
    /// top-level `updating` flag, and checked by the install-mutating
    /// callbacks.
    refreshing: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    /// Per-repo stage/error/available-version state, keyed by owner+name.
    /// Entries own their strings (see `freeStatus`); pruned when a repo is
    /// removed from the config.
    repo_states: []RepoStatus = &.{},
    /// Duplicated owner/name of the repo the running worker is currently
    /// checking/writing, so `removeRepo` can reject a mid-write removal.
    /// Always set/cleared under `mutex`.
    write_owner: ?[]const u8 = null,
    write_name: ?[]const u8 = null,
    /// Set under the mutex once the webview handle is destroyed; worker paths
    /// check it before calling `webview_dispatch` on `w`.
    stopped: bool = false,

    /// Store a deep, allocator-owned clone of `cfg`. The caller's copy (which
    /// may slice the global seed from `defaultRepos()`) is left untouched.
    pub fn init(allocator: Allocator, cfg: Config) !App {
        const owned = try cloneConfig(allocator, cfg);
        var app = App{ .allocator = allocator, .cfg = owned };
        // Resolve jar icons before the first getConfig so installed rows paint
        // with their real icon immediately instead of flashing a letter.
        app.ensureIconsLocked();
        return app;
    }

    /// Build the startup App from an optional loaded config. When `loaded` is
    /// null (first run / no config), the seed repo list from `defaultRepos` is
    /// used and then released — but only AFTER `App.init` has deep-cloned it,
    /// so the App owns a full copy and the seed originals do not leak.
    pub fn initFromLoaded(allocator: Allocator, loaded: ?Config) !App {
        if (loaded) |cfg| return init(allocator, cfg);

        const seeds = try config_mod.defaultRepos(allocator);
        errdefer config_mod.freeRepos(allocator, seeds);
        const cfg = Config{
            .minecraftDir = config_mod.defaultMinecraftDir(),
            .githubToken = null,
            .repos = seeds,
        };
        const app = try init(allocator, cfg);
        // `init` deep-cloned `seeds`; the App now owns its own copy.
        config_mod.freeRepos(allocator, seeds);
        return app;
    }

    pub fn deinit(self: *App) void {
        // Safe because `run` drains the refresh worker and destroys the
        // webview (setting `stopped`) before returning; `main` calls `deinit`
        // only after `run` completes, so no worker can touch `cfg`/`w` here.
        for (self.repo_states) |s| freeStatus(self.allocator, s);
        if (self.repo_states.len != 0) self.allocator.free(self.repo_states);
        self.repo_states = &.{};
        self.clearWritingLocked();
        config_mod.freeConfig(self.allocator, self.cfg);
        self.cfg = undefined;
    }

    // =========================================================================
    // macOS integrated chrome (Discord-style): content fills the window and
    // the UI's own top strip acts as the header. Implemented with ObjC runtime
    // calls on the NSWindow the webview shim owns; no-ops on other platforms.
    // =========================================================================

    /// Blend the webview into the title bar: the window content extends
    /// under the title strip (fullSizeContentView) while the strip itself is
    /// transparent and textless, so the UI's own 34px `.topbar` acts as the
    /// header and the traffic lights overlay its left spacer. Background
    /// drag still moves the window.
    ///
    /// ABI note: the style mask must be handed to `objc_msgSend` as a full
    /// 64-bit NSUInteger through a non-variadic `callconv(.c)` pointer — a
    /// narrower/malformed argument made AppKit read the full-screen bit and
    /// throw `NSGenericException`, which is what crashed earlier builds.
    fn integrateTitlebar(wv: ?*anyopaque) void {
        if (builtin.os.tag != .macos) return; // cross-platform guard
        const id_t = ?*anyopaque;
        const msgObj = @extern(
            *const fn (id_t, id_t, id_t) callconv(.c) id_t,
            .{ .name = "objc_msgSend" },
        );
        const msgObj2 = @extern(
            *const fn (id_t, id_t) callconv(.c) id_t,
            .{ .name = "objc_msgSend" },
        );
        const msgBool = @extern(
            *const fn (id_t, id_t, i32) callconv(.c) id_t,
            .{ .name = "objc_msgSend" },
        );
        const msgF4 = @extern(
            *const fn (id_t, id_t, f64, f64, f64, f64) callconv(.c) id_t,
            .{ .name = "objc_msgSend" },
        );
        // NSUInteger-typed argument: 64-bit, non-variadic (see ABI note).
        const msgUL = @extern(
            *const fn (id_t, id_t, u64) callconv(.c) void,
            .{ .name = "objc_msgSend" },
        );
        const getClass = @extern(
            *const fn ([*:0]const u8) callconv(.c) id_t,
            .{ .name = "objc_getClass" },
        );
        const s = @extern(
            *const fn ([*:0]const u8) callconv(.c) id_t,
            .{ .name = "sel_registerName" },
        );
        const msgObjVoid = @extern(
            *const fn (id_t, id_t, id_t) callconv(.c) void,
            .{ .name = "objc_msgSend" },
        );
        const msgRect = @extern(
            *const fn (id_t, id_t, NSRect) callconv(.c) void,
            .{ .name = "objc_msgSend" },
        );
        const allocClassPair = @extern(
            *const fn (id_t, [*:0]const u8, usize) callconv(.c) id_t,
            .{ .name = "objc_allocateClassPair" },
        );
        const addMethod = @extern(
            *const fn (id_t, id_t, *const anyopaque, [*:0]const u8) callconv(.c) i8,
            .{ .name = "class_addMethod" },
        );
        const registerClassPair = @extern(
            *const fn (id_t) callconv(.c) void,
            .{ .name = "objc_registerClassPair" },
        );

        const nsw = c.webview_get_native_handle(
            @ptrCast(wv),
            c.WEBVIEW_NATIVE_HANDLE_KIND_UI_WINDOW,
        ) orelse return;

        // Titled | closable | miniaturizable | resizable | fullSizeContentView
        // — content runs under the title strip and its traffic lights.
        msgUL(nsw, s("setStyleMask:"), 15 | 32768);

        // Background matching --bg (#0B0A10) so the strip is invisible.
        const color_cls = getClass("NSColor") orelse return;
        const dark = msgF4(
            color_cls,
            s("colorWithSRGBRed:green:blue:alpha:"),
            0.04314,
            0.03922,
            0.06275,
            1.0,
        );
        _ = msgObj(nsw, s("setBackgroundColor:"), dark);
        _ = msgBool(nsw, s("setTitlebarAppearsTransparent:"), 1);
        _ = msgBool(nsw, s("setTitleVisibility:"), 1);
        _ = msgBool(nsw, s("setMovableByWindowBackground:"), 1);

        // `setMovableByWindowBackground:` alone can't move the window here:
        // WKWebView consumes the mouse events across the whole content view.
        // Add a transparent native strip over the top 34px whose `mouseDown:`
        // starts a window drag, so the UI's own top bar drags like a titlebar.
        const content = msgObj2(nsw, s("contentView"));
        const nsview_cls = getClass("NSView") orelse return;
        const drag_cls = allocClassPair(nsview_cls, "ModsyncDragView", 0);
        if (drag_cls) |cls| {
            _ = addMethod(cls, s("mouseDown:"), @ptrCast(&dragMouseDown), "v@:@");
            registerClassPair(cls);
        }
        const strip_cls = drag_cls orelse nsview_cls;
        const strip = msgObj2(msgObj2(strip_cls, s("alloc")), s("init"));
        if (strip) |view| {
            msgRect(view, s("setFrame:"), .{ .x = 0, .y = 606, .w = 520, .h = 34 });
            // Width-sizable (2) + flexible bottom margin (8) pins it to the top
            // edge when the window is resized.
            _ = msgUL(view, s("setAutoresizingMask:"), 2 | 8);
            if (content) |cv| msgObjVoid(cv, s("addSubview:"), view);
        }
    }

    /// Create the webview, load the embedded UI document, bind the JS
    /// callables (passing `*App` as the C callback arg), and run the event
    /// loop until the window closes.
    pub fn run(self: *App) !void {
        const w = c.webview_create(0, null);
        if (w == null) return error.WebviewCreateFailed;
        self.w = w;

        _ = c.webview_set_title(w, "modsync");
        _ = c.webview_set_size(w, 520, 640, c.WEBVIEW_HINT_NONE);
        _ = c.webview_set_html(w, ui_html);
        if (builtin.os.tag == .macos) integrateTitlebar(w);
        const app_arg: ?*anyopaque = self;
        _ = c.webview_bind(w, "getConfig", cbGetConfig, app_arg);
        _ = c.webview_bind(w, "setMinecraftDir", cbSetMinecraftDir, app_arg);
        _ = c.webview_bind(w, "addRepo", cbAddRepo, app_arg);
        _ = c.webview_bind(w, "removeRepo", cbRemoveRepo, app_arg);
        _ = c.webview_bind(w, "startRefresh", cbStartRefresh, app_arg);
        _ = c.webview_bind(w, "listLaunchers", cbListLaunchers, app_arg);
        _ = c.webview_bind(w, "selectProfile", cbSelectProfile, app_arg);
        _ = c.webview_bind(w, "restoreDefaults", cbRestoreDefaults, app_arg);
        _ = c.webview_bind(w, "updateRepo", cbUpdateRepo, app_arg);
        _ = c.webview_bind(w, "installRepo", cbInstallRepo, app_arg);
        _ = c.webview_bind(w, "retryRepo", cbRetryRepo, app_arg);
        _ = c.webview_bind(w, "openUrl", cbOpenUrl, app_arg);
        _ = c.webview_bind(w, "copyToClipboard", cbCopyToClipboard, app_arg);
        _ = c.webview_bind(w, "validateFolder", cbValidateFolder, app_arg);

        _ = c.webview_run(w);

        // The window is closed, but a detached refresh worker may still be
        // running (downloads take seconds). Drain it before destroying the
        // webview: the worker calls `webview_dispatch(w, ...)` and touches
        // `cfg`, both of which die with the webview / `deinit`. The worker
        // clears `refreshing` as its very last action (its topmost `defer`),
        // so once the flag reads false nothing else will run. `std.Thread`
        // has no `sleep` in 0.17 and an Io handle isn't available here, so
        // the wait is a yield-loop.
        while (true) {
            self.mutex.lock();
            const busy = self.refreshing.load(.acquire);
            self.mutex.unlock();
            if (!busy) break;
            std.Thread.yield() catch {};
        }
        {
            self.mutex.lock();
            defer self.mutex.unlock();
            self.stopped = true;
        }
        _ = c.webview_destroy(w);
    }

    // ------------------------------------------------------------------
    // Config mutation (callers hold the mutex)
    // ------------------------------------------------------------------

    /// Parse `"owner/name"`, append a fresh Repo (null installed fields),
    /// free the OLD owned repos slice, and persist. Never touches the global
    /// seed — `cfg.repos` is always the allocator-owned clone from `init`.
    fn addRepo(self: *App, owner_and_name: []const u8) !bool {
        const owner, const name = (parseOwnerName(owner_and_name) orelse return false);

        const old = self.cfg.repos;
        const new_repos = try self.allocator.alloc(Repo, old.len + 1);

        var built: usize = 0;
        errdefer {
            for (new_repos[0..built]) |r| freeRepoOwned(self.allocator, r);
            self.allocator.free(new_repos);
        }
        for (old) |src| {
            new_repos[built] = try dupeRepo(self.allocator, src);
            built += 1;
        }
        const new_owner = try self.allocator.dupe(u8, owner);
        errdefer self.allocator.free(new_owner);
        const new_name = try self.allocator.dupe(u8, name);
        new_repos[old.len] = .{ .owner = new_owner, .name = new_name };
        built += 1;

        freeRepoSlice(self.allocator, old);
        self.cfg.repos = new_repos;

        config_mod.save(&self.cfg) catch return false;
        return true;
    }

    /// Build a NEW repos slice excluding the `"owner/name"` match, free the
    /// removed entry's strings plus the old owned slice, and persist.
    fn removeRepo(self: *App, owner_and_name: []const u8) !bool {
        const owner, const name = (parseOwnerName(owner_and_name) orelse return false);

        const old = self.cfg.repos;
        var match: ?usize = null;
        for (old, 0..) |r, i| {
            if (std.mem.eql(u8, r.owner, owner) and std.mem.eql(u8, r.name, name)) {
                match = i;
                break;
            }
        }
        const i = match orelse return false;

        const new_repos = try self.allocator.alloc(Repo, old.len - 1);

        var built: usize = 0;
        errdefer {
            for (new_repos[0..built]) |r| freeRepoOwned(self.allocator, r);
            self.allocator.free(new_repos);
        }
        for (old[0..i]) |src| {
            new_repos[built] = try dupeRepo(self.allocator, src);
            built += 1;
        }
        for (old[i + 1 ..]) |src| {
            new_repos[built] = try dupeRepo(self.allocator, src);
            built += 1;
        }

        freeRepoOwned(self.allocator, old[i]);
        self.allocator.free(old);
        self.cfg.repos = new_repos;

        config_mod.save(&self.cfg) catch return false;
        return true;
    }

    // ------------------------------------------------------------------
    // Background refresh
    // ------------------------------------------------------------------

    // ------------------------------------------------------------------
    // Per-repo progress state
    // ------------------------------------------------------------------

    /// Find the state row for `owner`/`name`; caller holds `mutex`.
    fn stateSlotLocked(self: *App, owner: []const u8, name: []const u8) ?*RepoStatus {
        for (self.repo_states) |*s| {
            if (std.mem.eql(u8, s.owner, owner) and std.mem.eql(u8, s.name, name)) return s;
        }
        return null;
    }

    /// Append a fresh row for `owner`/`name` (or return the existing one).
    /// Caller holds `mutex`. The new row owns freshly-duped strings.
    fn ensureStateLocked(self: *App, owner: []const u8, name: []const u8) !*RepoStatus {
        if (self.stateSlotLocked(owner, name)) |s| return s;

        const next = try self.allocator.alloc(RepoStatus, self.repo_states.len + 1);
        errdefer self.allocator.free(next);
        @memcpy(next[0..self.repo_states.len], self.repo_states);

        const owner_copy = try self.allocator.dupe(u8, owner);
        errdefer self.allocator.free(owner_copy);
        const name_copy = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(name_copy);
        const status_copy = try self.allocator.dupe(u8, "");
        next[self.repo_states.len] = .{
            .owner = owner_copy,
            .name = name_copy,
            .status = status_copy,
        };

        if (self.repo_states.len != 0) self.allocator.free(self.repo_states);
        self.repo_states = next;
        return &next[next.len - 1];
    }

    /// Replace an owned optional string, freeing the previous value.
    /// Caller holds `mutex`.
    fn setOwnedLocked(self: *App, slot: *?[]const u8, value: ?[]const u8) void {
        const copy: ?[]const u8 = if (value) |v| self.allocator.dupe(u8, v) catch return else null;
        if (slot.*) |old| self.allocator.free(old);
        slot.* = copy;
    }

    /// Replace a row's owned status text. Caller holds `mutex`.
    fn setStatusTextLocked(self: *App, s: *RepoStatus, text: []const u8) void {
        const copy = self.allocator.dupe(u8, text) catch return;
        self.allocator.free(s.status);
        s.status = copy;
    }

    /// Cache the icon extracted from the repo's installed jar (duplicated),
    /// or clear it when the jar has none. Caller holds `mutex`.
    fn setIcon(self: *App, owner: []const u8, name: []const u8, icon: ?[]const u8) void {
        const s = self.ensureStateLocked(owner, name) catch return;
        self.setOwnedLocked(&s.icon, icon);
        s.icon_loaded = true;
    }

    /// Make every tracked repo's cached icon match its installed jar. Repos
    /// without a jar have their icon cleared; a jar without an icon caches
    /// null so it is not re-read on every state push. Caller holds `mutex`
    /// (or calls before the App is shared). Never fails.
    fn ensureIconsLocked(self: *App) void {
        for (self.cfg.repos) |repo| {
            const s = self.ensureStateLocked(repo.owner, repo.name) catch continue;
            const jar = repo.installedJar orelse {
                self.setOwnedLocked(&s.icon, null);
                s.icon_loaded = false;
                continue;
            };
            if (s.icon_loaded) continue;

            const mods = install.modsDir(self.allocator, self.cfg.minecraftDir) catch continue;
            defer self.allocator.free(mods);
            const path = std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ mods, jar }) catch continue;
            defer self.allocator.free(path);

            const icon = loadJarIcon(self.allocator, path);
            self.setIconOwned(&s.icon, icon);
            s.icon_loaded = true;
        }
    }

    /// `setOwnedLocked` variant that also releases the caller's copy.
    fn setIconOwned(self: *App, slot: *?[]const u8, icon: ?[]const u8) void {
        self.setOwnedLocked(slot, icon);
        if (icon) |bytes| self.allocator.free(bytes);
    }

    /// First stage of an update: mark the row "checking" and drop stale error
    /// copy from a previous run.
    fn beginRepo(self: *App, owner: []const u8, name: []const u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        const s = self.ensureStateLocked(owner, name) catch return;
        s.stage = .checking;
        self.setOwnedLocked(&s.err, null);
    }

    fn setStage(self: *App, owner: []const u8, name: []const u8, stage: RepoStage) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        const s = self.ensureStateLocked(owner, name) catch return;
        s.stage = stage;
    }

    /// Record the release tag the worker just saw. `available` is true while
    /// the repo is not installed, so the UI can show "Available release vX".
    fn setFetched(self: *App, owner: []const u8, name: []const u8, tag: []const u8, available: bool) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        const s = self.ensureStateLocked(owner, name) catch return;
        self.setOwnedLocked(&s.latest, tag);
        self.setOwnedLocked(&s.available_version, if (available) tag else null);
        s.stage = .success;
    }

    /// Terminal success: clear error/available copy (the mod is installed) and
    /// store the human status text.
    fn markSuccess(self: *App, owner: []const u8, name: []const u8, text: []const u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        const s = self.ensureStateLocked(owner, name) catch return;
        s.stage = .success;
        self.setStatusTextLocked(s, text);
        self.setOwnedLocked(&s.err, null);
        self.setOwnedLocked(&s.available_version, null);
    }

    /// Terminal failure: stage=error, status="error", detailed message.
    fn markError(self: *App, owner: []const u8, name: []const u8, message: []const u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        const s = self.ensureStateLocked(owner, name) catch return;
        s.stage = .failed;
        self.setStatusTextLocked(s, "error");
        self.setOwnedLocked(&s.err, message);
    }

    fn pruneStatesLocked(self: *App) void {
        if (self.repo_states.len == 0) return;

        var keep: usize = 0;
        for (self.repo_states) |s| {
            if (self.repoIsTrackedLocked(s.owner, s.name)) keep += 1;
        }
        if (keep == self.repo_states.len) return;

        if (keep == 0) {
            for (self.repo_states) |s| freeStatus(self.allocator, s);
            self.allocator.free(self.repo_states);
            self.repo_states = &.{};
            return;
        }

        const next = self.allocator.alloc(RepoStatus, keep) catch return;
        var i: usize = 0;
        for (self.repo_states) |s| {
            if (!self.repoIsTrackedLocked(s.owner, s.name)) {
                freeStatus(self.allocator, s);
                continue;
            }
            next[i] = s;
            i += 1;
        }
        self.allocator.free(self.repo_states);
        self.repo_states = next;
    }

    fn repoIsTrackedLocked(self: *App, owner: []const u8, name: []const u8) bool {
        for (self.cfg.repos) |r| {
            if (std.mem.eql(u8, r.owner, owner) and std.mem.eql(u8, r.name, name)) return true;
        }
        return false;
    }

    /// Mark `owner`/`name` as the repo the worker is touching. The remove
    /// binding rejects removing exactly this repo until it is cleared.
    fn markWriting(self: *App, owner: []const u8, name: []const u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.clearWritingLocked();
        self.write_owner = self.allocator.dupe(u8, owner) catch null;
        self.write_name = self.allocator.dupe(u8, name) catch null;
    }

    fn clearWriting(self: *App) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.clearWritingLocked();
    }

    fn clearWritingLocked(self: *App) void {
        if (self.write_owner) |v| self.allocator.free(v);
        if (self.write_name) |v| self.allocator.free(v);
        self.write_owner = null;
        self.write_name = null;
    }

    // ------------------------------------------------------------------
    // Staged update worker
    // ------------------------------------------------------------------

    /// Stage one repo: check -> (download -> install)? -> success/error.
    /// `single` is true for updateRepo/installRepo/retryRepo, which push after
    /// every stage; the all-repos batch pushes one coherent snapshot at the
    /// end instead, leaving pre-run versions/counts untouched while it runs.
    fn updateOne(self: *App, client: *std.http.Client, minecraft_dir: []const u8, token: ?[]const u8, repo: Repo, single: bool) void {
        self.markWriting(repo.owner, repo.name);
        defer self.clearWriting();
        self.beginRepo(repo.owner, repo.name);
        if (single) self.pushCurrentState();

        var rate_reset: ?i64 = null;
        const fetched = net.fetchLatestReleaseDetailed(
            self.allocator,
            client,
            repo.owner,
            repo.name,
            token,
            &rate_reset,
        ) catch |err| {
            const owned = releaseErrorMessage(self.allocator, err, rate_reset);
            defer if (owned) |m| self.allocator.free(m);
            self.markError(repo.owner, repo.name, owned orelse "Couldn't complete the update. Try again.");
            if (single) self.pushFinalState();
            return;
        };
        defer {
            self.allocator.free(fetched.tag);
            self.allocator.free(fetched.name);
            self.allocator.free(fetched.url);
        }

        // A repo with no recorded install is a missing mod: surface the tag
        // the UI can show as "Available release vX".
        self.setFetched(repo.owner, repo.name, fetched.tag, repo.installedVersion == null);

        const mods = install.modsDir(self.allocator, minecraft_dir) catch {
            self.markError(repo.owner, repo.name, app_error_write);
            if (single) self.pushFinalState();
            return;
        };
        defer self.allocator.free(mods);

        const jar_path = std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ mods, fetched.name }) catch {
            self.markError(repo.owner, repo.name, app_error_write);
            if (single) self.pushFinalState();
            return;
        };
        defer self.allocator.free(jar_path);
        const jar_exists = if (std.Io.Dir.cwd().access(client.io, jar_path, .{})) true else |_| false;

        // Same tag + same jar name + jar on disk → nothing to do.
        const version_matches = std.mem.eql(u8, repo.installedVersion orelse "", fetched.tag) and
            std.mem.eql(u8, repo.installedJar orelse "", fetched.name);
        if (version_matches and jar_exists) {
            self.markSuccess(repo.owner, repo.name, "up to date");
            if (single) self.pushFinalState();
            return;
        }

        install.ensureModsDir(minecraft_dir) catch {
            self.markError(repo.owner, repo.name, app_error_write);
            if (single) self.pushFinalState();
            return;
        };

        const tmp_path = std.fmt.allocPrint(self.allocator, "{s}/{s}.tmp", .{ mods, fetched.name }) catch {
            self.markError(repo.owner, repo.name, app_error_write);
            if (single) self.pushFinalState();
            return;
        };
        defer {
            self.allocator.free(tmp_path);
            // No-op after a successful placeJar (file was moved).
            std.Io.Dir.cwd().deleteFile(client.io, tmp_path) catch {};
        }

        self.setStage(repo.owner, repo.name, .downloading);
        if (single) self.pushCurrentState();

        net.downloadJarDetailed(self.allocator, client, fetched.url, tmp_path, token) catch {
            self.markError(repo.owner, repo.name, app_error_download);
            if (single) self.pushFinalState();
            return;
        };

        self.setStage(repo.owner, repo.name, .installing);
        if (single) self.pushCurrentState();

        // Reclaim older jars belonging to this repo before placing the new one.
        if (install.staleJarNames(self.allocator, mods, repo.name, fetched.name)) |stale| {
            defer {
                for (stale) |jar| self.allocator.free(jar);
                self.allocator.free(stale);
            }
            for (stale) |jar| {
                const p = std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ mods, jar }) catch continue;
                defer self.allocator.free(p);
                std.Io.Dir.cwd().deleteFile(client.io, p) catch {};
            }
        } else |_| {}

        install.placeJar(mods, tmp_path, fetched.name) catch {
            self.markError(repo.owner, repo.name, app_error_write);
            if (single) self.pushFinalState();
            return;
        };

        // Record the new install in the live config under the lock.
        self.mutex.lock();
        for (self.cfg.repos) |*r| {
            if (std.mem.eql(u8, r.owner, repo.owner) and std.mem.eql(u8, r.name, repo.name)) {
                if (r.installedVersion) |v| self.allocator.free(v);
                if (r.installedJar) |v| self.allocator.free(v);
                r.installedVersion = self.allocator.dupe(u8, fetched.tag) catch null;
                r.installedJar = self.allocator.dupe(u8, fetched.name) catch null;
                break;
            }
        }
        self.mutex.unlock();

        // Cache the freshly placed jar's icon for the next state snapshot.
        const new_icon = loadJarIcon(self.allocator, jar_path);
        defer if (new_icon) |bytes| self.allocator.free(bytes);
        self.mutex.lock();
        self.setIcon(repo.owner, repo.name, new_icon);
        self.mutex.unlock();

        var status_buf: [192]u8 = undefined;
        const status_text = std.fmt.bufPrint(&status_buf, "installed {s}", .{fetched.tag}) catch "installed";
        self.markSuccess(repo.owner, repo.name, status_text);
        if (single) self.pushFinalState();
    }

    /// Background thread body for both "Update all" and the scoped
    /// updateRepo/installRepo/retryRepo bindings. With `single_owner` set only
    /// that repo is processed; otherwise every tracked repo is, in order, and
    /// one coherent snapshot is published when the batch finishes (independent
    /// successes are kept even when another repo fails).
    fn updateWorker(self: *App, single_owner: ?[]const u8, single_name: ?[]const u8) void {
        const single = single_owner != null and single_name != null;

        // Drain-loop contract: the spawning binding already set `refreshing`
        // true before spawning this thread (atomically, to guard double-spawn),
        // and this topmost defer clears it as the very last statement on EVERY
        // exit path. `run`'s post-`webview_run` drain loop spins on this flag,
        // so it can never destroy the webview while this function is live.
        defer self.refreshing.store(false, .release);

        // --- snapshot under the lock ---
        self.mutex.lock();
        const minecraft_dir = self.allocator.dupe(u8, self.cfg.minecraftDir) catch {
            self.mutex.unlock();
            return;
        };
        const token = if (self.cfg.githubToken) |t| self.allocator.dupe(u8, t) catch null else null;

        var wanted: usize = 0;
        for (self.cfg.repos) |r| {
            if (single) {
                if (std.mem.eql(u8, r.owner, single_owner.?) and std.mem.eql(u8, r.name, single_name.?)) wanted += 1;
            } else {
                wanted += 1;
            }
        }
        const repos = self.allocator.alloc(Repo, wanted) catch {
            self.mutex.unlock();
            self.allocator.free(minecraft_dir);
            if (token) |t| self.allocator.free(t);
            return;
        };
        var built: usize = 0;
        for (self.cfg.repos) |r| {
            if (single and !(std.mem.eql(u8, r.owner, single_owner.?) and std.mem.eql(u8, r.name, single_name.?))) continue;
            repos[built] = dupeRepo(self.allocator, r) catch break;
            built += 1;
        }
        self.mutex.unlock();

        defer self.allocator.free(minecraft_dir);
        defer if (token) |t| self.allocator.free(t);
        defer {
            for (repos[0..built]) |r| freeRepoOwned(self.allocator, r);
            self.allocator.free(repos);
        }

        // One HTTP client for the whole run (struct literal; no init fn).
        var threaded = std.Io.Threaded.init(self.allocator, .{});
        var client: std.http.Client = .{ .allocator = self.allocator, .io = threaded.io() };
        defer client.deinit();

        for (repos[0..built]) |repo| {
            self.updateOne(&client, minecraft_dir, token, repo, single);
        }

        // Batch (and the "repo vanished before we started" edge): a single
        // settled snapshot. Per-stage pushes already happened for single runs.
        if (!single or built == 0) self.pushFinalState();

        // --- persist the updated config ---
        self.mutex.lock();
        defer self.mutex.unlock();
        config_mod.save(&self.cfg) catch {};
    }

    /// Build the current state JSON and hand it to `pushState`. `force_updating`
    /// overrides the live `refreshing` flag so a terminal snapshot can say
    /// "not updating" while the worker is in its final bookkeeping.
    fn pushCurrentStateFlag(self: *App, force_updating: ?bool) void {
        self.mutex.lock();
        const updating = force_updating orelse self.refreshing.load(.acquire);
        const json = buildStateJson(self.allocator, &self.cfg, self.repo_states, updating);
        self.mutex.unlock();
        if (json) |j| self.pushState(j) else |_| {}
    }

    fn pushCurrentState(self: *App) void {
        self.pushCurrentStateFlag(null);
    }

    fn pushFinalState(self: *App) void {
        self.pushCurrentStateFlag(false);
    }

    /// Hand `json` (an already-built state blob) to the GUI thread, which
    /// evals `renderState(...)` in the page. Takes ownership of `json`.
    fn pushState(self: *App, json: []const u8) void {
        // Never touch the webview handle after teardown: if the window has
        // been closed and the webview destroyed, just drop the payload.
        {
            self.mutex.lock();
            defer self.mutex.unlock();
            if (self.stopped) {
                self.allocator.free(json);
                return;
            }
        }
        const js = std.fmt.allocPrintSentinel(self.allocator, "window.renderState && renderState({s});", .{json}, 0) catch {
            self.allocator.free(json);
            return;
        };
        self.allocator.free(json);

        const ctx = self.allocator.create(DispatchCtx) catch {
            self.allocator.free(js);
            return;
        };
        ctx.* = .{ .js = js, .allocator = self.allocator };
        _ = c.webview_dispatch(self.w, dispatchRender, ctx);
    }
};

// ============================================================================
// webview bridge plumbing
// ============================================================================

const DispatchCtx = struct {
    js: [*:0]u8,
    allocator: Allocator,
};

/// Runs on the GUI thread (webview_dispatch guarantees it) — safe to eval.
fn dispatchRender(w: c.webview_t, arg: ?*anyopaque) callconv(.c) void {
    const ctx: *DispatchCtx = @ptrCast(@alignCast(arg.?));
    defer {
        ctx.allocator.free(std.mem.span(ctx.js));
        ctx.allocator.destroy(ctx);
    }
    _ = c.webview_eval(w, ctx.js);
}

fn appFromArg(arg: ?*anyopaque) *App {
    return @ptrCast(@alignCast(arg.?));
}

/// Reply to a bind callback with a JSON value string (NUL-terminated copy).
fn respond(app: *App, id: [*c]const u8, json: []const u8) void {
    const z = app.allocator.dupeSentinel(u8, json, 0) catch {
        _ = c.webview_return(app.w, id, 0, "null");
        return;
    };
    defer app.allocator.free(z);
    _ = c.webview_return(app.w, id, 0, z.ptr);
}

/// Pull the first string out of the bind callback's JSON args array (`["x"]`).
/// On success the caller owns the returned dupe.
fn firstStringArg(app: *App, req: [*c]const u8, out: *[]const u8) bool {
    const parsed = std.json.parseFromSlice([]const []const u8, app.allocator, std.mem.span(req), .{}) catch return false;
    defer parsed.deinit();
    if (parsed.value.len < 1) return false;
    out.* = app.allocator.dupe(u8, parsed.value[0]) catch return false;
    return true;
}

/// Pull two strings out of the bind callback's JSON args array (`["a","b"]`),
/// used by updateRepo/installRepo/retryRepo(owner, name). On success the
/// caller owns both dupes.
fn twoStringArgs(app: *App, req: [*c]const u8, first: *[]const u8, second: *[]const u8) bool {
    const parsed = std.json.parseFromSlice([]const []const u8, app.allocator, std.mem.span(req), .{}) catch return false;
    defer parsed.deinit();
    if (parsed.value.len < 2) return false;
    const a = app.allocator.dupe(u8, parsed.value[0]) catch return false;
    const b = app.allocator.dupe(u8, parsed.value[1]) catch {
        app.allocator.free(a);
        return false;
    };
    first.* = a;
    second.* = b;
    return true;
}

/// `{"ok":true}` / `{"ok":false,"error":"..."}` for the OS-helper bindings.
fn respondResult(app: *App, id: [*c]const u8, ok: bool, message: []const u8) void {
    if (ok) {
        respond(app, id, "{\"ok\":true}");
        return;
    }
    const json = std.fmt.allocPrint(app.allocator, "{{\"ok\":false,\"error\":\"{s}\"}}", .{message}) catch {
        respond(app, id, "{\"ok\":false,\"error\":\"Operation failed.\"}");
        return;
    };
    defer app.allocator.free(json);
    respond(app, id, json);
}

/// getConfig() → full state JSON (per-repo rows default to idle until an
/// update fills them).
fn cbGetConfig(id: [*c]const u8, req: [*c]const u8, arg: ?*anyopaque) callconv(.c) void {
    _ = req;
    const app = appFromArg(arg);

    app.mutex.lock();
    defer app.mutex.unlock();
    // Lazy one-time load for rows whose jar landed outside this process (or
    // before the icon cache existed); no-ops once every row is resolved.
    app.ensureIconsLocked();
    const json = buildStateJson(
        app.allocator,
        &app.cfg,
        app.repo_states,
        app.refreshing.load(.acquire),
    ) catch {
        respond(app, id, "null");
        return;
    };
    defer app.allocator.free(json);
    respond(app, id, json);
}

/// setMinecraftDir(path) → "true"/"false"; persists. Rejected while an update
/// worker is running (the worker snapshots the dir when it starts), and the
/// path is validated by the UI through `validateFolder` before calling.
fn cbSetMinecraftDir(id: [*c]const u8, req: [*c]const u8, arg: ?*anyopaque) callconv(.c) void {
    const app = appFromArg(arg);
    var path: []const u8 = undefined;
    if (!firstStringArg(app, req, &path)) {
        respond(app, id, "false");
        return;
    }

    app.mutex.lock();
    defer app.mutex.unlock();
    if (path.len == 0 or app.refreshing.load(.acquire)) {
        app.allocator.free(path);
        respond(app, id, "false");
        return;
    }
    const old = app.cfg.minecraftDir;
    app.cfg.minecraftDir = path; // ownership transferred to the config
    app.allocator.free(old);

    // A hand-typed folder is no longer a launcher profile pick.
    if (app.cfg.selectedProfile) |old_sp| {
        app.allocator.free(old_sp.kind);
        app.allocator.free(old_sp.name);
        app.allocator.free(old_sp.gameDir);
        app.cfg.selectedProfile = null;
    }

    if (config_mod.save(&app.cfg)) {
        respond(app, id, "true");
    } else |_| {
        respond(app, id, "false");
    }
}

/// listLaunchers() → discovery JSON: {"profiles":[...],"errors":[...]}.
fn cbListLaunchers(id: [*c]const u8, req: [*c]const u8, arg: ?*anyopaque) callconv(.c) void {
    _ = req;
    const app = appFromArg(arg);

    const d = launcher.discoverAll(app.allocator) catch {
        respond(app, id, "{\"profiles\":[],\"errors\":[\"discovery failed\"]}");
        return;
    };
    defer launcher.freeDiscovery(app.allocator, d);

    const json = buildLaunchersJson(app.allocator, &d) catch {
        respond(app, id, "{\"profiles\":[],\"errors\":[\"discovery failed\"]}");
        return;
    };
    defer app.allocator.free(json);
    respond(app, id, json);
}

/// selectProfile(gameDir) → "true"/"false"; sets minecraftDir + selectedProfile
/// if (and only if) the gameDir matches a discovered profile, then persists.
/// Rejected while an update worker is running.
fn cbSelectProfile(id: [*c]const u8, req: [*c]const u8, arg: ?*anyopaque) callconv(.c) void {
    const app = appFromArg(arg);
    var game_dir: []const u8 = undefined;
    if (!firstStringArg(app, req, &game_dir)) {
        respond(app, id, "false");
        return;
    }

    // Cheap pre-check before scanning the filesystem.
    if (app.refreshing.load(.acquire)) {
        app.allocator.free(game_dir);
        respond(app, id, "false");
        return;
    }

    // Discover OUTSIDE the lock (filesystem scan), then decide under the lock.
    const d = launcher.discoverAll(app.allocator) catch {
        app.allocator.free(game_dir);
        respond(app, id, "false");
        return;
    };
    defer launcher.freeDiscovery(app.allocator, d);

    var matched: ?launcher.Profile = null;
    for (d.profiles) |p| {
        if (std.mem.eql(u8, p.gameDir, game_dir)) {
            matched = p;
            break;
        }
    }
    const p = matched orelse {
        app.allocator.free(game_dir); // not an offered profile — reject
        respond(app, id, "false");
        return;
    };

    app.mutex.lock();
    defer app.mutex.unlock();

    if (app.refreshing.load(.acquire)) {
        app.allocator.free(game_dir);
        respond(app, id, "false");
        return;
    }

    const kind = app.allocator.dupe(u8, @tagName(p.kind)) catch {
        app.allocator.free(game_dir);
        respond(app, id, "false");
        return;
    };
    const name = app.allocator.dupe(u8, p.name) catch {
        app.allocator.free(kind);
        app.allocator.free(game_dir);
        respond(app, id, "false");
        return;
    };
    // `selectedProfile.gameDir` must be its OWN allocation: `freeConfig` frees
    // it independently of `minecraftDir`.
    const profile_dir = app.allocator.dupe(u8, game_dir) catch {
        app.allocator.free(kind);
        app.allocator.free(name);
        app.allocator.free(game_dir);
        respond(app, id, "false");
        return;
    };

    const old = app.cfg.minecraftDir;
    app.cfg.minecraftDir = game_dir; // ownership transferred to the config
    app.allocator.free(old);
    if (app.cfg.selectedProfile) |old_sp| {
        app.allocator.free(old_sp.kind);
        app.allocator.free(old_sp.name);
        app.allocator.free(old_sp.gameDir);
    }
    app.cfg.selectedProfile = .{ .kind = kind, .name = name, .gameDir = profile_dir };

    if (config_mod.save(&app.cfg)) {
        respond(app, id, "true");
    } else |_| {
        respond(app, id, "false");
    }
}

/// restoreDefaults() → "true"/"false"; replaces the repo list with the seed
/// (from `<config-dir>/defaults.json`, else embedded) and persists.
fn cbRestoreDefaults(id: [*c]const u8, req: [*c]const u8, arg: ?*anyopaque) callconv(.c) void {
    _ = req;
    const app = appFromArg(arg);

    const seeded = config_mod.defaultRepos(app.allocator) catch {
        respond(app, id, "false");
        return;
    };

    app.mutex.lock();
    defer app.mutex.unlock();

    freeRepoSlice(app.allocator, app.cfg.repos);
    app.cfg.repos = seeded; // ownership transferred to the config
    app.pruneStatesLocked();

    if (config_mod.save(&app.cfg)) {
        respond(app, id, "true");
    } else |_| {
        respond(app, id, "false");
    }
}

/// addRepo("owner/name") → "true"/"false"; appends + persists.
fn cbAddRepo(id: [*c]const u8, req: [*c]const u8, arg: ?*anyopaque) callconv(.c) void {
    const app = appFromArg(arg);
    var spec: []const u8 = undefined;
    if (!firstStringArg(app, req, &spec)) {
        respond(app, id, "false");
        return;
    }
    defer app.allocator.free(spec);

    app.mutex.lock();
    defer app.mutex.unlock();
    const ok = app.addRepo(spec) catch false;
    respond(app, id, if (ok) "true" else "false");
}

/// removeRepo("owner/name") → "true"/"false"; filters + persists. A repo the
/// running worker is currently touching is rejected.
fn cbRemoveRepo(id: [*c]const u8, req: [*c]const u8, arg: ?*anyopaque) callconv(.c) void {
    const app = appFromArg(arg);
    var spec: []const u8 = undefined;
    if (!firstStringArg(app, req, &spec)) {
        respond(app, id, "false");
        return;
    }
    defer app.allocator.free(spec);

    app.mutex.lock();
    defer app.mutex.unlock();

    if (parseOwnerName(spec)) |parts| {
        if (app.write_owner) |wo| {
            if (std.mem.eql(u8, wo, parts[0]) and std.mem.eql(u8, app.write_name orelse "", parts[1])) {
                respond(app, id, "false"); // mid-write
                return;
            }
        }
    }

    const ok = app.removeRepo(spec) catch false;
    if (ok) app.pruneStatesLocked();
    respond(app, id, if (ok) "true" else "false");
}

/// startRefresh() → "true" if a worker was spawned, "false" if one is already
/// running (or spawning failed). Returns immediately; UI stays responsive.
fn cbStartRefresh(id: [*c]const u8, req: [*c]const u8, arg: ?*anyopaque) callconv(.c) void {
    _ = req;
    const app = appFromArg(arg);

    if (app.refreshing.cmpxchgStrong(false, true, .acquire, .monotonic) != null) {
        respond(app, id, "false"); // already running
        return;
    }
    const t = std.Thread.spawn(.{}, updateWorkerEntry, .{ app, UpdateJob{} }) catch {
        app.refreshing.store(false, .release);
        respond(app, id, "false");
        return;
    };
    t.detach();
    respond(app, id, "true");
}

/// Heap-owned arguments for `updateWorkerEntry` (slices must outlive the
/// calling bind callback, so they are duped and freed by the entry function).
const UpdateJob = struct {
    owner: ?[]const u8 = null,
    name: ?[]const u8 = null,
};

fn updateWorkerEntry(app: *App, job: UpdateJob) void {
    defer if (job.owner) |v| app.allocator.free(v);
    defer if (job.name) |v| app.allocator.free(v);
    app.updateWorker(job.owner, job.name);
}

// ============================================================================
// Scoped repo update + OS helper bindings
// ============================================================================

const RepoAction = enum { update, install, retry };

/// updateRepo/installRepo/retryRepo(owner, name) → "true" if a scoped worker
/// was spawned, "false" if the repo isn't tracked or an update is in flight.
/// All three run the identical staged pipeline; `retry` also clears the row's
/// previous error copy first.
fn startRepoUpdate(app: *App, id: [*c]const u8, req: [*c]const u8, action: RepoAction) void {
    var owner: []const u8 = undefined;
    var name: []const u8 = undefined;
    if (!twoStringArgs(app, req, &owner, &name)) {
        respond(app, id, "false");
        return;
    }
    defer app.allocator.free(owner);
    defer app.allocator.free(name);

    if (owner.len == 0 or name.len == 0) {
        respond(app, id, "false");
        return;
    }

    app.mutex.lock();
    if (!app.repoIsTrackedLocked(owner, name)) {
        app.mutex.unlock();
        respond(app, id, "false");
        return;
    }
    if (action == .retry) {
        if (app.stateSlotLocked(owner, name)) |s| {
            app.setOwnedLocked(&s.err, null);
            s.stage = .idle;
        }
    }
    app.mutex.unlock();

    if (app.refreshing.cmpxchgStrong(false, true, .acquire, .monotonic) != null) {
        respond(app, id, "false"); // one worker at a time
        return;
    }
    const owner_copy = app.allocator.dupe(u8, owner) catch {
        app.refreshing.store(false, .release);
        respond(app, id, "false");
        return;
    };
    const name_copy = app.allocator.dupe(u8, name) catch {
        app.allocator.free(owner_copy);
        app.refreshing.store(false, .release);
        respond(app, id, "false");
        return;
    };
    const t = std.Thread.spawn(.{}, updateWorkerEntry, .{ app, UpdateJob{ .owner = owner_copy, .name = name_copy } }) catch {
        app.allocator.free(owner_copy);
        app.allocator.free(name_copy);
        app.refreshing.store(false, .release);
        respond(app, id, "false");
        return;
    };
    t.detach();
    respond(app, id, "true");
}

fn cbUpdateRepo(id: [*c]const u8, req: [*c]const u8, arg: ?*anyopaque) callconv(.c) void {
    startRepoUpdate(appFromArg(arg), id, req, .update);
}

fn cbInstallRepo(id: [*c]const u8, req: [*c]const u8, arg: ?*anyopaque) callconv(.c) void {
    startRepoUpdate(appFromArg(arg), id, req, .install);
}

fn cbRetryRepo(id: [*c]const u8, req: [*c]const u8, arg: ?*anyopaque) callconv(.c) void {
    startRepoUpdate(appFromArg(arg), id, req, .retry);
}

/// openUrl(url) → {"ok":true} or {"ok":false,"error":"..."}.
fn cbOpenUrl(id: [*c]const u8, req: [*c]const u8, arg: ?*anyopaque) callconv(.c) void {
    const app = appFromArg(arg);
    var url: []const u8 = undefined;
    if (!firstStringArg(app, req, &url)) {
        respondResult(app, id, false, "Couldn't open browser.");
        return;
    }
    defer app.allocator.free(url);

    os.openUrl(url) catch {
        respondResult(app, id, false, "Couldn't open browser.");
        return;
    };
    respondResult(app, id, true, "");
}

/// copyToClipboard(text) → {"ok":true} or {"ok":false,"error":"..."}.
fn cbCopyToClipboard(id: [*c]const u8, req: [*c]const u8, arg: ?*anyopaque) callconv(.c) void {
    const app = appFromArg(arg);
    var text: []const u8 = undefined;
    if (!firstStringArg(app, req, &text)) {
        respondResult(app, id, false, "Couldn't copy.");
        return;
    }
    defer app.allocator.free(text);

    os.copyToClipboard(text) catch {
        respondResult(app, id, false, "Couldn't copy.");
        return;
    };
    respondResult(app, id, true, "");
}

/// validateFolder(path) → {"valid":true} or {"valid":false,"error":"..."}.
fn cbValidateFolder(id: [*c]const u8, req: [*c]const u8, arg: ?*anyopaque) callconv(.c) void {
    const app = appFromArg(arg);
    var path: []const u8 = undefined;
    if (!firstStringArg(app, req, &path)) {
        respond(app, id, "{\"valid\":false,\"error\":\"Folder not found.\"}");
        return;
    }
    defer app.allocator.free(path);

    if (path.len == 0) {
        respond(app, id, "{\"valid\":false,\"error\":\"Folder not found.\"}");
        return;
    }
    const valid = os.validateFolderWritable(path) catch {
        respond(app, id, "{\"valid\":false,\"error\":\"Couldn't check that folder.\"}");
        return;
    };
    respond(app, id, if (valid)
        "{\"valid\":true}"
    else
        "{\"valid\":false,\"error\":\"Folder doesn't exist or isn't writable.\"}");
}

// ============================================================================
// Owned-config helpers
// ============================================================================

/// Split `"owner/name"`; null unless there are exactly two non-empty parts.
fn parseOwnerName(owner_and_name: []const u8) ?struct { []const u8, []const u8 } {
    var it = std.mem.splitScalar(u8, owner_and_name, '/');
    const owner = it.next() orelse return null;
    const name = it.next() orelse return null;
    if (owner.len == 0 or name.len == 0) return null;
    if (it.next() != null) return null;
    return .{ owner, name };
}

/// Deep-copy a Config so the allocator owns every string. Used by `App.init`
/// so a config built from the global `seeded_repos` is never mutated/freed.
pub fn cloneConfig(allocator: Allocator, cfg: Config) !Config {
    const minecraft_dir = try allocator.dupe(u8, cfg.minecraftDir);
    errdefer allocator.free(minecraft_dir);
    const token = if (cfg.githubToken) |t| try allocator.dupe(u8, t) else null;
    errdefer if (token) |t| allocator.free(t);

    const repos = try allocator.alloc(Repo, cfg.repos.len);
    errdefer allocator.free(repos);
    var built: usize = 0;
    errdefer for (repos[0..built]) |r| freeRepoOwned(allocator, r);

    for (cfg.repos, repos) |src, *dst| {
        dst.* = try dupeRepo(allocator, src);
        built += 1;
    }

    return .{ .minecraftDir = minecraft_dir, .githubToken = token, .repos = repos };
}

fn dupeRepo(allocator: Allocator, src: Repo) !Repo {
    const owner = try allocator.dupe(u8, src.owner);
    errdefer allocator.free(owner);
    const name = try allocator.dupe(u8, src.name);
    errdefer allocator.free(name);
    const installed_version = if (src.installedVersion) |v| try allocator.dupe(u8, v) else null;
    errdefer if (installed_version) |v| allocator.free(v);
    const installed_jar = if (src.installedJar) |v| try allocator.dupe(u8, v) else null;
    return .{
        .owner = owner,
        .name = name,
        .installedVersion = installed_version,
        .installedJar = installed_jar,
    };
}

fn freeRepoOwned(allocator: Allocator, r: Repo) void {
    allocator.free(r.owner);
    allocator.free(r.name);
    if (r.installedVersion) |v| allocator.free(v);
    if (r.installedJar) |v| allocator.free(v);
}

/// Free every entry of an owned repos slice plus the slice itself.
fn freeRepoSlice(allocator: Allocator, repos: []Repo) void {
    for (repos) |r| freeRepoOwned(allocator, r);
    allocator.free(repos);
}

/// Free an owned `RepoStatus` stored on `App.repo_states` (every string in
/// such a row is allocator-owned; borrowed rows handed to `buildStateJson`
/// in tests are never passed here).
fn freeStatus(allocator: Allocator, s: RepoStatus) void {
    allocator.free(s.owner);
    allocator.free(s.name);
    allocator.free(s.status);
    if (s.latest) |v| allocator.free(v);
    if (s.err) |v| allocator.free(v);
    if (s.available_version) |v| allocator.free(v);
    if (s.icon) |v| allocator.free(v);
}

/// Format GitHub's rate-limit reset epoch as the UI copy. Returns null on OOM
/// or when no reset time is available.
fn formatRateLimitReset(allocator: Allocator, reset: ?i64) ?[]const u8 {
    const secs = reset orelse
        return allocator.dupe(u8, "GitHub rate limit reached. Try again later.") catch null;
    if (secs <= 0)
        return allocator.dupe(u8, "GitHub rate limit reached. Try again later.") catch null;

    const es: std.time.epoch.EpochSeconds = .{ .secs = @intCast(secs) };
    const yd = es.getEpochDay().calculateYearDay();
    const md = yd.calculateMonthDay();
    const ds = es.getDaySeconds();
    return std.fmt.allocPrint(
        allocator,
        "GitHub rate limit reached. Try again after {d}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2} UTC.",
        .{
            yd.year,
            @backingInt(md.month),
            md.day_index + 1,
            ds.getHoursIntoDay(),
            ds.getMinutesIntoHour(),
        },
    ) catch null;
}

/// Map a network/release error to the exact user-facing copy. Returns an
/// allocator-owned string (caller frees) or null when the caller should use
/// its generic fallback (OOM / unknown).
fn releaseErrorMessage(allocator: Allocator, err: anyerror, rate_reset: ?i64) ?[]const u8 {
    const copy: []const u8 = switch (err) {
        error.NotFound => "Repository not found or unavailable. Check owner/name.",
        error.RateLimited => return formatRateLimitReset(allocator, rate_reset),
        error.NoCompatibleJar => "No compatible .jar release found for this install.",
        error.DownloadFailed => "Couldn't download. Check your connection and retry.",
        error.Offline, error.InvalidPayload => "Couldn't reach GitHub. Check your connection and retry.",
        error.OutOfMemory => return null,
        else => return null,
    };
    return allocator.dupe(u8, copy) catch null;
}

// ============================================================================
// Tests
// ============================================================================

test "buildStateJson: installed repo row carries owner, name, version, jar, status" {
    var repos = [1]Repo{
        .{ .owner = "cumsauce", .name = "gore", .installedVersion = "v0.1.2", .installedJar = "gore-0.1.2.jar" },
    };
    const cfg = Config{ .minecraftDir = "/tmp/mc", .githubToken = null, .repos = &repos };
    const statuses = [1]RepoStatus{
        .{ .owner = "cumsauce", .name = "gore", .status = "installed v0.1.2" },
    };

    const json = try buildStateJson(std.testing.allocator, &cfg, &statuses, false);
    defer std.testing.allocator.free(json);

    try std.testing.expect(std.mem.indexOf(u8, json, "\"minecraftDir\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"/tmp/mc\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"gore\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"v0.1.2\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"gore-0.1.2.jar\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"installed v0.1.2\"") != null);
}

test "buildStateJson: cached jar icon serializes as a data URL" {
    const icon = "data:image/png;base64,iVBORw0KGgo=";
    var repos = [1]Repo{
        .{ .owner = "a", .name = "b", .installedVersion = "v1", .installedJar = "b.jar" },
    };
    const cfg = Config{ .minecraftDir = "/tmp/mc", .githubToken = null, .repos = &repos };
    const statuses = [1]RepoStatus{
        .{ .owner = "a", .name = "b", .status = "up to date", .icon = icon },
    };

    const json = try buildStateJson(std.testing.allocator, &cfg, &statuses, false);
    defer std.testing.allocator.free(json);

    try std.testing.expect(std.mem.indexOf(u8, json, ",\"icon\":\"data:image/png;base64,iVBORw0KGgo=\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, ",\"icon\":null") == null);
}

test "jarIconRank prefers namespaced icon, then logo, then root files" {
    try std.testing.expectEqual(@as(?u8, 0), jarIconRank("assets/foo/icon.png"));
    try std.testing.expectEqual(@as(?u8, 1), jarIconRank("assets/foo/logo.png"));
    try std.testing.expectEqual(@as(?u8, 3), jarIconRank("icon.png"));
    try std.testing.expectEqual(@as(?u8, 4), jarIconRank("logo.png"));
    try std.testing.expectEqual(@as(?u8, 5), jarIconRank("pack.png"));
    try std.testing.expectEqual(@as(?u8, null), jarIconRank("assets/foo/other.png"));
    try std.testing.expectEqual(@as(?u8, null), jarIconRank("assets/icon.png"));
    try std.testing.expectEqual(@as(?u8, null), jarIconRank("assets/a/b/icon.png"));
}

test "buildStateJson: no-releases row plus null installedVersion serializes as null" {
    var repos = [2]Repo{
        .{ .owner = "cumsauce", .name = "gore", .installedVersion = null, .installedJar = null },
        .{ .owner = "desocketed", .name = "surprise" },
    };
    const cfg = Config{ .minecraftDir = "/tmp/mc", .githubToken = null, .repos = &repos };
    const statuses = [2]RepoStatus{
        .{ .owner = "cumsauce", .name = "gore", .status = "no releases" },
        .{ .owner = "desocketed", .name = "surprise", .status = "no releases" },
    };

    const json = try buildStateJson(std.testing.allocator, &cfg, &statuses, false);
    defer std.testing.allocator.free(json);

    try std.testing.expect(std.mem.indexOf(u8, json, "\"surprise\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"no releases\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"installedVersion\":null") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"installedJar\":null") != null);
}

test "buildStateJson: statuses pair by owner+name, not by index" {
    var repos = [2]Repo{
        .{ .owner = "cumsauce", .name = "gore", .installedVersion = "v0.1.2", .installedJar = "gore-0.1.2.jar" },
        .{ .owner = "desocketed", .name = "surprise" },
    };
    const cfg = Config{ .minecraftDir = "/tmp/mc", .githubToken = null, .repos = &repos };
    // Deliberately ordered DIFFERENTLY from cfg.repos (plus a stale entry for
    // a repo that is no longer in the config) — simulates a mid-refresh
    // add/remove shifting indices. Pairing must be by owner+name.
    const statuses = [3]RepoStatus{
        .{ .owner = "desocketed", .name = "surprise", .status = "no releases" },
        .{ .owner = "ghost", .name = "removed", .status = "stale status" },
        .{ .owner = "cumsauce", .name = "gore", .status = "installed v0.1.2", .latest = "v0.1.2" },
    };

    const json = try buildStateJson(std.testing.allocator, &cfg, &statuses, false);
    defer std.testing.allocator.free(json);

    // Brief's four substrings, all in ONE JSON blob:
    try std.testing.expect(std.mem.indexOf(u8, json, "\"gore\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"v0.1.2\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"surprise\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"no releases\"") != null);

    // The stale status must NOT appear — cfg.repos drives the rows.
    try std.testing.expect(std.mem.indexOf(u8, json, "stale status") == null);

    // Rows come out in cfg.repos order, each carrying the status that
    // matched ITS owner+name (not whatever happened to share an index):
    const gore_row = "{\"owner\":\"cumsauce\",\"name\":\"gore\",\"installedVersion\":\"v0.1.2\",\"installedJar\":\"gore-0.1.2.jar\",\"status\":\"installed v0.1.2\",\"latestVersion\":\"v0.1.2\",\"stage\":\"idle\",\"error\":null,\"availableVersion\":null,\"icon\":null}";
    const surprise_row = "{\"owner\":\"desocketed\",\"name\":\"surprise\",\"installedVersion\":null,\"installedJar\":null,\"status\":\"no releases\",\"latestVersion\":null,\"stage\":\"idle\",\"error\":null,\"availableVersion\":null,\"icon\":null}";
    const gore_at = std.mem.indexOf(u8, json, gore_row) orelse return error.TestUnexpectedResult;
    const surprise_at = std.mem.indexOf(u8, json, surprise_row) orelse return error.TestUnexpectedResult;
    try std.testing.expect(gore_at < surprise_at);
}

test "buildStateJson: repo without a status row gets an empty status" {
    var repos = [1]Repo{.{ .owner = "a", .name = "b" }};
    const cfg = Config{ .minecraftDir = "/tmp/mc", .githubToken = null, .repos = &repos };

    const json = try buildStateJson(std.testing.allocator, &cfg, &.{}, false);
    defer std.testing.allocator.free(json);

    try std.testing.expect(std.mem.indexOf(u8, json, "\"status\":\"\"") != null);
}

test "initFromLoaded seeds the repo list when no config is loaded" {
    // Regression: a first run (no saved config) must end up with the seed
    // repos, not an empty list. The App deep-clones the seed list and only
    // then frees the originals, so `cfg.repos` is non-empty and owned.
    var app = try App.initFromLoaded(std.testing.allocator, null);
    defer app.deinit();

    try std.testing.expect(app.cfg.repos.len > 0);
    try std.testing.expectEqualStrings("gore", app.cfg.repos[0].name);
}

test "cloneConfig deep-copies the seed so mutation never touches it" {
    const alloc = std.testing.allocator;
    const original = try config_mod.defaultRepos(alloc);
    defer config_mod.freeRepos(alloc, original);

    const cfg = try cloneConfig(alloc, Config{
        .minecraftDir = "~/mc",
        .githubToken = null,
        .repos = original,
    });
    defer config_mod.freeConfig(alloc, cfg);

    try std.testing.expect(cfg.repos.ptr != original.ptr);
    try std.testing.expect(cfg.repos[0].owner.ptr != original[0].owner.ptr);
    try std.testing.expect(cfg.repos[4].name.ptr != original[4].name.ptr);
}

test "buildLaunchersJson includes profiles and errors" {
    var profiles = [_]launcher.Profile{
        .{ .kind = .prism, .name = "A", .gameDir = "/m/A", .root = "/r1" },
    };
    var errs = [_][]const u8{"denied"};
    const d = launcher.Discovery{ .profiles = &profiles, .errors = &errs };
    const json = try buildLaunchersJson(std.testing.allocator, &d);
    defer std.testing.allocator.free(json);

    try std.testing.expect(std.mem.indexOf(u8, json, "\"prism\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"A\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "/m/A") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "denied") != null);
}

test "buildLaunchersJson with empty discovery emits empty arrays" {
    const d = launcher.Discovery{ .profiles = &.{}, .errors = &.{} };
    const json = try buildLaunchersJson(std.testing.allocator, &d);
    defer std.testing.allocator.free(json);

    try std.testing.expect(std.mem.indexOf(u8, json, "\"profiles\":[]") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"errors\":[]") != null);
}
