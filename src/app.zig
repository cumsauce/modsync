const std = @import("std");
const Allocator = std.mem.Allocator;

const c = @import("webview_api");

const config_mod = @import("config.zig");
const net = @import("net.zig");
const install = @import("install.zig");
const launcher = @import("launcher.zig");

const Config = config_mod.Config;
const Repo = config_mod.Repo;

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

/// One row of per-repo status for the UI, matched to a Config repo by
/// owner AND name (never by index).
pub const RepoStatus = struct {
    owner: []const u8,
    name: []const u8,
    status: []const u8,
};

/// Emit the JSON blob the UI (Task 7) renders:
/// `{"minecraftDir":"...","repos":[{"owner":...,"name":...,"installedVersion":
/// "v0.1.3"|null,"installedJar":...|null,"status":"..."}, ...]}`.
/// Each entry of `statuses` is paired with the repo whose `owner` AND `name`
/// match it (linear scan — the config can mutate mid-refresh, so index
/// pairing would drift); repos with no matching status get an empty status.
/// One row per `cfg.repos` entry, in `cfg.repos` order. Everything is
/// serialized immediately, so nothing is retained past the call.
pub fn buildStateJson(allocator: Allocator, cfg: *const Config, statuses: []const RepoStatus) ![]u8 {
    var out = try std.ArrayList(u8).initCapacity(allocator, 256);
    errdefer out.deinit(allocator);

    try out.appendSlice(allocator, "{\"minecraftDir\":");
    try appendJsonString(allocator, &out, cfg.minecraftDir);
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
        const status: []const u8 = blk: {
            for (statuses) |s| {
                if (std.mem.eql(u8, s.owner, repo.owner) and std.mem.eql(u8, s.name, repo.name)) {
                    break :blk s.status;
                }
            }
            break :blk "";
        };
        try appendJsonString(allocator, &out, status);
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
    /// by `run`'s drain loop after `webview_run` returns).
    refreshing: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    /// Set under the mutex once the webview handle is destroyed; worker paths
    /// check it before calling `webview_dispatch` on `w`.
    stopped: bool = false,

    /// Store a deep, allocator-owned clone of `cfg`. The caller's copy (which
    /// may slice the global seed from `defaultRepos()`) is left untouched.
    pub fn init(allocator: Allocator, cfg: Config) !App {
        const owned = try cloneConfig(allocator, cfg);
        return .{ .allocator = allocator, .cfg = owned };
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
        config_mod.freeConfig(self.allocator, self.cfg);
        self.cfg = undefined;
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

        const app_arg: ?*anyopaque = self;
        _ = c.webview_bind(w, "getConfig", cbGetConfig, app_arg);
        _ = c.webview_bind(w, "setMinecraftDir", cbSetMinecraftDir, app_arg);
        _ = c.webview_bind(w, "addRepo", cbAddRepo, app_arg);
        _ = c.webview_bind(w, "removeRepo", cbRemoveRepo, app_arg);
        _ = c.webview_bind(w, "startRefresh", cbStartRefresh, app_arg);
        _ = c.webview_bind(w, "listLaunchers", cbListLaunchers, app_arg);
        _ = c.webview_bind(w, "selectProfile", cbSelectProfile, app_arg);
        _ = c.webview_bind(w, "restoreDefaults", cbRestoreDefaults, app_arg);

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

    /// Fetch the latest release for one repo and install it if needed.
    /// Returns an allocator-owned status string for the UI row ("up to date",
    /// "installed vX", "no releases", "no jar asset", "error: <name>").
    /// Never aborts — every failure becomes a status string.
    fn refreshRepo(self: *App, client: *std.http.Client, minecraft_dir: []const u8, token: ?[]const u8, repo: Repo) []const u8 {
        const fetched = net.fetchLatestAsset(self.allocator, client, repo.owner, repo.name, token) catch |err| {
            return switch (err) {
                error.NoReleases => self.allocator.dupe(u8, "no releases") catch unreachable,
                error.NoJarAsset => self.allocator.dupe(u8, "no jar asset") catch unreachable,
                else => std.fmt.allocPrint(self.allocator, "error: {s}", .{@errorName(err)}) catch unreachable,
            };
        } orelse return self.allocator.dupe(u8, "no releases") catch unreachable;
        defer {
            self.allocator.free(fetched.tag);
            self.allocator.free(fetched.name);
            self.allocator.free(fetched.url);
        }

        const mods = install.modsDir(self.allocator, minecraft_dir) catch |err| {
            return std.fmt.allocPrint(self.allocator, "error: {s}", .{@errorName(err)}) catch unreachable;
        };
        defer self.allocator.free(mods);

        const jar_path = std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ mods, fetched.name }) catch unreachable;
        defer self.allocator.free(jar_path);
        const jar_exists = if (std.Io.Dir.cwd().access(client.io, jar_path, .{})) true else |_| false;

        // Same tag + same jar name + jar on disk → nothing to do.
        const version_matches = std.mem.eql(u8, repo.installedVersion orelse "", fetched.tag) and
            std.mem.eql(u8, repo.installedJar orelse "", fetched.name);
        if (version_matches and jar_exists) {
            return self.allocator.dupe(u8, "up to date") catch unreachable;
        }

        install.ensureModsDir(minecraft_dir) catch |err| {
            return std.fmt.allocPrint(self.allocator, "error: {s}", .{@errorName(err)}) catch unreachable;
        };

        const tmp_path = std.fmt.allocPrint(self.allocator, "{s}/{s}.tmp", .{ mods, fetched.name }) catch unreachable;
        defer {
            self.allocator.free(tmp_path);
            // No-op after a successful placeJar (file was moved).
            std.Io.Dir.cwd().deleteFile(client.io, tmp_path) catch {};
        }

        net.downloadJar(self.allocator, client, fetched.url, tmp_path, token) catch |err| {
            return std.fmt.allocPrint(self.allocator, "error: {s}", .{@errorName(err)}) catch unreachable;
        };

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

        install.placeJar(mods, tmp_path, fetched.name) catch |err| {
            return std.fmt.allocPrint(self.allocator, "error: {s}", .{@errorName(err)}) catch unreachable;
        };

        // Record the new install in the live config under the lock.
        {
            self.mutex.lock();
            defer self.mutex.unlock();
            for (self.cfg.repos) |*r| {
                if (std.mem.eql(u8, r.owner, repo.owner) and std.mem.eql(u8, r.name, repo.name)) {
                    if (r.installedVersion) |v| self.allocator.free(v);
                    if (r.installedJar) |v| self.allocator.free(v);
                    r.installedVersion = self.allocator.dupe(u8, fetched.tag) catch null;
                    r.installedJar = self.allocator.dupe(u8, fetched.name) catch null;
                    break;
                }
            }
        }

        return std.fmt.allocPrint(self.allocator, "installed {s}", .{fetched.tag}) catch unreachable;
    }

    /// Background thread body: snapshot the repo list, fetch/install each repo
    /// in turn (per-repo errors become status strings, never abort the loop),
    /// push fresh state JSON to the UI after each repo, persist at the end.
    fn refreshWorker(self: *App) void {
        // Drain-loop contract: `cbStartRefresh` already set `refreshing` true
        // before spawning this thread (atomically, to guard double-spawn), and
        // this topmost defer clears it as the very last statement on EVERY
        // exit path — including the early returns below. `run`'s post-
        // `webview_run` drain loop spins on this flag, so it can never
        // destroy the webview while any code in this function is still live.
        defer self.refreshing.store(false, .release);

        // --- snapshot under the lock ---
        self.mutex.lock();
        const minecraft_dir = self.allocator.dupe(u8, self.cfg.minecraftDir) catch {
            self.mutex.unlock();
            return;
        };
        defer self.allocator.free(minecraft_dir);
        const token = if (self.cfg.githubToken) |t| self.allocator.dupe(u8, t) catch null else null;
        defer if (token) |t| self.allocator.free(t);
        const repos = self.allocator.alloc(Repo, self.cfg.repos.len) catch {
            self.mutex.unlock();
            return;
        };
        for (self.cfg.repos, repos) |src, *dst| {
            dst.* = dupeRepo(self.allocator, src) catch {
                self.mutex.unlock();
                return; // OOM mid-snapshot: leak the partial copy, stop refreshing
            };
        }
        self.mutex.unlock();
        defer for (repos) |r| freeRepoOwned(self.allocator, r);

        const statuses = self.allocator.alloc(RepoStatus, repos.len) catch return;
        var statuses_built: usize = 0;
        defer self.allocator.free(statuses);
        defer for (statuses[0..statuses_built]) |s| self.allocator.free(s.status);

        // One HTTP client for the whole run (struct literal; no init fn).
        var threaded = std.Io.Threaded.init(self.allocator, .{});
        var client: std.http.Client = .{ .allocator = self.allocator, .io = threaded.io() };
        defer client.deinit();

        for (repos, 0..) |repo, i| {
            const status = self.refreshRepo(&client, minecraft_dir, token, repo);
            statuses[i] = .{ .owner = repo.owner, .name = repo.name, .status = status };
            statuses_built = i + 1;

            self.mutex.lock();
            const json = buildStateJson(self.allocator, &self.cfg, statuses[0..statuses_built]);
            self.mutex.unlock();
            if (json) |j| self.pushState(j) else |_| {}
        }

        // --- persist the updated config ---
        self.mutex.lock();
        defer self.mutex.unlock();
        config_mod.save(&self.cfg) catch {};
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

/// getConfig() → full state JSON (statuses empty until a refresh fills them).
fn cbGetConfig(id: [*c]const u8, req: [*c]const u8, arg: ?*anyopaque) callconv(.c) void {
    _ = req;
    const app = appFromArg(arg);

    app.mutex.lock();
    defer app.mutex.unlock();
    const json = buildStateJson(app.allocator, &app.cfg, &.{}) catch {
        respond(app, id, "null");
        return;
    };
    defer app.allocator.free(json);
    respond(app, id, json);
}

/// setMinecraftDir(path) → "true"/"false"; persists.
fn cbSetMinecraftDir(id: [*c]const u8, req: [*c]const u8, arg: ?*anyopaque) callconv(.c) void {
    const app = appFromArg(arg);
    var path: []const u8 = undefined;
    if (!firstStringArg(app, req, &path)) {
        respond(app, id, "false");
        return;
    }

    app.mutex.lock();
    defer app.mutex.unlock();
    const old = app.cfg.minecraftDir;
    app.cfg.minecraftDir = path; // ownership transferred to the config
    app.allocator.free(old);
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
fn cbSelectProfile(id: [*c]const u8, req: [*c]const u8, arg: ?*anyopaque) callconv(.c) void {
    const app = appFromArg(arg);
    var game_dir: []const u8 = undefined;
    if (!firstStringArg(app, req, &game_dir)) {
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

    const old = app.cfg.minecraftDir;
    app.cfg.minecraftDir = game_dir; // ownership transferred to the config
    app.allocator.free(old);
    if (app.cfg.selectedProfile) |old_sp| {
        app.allocator.free(old_sp.kind);
        app.allocator.free(old_sp.name);
        app.allocator.free(old_sp.gameDir);
    }
    app.cfg.selectedProfile = .{ .kind = kind, .name = name, .gameDir = game_dir };

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

/// removeRepo("owner/name") → "true"/"false"; filters + persists.
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
    const ok = app.removeRepo(spec) catch false;
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
    const t = std.Thread.spawn(.{}, refreshWorkerEntry, .{app}) catch {
        app.refreshing.store(false, .release);
        respond(app, id, "false");
        return;
    };
    t.detach();
    respond(app, id, "true");
}

fn refreshWorkerEntry(app: *App) void {
    app.refreshWorker();
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

    const json = try buildStateJson(std.testing.allocator, &cfg, &statuses);
    defer std.testing.allocator.free(json);

    try std.testing.expect(std.mem.indexOf(u8, json, "\"minecraftDir\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"/tmp/mc\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"gore\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"v0.1.2\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"gore-0.1.2.jar\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"installed v0.1.2\"") != null);
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

    const json = try buildStateJson(std.testing.allocator, &cfg, &statuses);
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
        .{ .owner = "cumsauce", .name = "gore", .status = "installed v0.1.2" },
    };

    const json = try buildStateJson(std.testing.allocator, &cfg, &statuses);
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
    const gore_row = "{\"owner\":\"cumsauce\",\"name\":\"gore\",\"installedVersion\":\"v0.1.2\",\"installedJar\":\"gore-0.1.2.jar\",\"status\":\"installed v0.1.2\"}";
    const surprise_row = "{\"owner\":\"desocketed\",\"name\":\"surprise\",\"installedVersion\":null,\"installedJar\":null,\"status\":\"no releases\"}";
    const gore_at = std.mem.indexOf(u8, json, gore_row) orelse return error.TestUnexpectedResult;
    const surprise_at = std.mem.indexOf(u8, json, surprise_row) orelse return error.TestUnexpectedResult;
    try std.testing.expect(gore_at < surprise_at);
}

test "buildStateJson: repo without a status row gets an empty status" {
    var repos = [1]Repo{.{ .owner = "a", .name = "b" }};
    const cfg = Config{ .minecraftDir = "/tmp/mc", .githubToken = null, .repos = &repos };

    const json = try buildStateJson(std.testing.allocator, &cfg, &.{});
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
