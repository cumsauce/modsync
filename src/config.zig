const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

pub const Repo = struct {
    owner: []const u8,
    name: []const u8,
    installedVersion: ?[]const u8 = null,
    installedJar: ?[]const u8 = null,
};

pub const ProfileRef = struct {
    kind: []const u8, // "prism" | "modrinth"
    name: []const u8, // display label (folder name)
    gameDir: []const u8, // absolute; equals minecraftDir when set via a pick
};

pub const Config = struct {
    minecraftDir: []const u8,
    githubToken: ?[]const u8 = null,
    repos: []Repo,
    /// The launcher profile the user picked, for display. `minecraftDir` stays
    /// the authoritative path; this records where it came from.
    selectedProfile: ?ProfileRef = null,
};

/// Backing storage for `defaultRepos`. Returned as a mutable slice because the
/// interface has no allocator; callers may copy from it before mutating.
var seeded_repos = [_]Repo{
    .{ .owner = "cumsauce", .name = "gore" },
    .{ .owner = "cumsauce", .name = "foley" },
    .{ .owner = "cumsauce", .name = "earshot" },
    .{ .owner = "cumsauce", .name = "stalker" },
    .{ .owner = "cumsauce", .name = "aorta" },
    .{ .owner = "desocketed", .name = "yakvc" },
};

/// The repositories modsync seeds a fresh config with, in order.
pub fn defaultRepos() []Repo {
    return &seeded_repos;
}

/// Per-OS standard Minecraft directory, with `~` left un-expanded (static
/// literal — allocation-free, safe lifetime). Task 4's modsDir() expands `~`
/// against $HOME when building the full path.
pub fn defaultMinecraftDir() []const u8 {
    return switch (builtin.target.os.tag) {
        .macos => "~/Library/Application Support/minecraft",
        else => "~/.minecraft",
    };
}

/// A Threaded Io instance seeded with the real process environment.
///
/// Note: `Threaded.environString` is NOT used for arbitrary keys — on Windows
/// its pre-scanned `Environ.String` struct is empty, so `environString("HOME")`
/// and `environString("APPDATA")` don't even compile there. We still need a
/// Threaded for file I/O, so this seeds it; env lookups go through `getEnv`.
fn makeThreaded() std.Io.Threaded {
    if (builtin.target.os.tag == .windows) {
        return std.Io.Threaded.init(std.heap.page_allocator, .{
            .environ = .{ .block = .global },
        });
    }
    var count: usize = 0;
    while (std.c.environ[count] != null) : (count += 1) {}
    return std.Io.Threaded.init(std.heap.page_allocator, .{
        .environ = .{ .block = .{ .slice = std.c.environ[0..count :null] } },
    });
}

/// Portable environment-variable lookup (UTF-8 value, caller owns).
/// Uses `std.process.Environ.getAlloc`, which branches to the POSIX/Windows
/// implementation internally — unlike `Threaded.environString`, it works for
/// arbitrary keys on every platform.
fn getEnv(allocator: Allocator, key: []const u8) ?[]u8 {
    const environ: std.process.Environ = if (builtin.target.os.tag == .windows)
        .{ .block = .global }
    else blk: {
        var count: usize = 0;
        while (std.c.environ[count] != null) : (count += 1) {}
        break :blk .{ .block = .{ .slice = std.c.environ[0..count :null] } };
    };
    return std.process.Environ.getAlloc(environ, allocator, key) catch null;
}

/// Absolute platform config file path (`~`/`%APPDATA%` expanded). Caller owns.
pub fn configPath(allocator: Allocator) ![]const u8 {
    var buf: [4096]u8 = undefined;
    const path: []const u8 = if (builtin.target.os.tag == .windows) blk: {
        const appdata = getEnv(allocator, "APPDATA") orelse return error.NoAppDataDirectory;
        defer allocator.free(appdata);
        break :blk try std.fmt.bufPrint(&buf, "{s}\\modsync\\config.json", .{appdata});
    } else blk: {
        const home = getEnv(allocator, "HOME") orelse return error.NoHomeDirectory;
        defer allocator.free(home);
        break :blk switch (builtin.target.os.tag) {
            .macos => try std.fmt.bufPrint(&buf, "{s}/Library/Application Support/modsync/config.json", .{home}),
            else => try std.fmt.bufPrint(&buf, "{s}/.config/modsync/config.json", .{home}),
        };
    };
    return try allocator.dupe(u8, path);
}

/// Load the config from `path`; returns null when the file does not exist.
/// A corrupt file surfaces as an error. Caller owns the returned slices
/// (release with `freeConfig`).
pub fn loadFrom(allocator: Allocator, path: []const u8) !?Config {
    var threaded = makeThreaded();
    const io = threaded.io();

    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .unlimited) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer allocator.free(bytes);

    const parsed = try std.json.parseFromSlice(Config, allocator, bytes, .{});
    defer parsed.deinit();

    return try dupeConfig(allocator, parsed.value);
}

