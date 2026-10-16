const std = @import("std");
const Allocator = std.mem.Allocator;

const config_mod = @import("config.zig");
const net = @import("net.zig");
const install = @import("install.zig");
const launcher = @import("launcher.zig");

const Config = config_mod.Config;
const Repo = config_mod.Repo;

// ============================================================================
// Shared state types
// ============================================================================

/// One row of per-repo status for the UI, matched to a Config repo by
/// owner AND name (never by index).
pub const RepoStatus = struct {
    owner: []const u8,
    name: []const u8,
    status: []const u8,
};

/// Persistent (across frames) UI input state. dvui is immediate-mode: widgets
/// are rebuilt every frame, so anything the user types must live here.
pub const UiState = struct {
    /// Backing storage for the minecraft-folder textEntry (`.buffer` mode
    /// finds its length from the first NUL, which TextEntryWidget maintains).
    mc_dir_buf: [1024]u8 = @splat(0),
    /// True when `mc_dir_buf` must be re-seeded from `cfg.minecraftDir`
    /// (first frame, or after a launcher profile was selected).
    mc_dir_dirty: bool = true,
    /// Backing list for the add-repo textEntry (`.array_list` mode).
    add_buf: std.ArrayList(u8) = .empty,
};

/// Blocking mutex over an atomic flag (std.Thread.Mutex no longer exists in
/// Zig 0.17; std.Io.Mutex needs an Io handle, which neither the GUI thread
/// nor the refresh worker has at every call site). Critical sections here are
/// short, so a yield-loop is fine.
const SpinMutex = struct {
    locked: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    pub fn lock(self: *SpinMutex) void {
        while (self.locked.cmpxchgStrong(false, true, .acquire, .monotonic) != null) {
            std.Thread.yield() catch {};
        }
    }

    pub fn unlock(self: *SpinMutex) void {
        self.locked.store(false, .release);
    }
};

// ============================================================================
// App: shared state + background refresh worker
// ============================================================================

pub const App = struct {
    allocator: Allocator,
    /// Always allocator-owned (see `cloneConfig`) — never aliases the global
    /// `seeded_repos` backing `defaultRepos()`.
    cfg: Config,
    /// Guards `cfg`, `statuses` and `stopped` across the GUI thread (dvui
    /// frame callbacks) and the refresh worker thread.
    mutex: SpinMutex = .{},
    /// True while a refresh worker is running (guards double-spawn; also read
    /// by `drainRefresh` after the window closes).
    refreshing: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    /// Set under the mutex once the window is about to go away; the worker
    /// checks it before calling `dvui.refresh` on `win`.
    stopped: bool = false,
    /// dvui window handle (opaque here — this file stays free of the dvui
    /// import so unit tests do not link the GUI stack). Set once from the
    /// GUI thread (`appInit`) together with `wake`.
    win: ?*anyopaque = null,
    /// Callback that wakes the GUI thread (implemented in `main.zig` as
    /// `dvui.refresh(win, ...)`); called by the worker with `win` after each
    /// repo. Set once from the GUI thread before any worker can run.
    wake: ?*const fn (?*anyopaque) void = null,
    /// Per-repo status strings for the UI, keyed by owner+name. Guarded by
    /// `mutex`; entries are allocator-owned and freed in `deinit`.
    statuses: std.ArrayList(RepoStatus) = .empty,
    /// Most recent launcher discovery. GUI-thread only — the refresh worker
    /// never touches it, so the frame renders it without the lock.
    launchers: ?launcher.Discovery = null,
    /// Persistent UI text buffers (see `UiState`).
    ui: UiState = .{},

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

    /// Free everything the App owns. The caller must have drained the refresh
    /// worker first (`drainRefresh`) so no other thread touches this state.
    pub fn deinit(self: *App) void {
        self.clearStatusesLocked();
        self.statuses.deinit(self.allocator);
        if (self.launchers) |d| launcher.freeDiscovery(self.allocator, d);
        self.ui.add_buf.deinit(self.allocator);
        config_mod.freeConfig(self.allocator, self.cfg);
        self.cfg = undefined;
    }

    /// Block until the background refresh worker has fully exited, then mark
    /// the app stopped. Must run before the dvui window is destroyed: the
    /// worker calls `dvui.refresh(win, ...)` and touches `cfg`, both of which
    /// die with the window / `deinit`. The worker clears `refreshing` as its
    /// very last action (its topmost `defer`), so once the flag reads false
    /// nothing else will run. `std.Thread` has no `sleep` in 0.17 and an Io
    /// handle isn't available here, so the wait is a yield-loop.
    pub fn drainRefresh(self: *App) void {
        while (true) {
            self.mutex.lock();
            const busy = self.refreshing.load(.acquire);
            self.mutex.unlock();
            if (!busy) break;
            std.Thread.yield() catch {};
        }
        self.mutex.lock();
        defer self.mutex.unlock();
        self.stopped = true;
    }

    // ------------------------------------------------------------------
    // Config mutation (GUI thread; these take the mutex themselves)
    // ------------------------------------------------------------------

    /// Set + persist the minecraft folder. Returns whether the save worked.
    pub fn setMinecraftDir(self: *App, path: []const u8) !bool {
        const new_dir = try self.allocator.dupe(u8, path);
        errdefer self.allocator.free(new_dir);

        self.mutex.lock();
        defer self.mutex.unlock();
        const old = self.cfg.minecraftDir;
        self.cfg.minecraftDir = new_dir; // ownership transferred to the config
        self.allocator.free(old);
        config_mod.save(&self.cfg) catch return false;
        return true;
    }

    /// Re-scan the filesystem for launcher profiles (Prism, Modrinth) and
    /// cache the result. GUI-thread only; on failure the old list is kept.
    pub fn rescanLaunchers(self: *App) !void {
        const d = try launcher.discoverAll(self.allocator);
        if (self.launchers) |old| launcher.freeDiscovery(self.allocator, old);
        self.launchers = d;
    }

    /// Set minecraftDir + selectedProfile if (and only if) `game_dir` matches
    /// a currently discovered profile, then persist. Returns whether it did.
    pub fn selectProfile(self: *App, game_dir: []const u8) !bool {
        // Discover OUTSIDE the lock (filesystem scan), then decide under it.
        const d = launcher.discoverAll(self.allocator) catch return false;
        defer launcher.freeDiscovery(self.allocator, d);

        var matched: ?launcher.Profile = null;
        for (d.profiles) |p| {
            if (std.mem.eql(u8, p.gameDir, game_dir)) {
                matched = p;
                break;
            }
        }
        const p = matched orelse return false; // not an offered profile — reject

        const kind = try self.allocator.dupe(u8, @tagName(p.kind));
        errdefer self.allocator.free(kind);
        const name = try self.allocator.dupe(u8, p.name);
        errdefer self.allocator.free(name);
        const new_dir = try self.allocator.dupe(u8, p.gameDir);
        errdefer self.allocator.free(new_dir);

        self.mutex.lock();
        defer self.mutex.unlock();

        const old = self.cfg.minecraftDir;
        self.cfg.minecraftDir = new_dir; // ownership transferred to the config
        self.allocator.free(old);
        if (self.cfg.selectedProfile) |old_sp| {
            self.allocator.free(old_sp.kind);
            self.allocator.free(old_sp.name);
            self.allocator.free(old_sp.gameDir);
        }
        self.cfg.selectedProfile = .{ .kind = kind, .name = name, .gameDir = new_dir };

        config_mod.save(&self.cfg) catch return false;
        return true;
    }

    /// Replace the repo list with the seed (`<config-dir>/defaults.json`,
    /// else embedded) and persist.
    pub fn restoreDefaults(self: *App) !bool {
        const seeded = config_mod.defaultRepos(self.allocator) catch return false;

        self.mutex.lock();
        defer self.mutex.unlock();

        freeRepoSlice(self.allocator, self.cfg.repos);
        self.cfg.repos = seeded; // ownership transferred to the config

        config_mod.save(&self.cfg) catch return false;
        return true;
    }

    /// Parse `"owner/name"`, append a fresh Repo (null installed fields),
    /// free the OLD owned repos slice, and persist. Never touches the global
    /// seed — `cfg.repos` is always the allocator-owned clone from `init`.
    pub fn addRepo(self: *App, owner_and_name: []const u8) !bool {
        const owner, const name = (parseOwnerName(owner_and_name) orelse return false);

        self.mutex.lock();
        defer self.mutex.unlock();

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
    pub fn removeRepo(self: *App, owner_and_name: []const u8) !bool {
        const owner, const name = (parseOwnerName(owner_and_name) orelse return false);

        self.mutex.lock();
        defer self.mutex.unlock();

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
    // Status map (callers hold the mutex)
    // ------------------------------------------------------------------

    /// Record `status` (allocator-owned; ownership transfers to the map)
    /// against `owner`/`name`, replacing any previous status for that repo.
    fn setStatusLocked(self: *App, owner: []const u8, name: []const u8, status: []const u8) void {
        for (self.statuses.items) |*s| {
            if (std.mem.eql(u8, s.owner, owner) and std.mem.eql(u8, s.name, name)) {
                self.allocator.free(s.status);
                s.status = status;
                return;
            }
        }
        const o = self.allocator.dupe(u8, owner) catch {
            self.allocator.free(status);
            return;
        };
        const n = self.allocator.dupe(u8, name) catch {
            self.allocator.free(o);
            self.allocator.free(status);
            return;
        };
        self.statuses.append(self.allocator, .{ .owner = o, .name = n, .status = status }) catch {
            self.allocator.free(o);
            self.allocator.free(n);
            self.allocator.free(status);
        };
    }

    /// The status string for a repo, or null if it has none yet. The slice
    /// is valid until the next status update for this repo.
    pub fn findStatusLocked(self: *App, owner: []const u8, name: []const u8) ?[]const u8 {
        for (self.statuses.items) |s| {
            if (std.mem.eql(u8, s.owner, owner) and std.mem.eql(u8, s.name, name)) {
                return s.status;
            }
        }
        return null;
    }

    /// Free every status entry, keeping the allocation. Caller holds the
    /// mutex (or has already drained the worker in `deinit`).
    fn clearStatusesLocked(self: *App) void {
        for (self.statuses.items) |s| {
            self.allocator.free(s.owner);
            self.allocator.free(s.name);
            self.allocator.free(s.status);
        }
        self.statuses.clearRetainingCapacity();
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

    /// Start a background refresh (no-op if one is already running). The
    /// per-repo status map is cleared first so rows start fresh; each repo
    /// publishes its status under the mutex and wakes the GUI thread with
    /// `dvui.refresh`.
    pub fn startRefresh(self: *App) void {
        if (self.refreshing.cmpxchgStrong(false, true, .acquire, .monotonic) != null) {
            return; // already running
        }
        {
            self.mutex.lock();
            defer self.mutex.unlock();
            self.clearStatusesLocked();
        }
        const t = std.Thread.spawn(.{}, refreshWorkerEntry, .{self}) catch {
            self.refreshing.store(false, .release);
            return;
        };
        t.detach();
    }

    /// Background thread body: snapshot the repo list, fetch/install each repo
    /// in turn (per-repo errors become status strings, never abort the loop),
    /// publish each status + wake the GUI after each repo, persist at the end.
    fn refreshWorker(self: *App) void {
        // Drain-loop contract: `startRefresh` already set `refreshing` true
        // before spawning this thread (atomically, to guard double-spawn), and
        // this topmost defer clears it as the very last statement on EVERY
        // exit path — including the early returns below. `drainRefresh` spins
        // on this flag, so it can never tear down the window while any code in
        // this function is still live.
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

        // One HTTP client for the whole run (struct literal; no init fn).
        var threaded = std.Io.Threaded.init(self.allocator, .{});
        var client: std.http.Client = .{ .allocator = self.allocator, .io = threaded.io() };
        defer client.deinit();

        for (repos) |repo| {
            const status = self.refreshRepo(&client, minecraft_dir, token, repo);

            // Publish the status under the lock, grab the window, then wake
            // the GUI thread (dvui.refresh is thread-safe; it just queues an
            // event so the frame loop redraws).
            self.mutex.lock();
            self.setStatusLocked(repo.owner, repo.name, status); // takes ownership
            const win = if (self.stopped) null else self.win;
            const wake = self.wake;
            self.mutex.unlock();
            if (win) |w| {
                if (wake) |wake_fn| wake_fn(w);
            }
        }

        // --- persist the updated config ---
        self.mutex.lock();
        defer self.mutex.unlock();
        config_mod.save(&self.cfg) catch {};
    }
};

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

test "statuses pair by owner+name, not by insertion order" {
    const alloc = std.testing.allocator;
    var repos = [2]Repo{
        .{ .owner = "cumsauce", .name = "gore", .installedVersion = "v0.1.2", .installedJar = "gore-0.1.2.jar" },
        .{ .owner = "desocketed", .name = "surprise" },
    };
    var app = try App.init(alloc, Config{
        .minecraftDir = "/tmp/mc",
        .githubToken = null,
        .repos = &repos,
    });
    defer app.deinit();

    app.mutex.lock();
    defer app.mutex.unlock();

    // setStatusLocked takes ownership of the status string, so hand it
    // allocator-owned dupes (as refreshWorker does), never literals.
    //
    // Deliberately ordered DIFFERENTLY from cfg.repos (plus a stale entry
    // for a repo that is no longer in the config) — simulates a mid-refresh
    // add/remove shifting indices. Pairing must be by owner+name.
    app.setStatusLocked("desocketed", "surprise", try alloc.dupe(u8, "no releases"));
    app.setStatusLocked("ghost", "removed", try alloc.dupe(u8, "stale status"));
    app.setStatusLocked("cumsauce", "gore", try alloc.dupe(u8, "installed v0.1.2"));
    // Re-setting an existing repo replaces its status in place (no dup of
    // owner/name; testing.allocator catches any leak of the old status).
    app.setStatusLocked("cumsauce", "gore", try alloc.dupe(u8, "up to date"));

    try std.testing.expectEqual(@as(usize, 3), app.statuses.items.len);
    try std.testing.expectEqualStrings("up to date", app.findStatusLocked("cumsauce", "gore").?);
    try std.testing.expectEqualStrings("no releases", app.findStatusLocked("desocketed", "surprise").?);
    try std.testing.expectEqualStrings("stale status", app.findStatusLocked("ghost", "removed").?);
    try std.testing.expect(app.findStatusLocked("nobody", "nothing") == null);
}

test "parseOwnerName splits owner/name" {
    const ok = parseOwnerName("cumsauce/gore").?;
    try std.testing.expectEqualStrings("cumsauce", ok[0]);
    try std.testing.expectEqualStrings("gore", ok[1]);

    try std.testing.expect(parseOwnerName("gore") == null);
    try std.testing.expect(parseOwnerName("") == null);
    try std.testing.expect(parseOwnerName("/gore") == null);
    try std.testing.expect(parseOwnerName("cumsauce/") == null);
    try std.testing.expect(parseOwnerName("a/b/c") == null);
}