/// Write `cfg` to `path` as pretty (indent_2) JSON, creating parent dirs.
pub fn saveTo(path: []const u8, cfg: *const Config) !void {
    var threaded = makeThreaded();
    const io = threaded.io();

    var dir_end: usize = 0;
    if (std.mem.lastIndexOfScalar(u8, path, '/')) |i| dir_end = @max(dir_end, i);
    if (std.mem.lastIndexOfScalar(u8, path, '\\')) |i| dir_end = @max(dir_end, i);
    if (dir_end > 0) {
        const dir = path[0..dir_end];
        // Only create if missing; an existing dir (even a symlinked one like
        // macOS /tmp) makes createDirPath return NotDir, so probe first.
        std.Io.Dir.cwd().access(io, dir, .{}) catch {
            std.Io.Dir.cwd().createDirPath(io, dir) catch |err| return err;
        };
    }

    const json = try std.json.Stringify.valueAlloc(std.heap.page_allocator, cfg, .{ .whitespace = .indent_2 });
    defer std.heap.page_allocator.free(json);

    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = json });
}

/// Load the platform config file; returns null when it does not exist.
pub fn load(allocator: Allocator) !?Config {
    const path = try configPath(allocator);
    defer allocator.free(path);
    return loadFrom(allocator, path);
}

/// Save the config to the platform config file (creates the parent dir).
pub fn save(cfg: *const Config) !void {
    const path = try configPath(std.heap.page_allocator);
    defer std.heap.page_allocator.free(path);
    try saveTo(path, cfg);
}

/// Free everything owned by a Config produced by `load`/`loadFrom`.
pub fn freeConfig(allocator: Allocator, cfg: Config) void {
    allocator.free(cfg.minecraftDir);
    if (cfg.githubToken) |t| allocator.free(t);
    if (cfg.selectedProfile) |p| {
        allocator.free(p.kind);
        allocator.free(p.name);
        allocator.free(p.gameDir);
    }
    for (cfg.repos) |r| freeRepo(allocator, r);
    allocator.free(cfg.repos);
}

fn freeRepo(allocator: Allocator, r: Repo) void {
    allocator.free(r.owner);
    allocator.free(r.name);
    if (r.installedVersion) |v| allocator.free(v);
    if (r.installedJar) |v| allocator.free(v);
}

/// Deep-copy a parsed Config so the caller's allocator owns every string
/// (parseFromSlice's arena is released by its `deinit`).
fn dupeConfig(allocator: Allocator, src: Config) !Config {
    const minecraft_dir = try allocator.dupe(u8, src.minecraftDir);
    errdefer allocator.free(minecraft_dir);

    const token = if (src.githubToken) |t| try allocator.dupe(u8, t) else null;
    errdefer if (token) |t| allocator.free(t);

    const selected_profile: ?ProfileRef = if (src.selectedProfile) |sp| blk: {
        const kind = try allocator.dupe(u8, sp.kind);
        errdefer allocator.free(kind);
        const name = try allocator.dupe(u8, sp.name);
        errdefer allocator.free(name);
        const game_dir = try allocator.dupe(u8, sp.gameDir);
        errdefer allocator.free(game_dir);
        break :blk .{ .kind = kind, .name = name, .gameDir = game_dir };
    } else null;
    errdefer if (selected_profile) |sp| {
        allocator.free(sp.kind);
        allocator.free(sp.name);
        allocator.free(sp.gameDir);
    };

    const repos = try allocator.alloc(Repo, src.repos.len);
    errdefer allocator.free(repos);

    var built: usize = 0;
    errdefer {
        for (repos[0..built]) |r| freeRepo(allocator, r);
    }

    for (src.repos, repos) |s, *d| {
        const owner = try allocator.dupe(u8, s.owner);
        errdefer allocator.free(owner);
        const name = try allocator.dupe(u8, s.name);
        errdefer allocator.free(name);
        const installed_version = if (s.installedVersion) |v| try allocator.dupe(u8, v) else null;
        errdefer if (installed_version) |v| allocator.free(v);
        const installed_jar = if (s.installedJar) |v| try allocator.dupe(u8, v) else null;

        d.* = .{
            .owner = owner,
            .name = name,
            .installedVersion = installed_version,
            .installedJar = installed_jar,
        };
        built += 1;
    }

    return .{
        .minecraftDir = minecraft_dir,
        .githubToken = token,
        .repos = repos,
        .selectedProfile = selected_profile,
    };
}

test "defaultRepos returns the seeded repos in order" {
    const repos = defaultRepos();
    try std.testing.expectEqual(@as(usize, 6), repos.len);
    try std.testing.expectEqualStrings("cumsauce", repos[0].owner);
    try std.testing.expectEqualStrings("gore", repos[0].name);
    try std.testing.expectEqualStrings("desocketed", repos[5].owner);
    try std.testing.expectEqualStrings("yakvc", repos[5].name);

    const expected_owners = [_][]const u8{ "cumsauce", "cumsauce", "cumsauce", "cumsauce", "cumsauce", "desocketed" };
    const expected_names = [_][]const u8{ "gore", "foley", "earshot", "stalker", "aorta", "yakvc" };
    for (expected_owners, expected_names, repos) |eo, en, r| {
        try std.testing.expectEqualStrings(eo, r.owner);
        try std.testing.expectEqualStrings(en, r.name);
        try std.testing.expect(r.installedVersion == null);
        try std.testing.expect(r.installedJar == null);
    }
}

test "configPath is absolute and ends in modsync/config.json" {
    const path = try configPath(std.testing.allocator);
    defer std.testing.allocator.free(path);

    try std.testing.expect(std.mem.startsWith(u8, path, "/"));
    try std.testing.expect(std.mem.endsWith(u8, path, "modsync/config.json"));

    // Force analysis of the real-path wrappers without touching $HOME.
    _ = &load;
    _ = &save;
}

test "Config round-trips through saveTo/loadFrom as pretty JSON" {
    var threaded = std.Io.Threaded.init(std.heap.page_allocator, .{});
    const io = threaded.io();

    const path = "/tmp/modsync-task2-roundtrip.json";
    std.Io.Dir.cwd().deleteFile(io, path) catch {};
    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};

    const repos = try std.testing.allocator.alloc(Repo, 1);
    defer std.testing.allocator.free(repos);
    repos[0] = .{
        .owner = "a",
        .name = "b",
        .installedVersion = "v0.1.2",
        .installedJar = "gore-0.1.2.jar",
    };
    const cfg = Config{
        .minecraftDir = "/tmp/mc",
        .githubToken = null,
        .repos = repos,
    };

    try saveTo(path, &cfg);

    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, std.testing.allocator, .unlimited);
    defer std.testing.allocator.free(bytes);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\"/tmp/mc\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\"v0.1.2\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\"gore-0.1.2.jar\"") != null);
    // Pretty serialization → newline + 2-space indent (indent_2, not minified).
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\n  ") != null);

    const loaded = (try loadFrom(std.testing.allocator, path)) orelse return error.ExpectedConfigToExist;
    defer freeConfig(std.testing.allocator, loaded);

    try std.testing.expectEqualStrings("/tmp/mc", loaded.minecraftDir);
    try std.testing.expect(loaded.githubToken == null);
    try std.testing.expectEqual(@as(usize, 1), loaded.repos.len);
    try std.testing.expectEqualStrings("a", loaded.repos[0].owner);
    try std.testing.expectEqualStrings("b", loaded.repos[0].name);
    try std.testing.expectEqualStrings("v0.1.2", loaded.repos[0].installedVersion.?);
    try std.testing.expectEqualStrings("gore-0.1.2.jar", loaded.repos[0].installedJar.?);

    // Absent file → null, not an error (pinned behavior).
    try std.testing.expect((try loadFrom(std.testing.allocator, "/tmp/modsync-absent-does-not-exist.json")) == null);
}

test "selectedProfile round-trips through saveTo/loadFrom" {
    const path = "/tmp/modsync-task2-profile-roundtrip.json";
    var threaded = std.Io.Threaded.init(std.heap.page_allocator, .{});
    const io = threaded.io();
    std.Io.Dir.cwd().deleteFile(io, path) catch {};
    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};

    const repos = try std.testing.allocator.alloc(Repo, 1);
    defer std.testing.allocator.free(repos);
    repos[0] = .{ .owner = "a", .name = "b" };
    const cfg = Config{
        .minecraftDir = "/tmp/mc",
        .repos = repos,
        .selectedProfile = .{
            .kind = "prism",
            .name = "A",
            .gameDir = "/tmp/instances/A/minecraft",
        },
    };

    try saveTo(path, &cfg);
    const loaded = (try loadFrom(std.testing.allocator, path)) orelse return error.ExpectedConfigToExist;
    defer freeConfig(std.testing.allocator, loaded);

    const sp = loaded.selectedProfile.?;
    try std.testing.expectEqualStrings("prism", sp.kind);
    try std.testing.expectEqualStrings("A", sp.name);
    try std.testing.expectEqualStrings("/tmp/instances/A/minecraft", sp.gameDir);
}

test "a pre-v0.2 config without selectedProfile loads with it null" {
    const path = "/tmp/modsync-task2-legacy-config.json";
    var threaded = std.Io.Threaded.init(std.heap.page_allocator, .{});
    const io = threaded.io();
    std.Io.Dir.cwd().deleteFile(io, path) catch {};
    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};

    // A v0.1.0-shaped config file: no selectedProfile key at all.
    const legacy_json =
        \\{
        \\  "minecraftDir": "/tmp/mc",
        \\  "repos": [
        \\    { "owner": "cumsauce", "name": "gore" }
        \\  ]
        \\}
    ;
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = legacy_json });

    const loaded = (try loadFrom(std.testing.allocator, path)) orelse return error.ExpectedConfigToExist;
    defer freeConfig(std.testing.allocator, loaded);

    try std.testing.expect(loaded.selectedProfile == null);
    try std.testing.expectEqualStrings("/tmp/mc", loaded.minecraftDir);
    try std.testing.expectEqual(@as(usize, 1), loaded.repos.len);
}
