//! Launcher detection for modsync: locate Prism Launcher and Modrinth App
//! data directories ("roots") and enumerate the instances/profiles inside.
//!
//! Every string handed back is owned by the caller's allocator (duped —
//! nothing aliases static or iterator-buffer memory); release with the
//! matching `free*` function.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

pub const Kind = enum { prism, modrinth };
pub const Profile = struct {
    kind: Kind,
    name: []const u8,
    gameDir: []const u8,
    root: []const u8,
};
pub const Discovery = struct {
    profiles: []Profile,
    errors: [][]const u8,
};

// ---------------------------------------------------------------------------
// Environment / IO helpers (same Zig 0.17 idioms as config.zig).
// ---------------------------------------------------------------------------

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

/// `access`-based existence probe (spec: a path counts only if it exists).
fn dirExists(io: anytype, path: []const u8) bool {
    std.Io.Dir.cwd().access(io, path, .{}) catch return false;
    return true;
}

/// Expand a leading `~` to the user's home dir (`$HOME` on POSIX,
/// `%USERPROFILE%` on Windows); paths without a leading `~` are duped
/// unchanged. Caller owns the result.
fn expandHome(allocator: Allocator, path: []const u8) ![]u8 {
    if (path.len == 0 or path[0] != '~') return allocator.dupe(u8, path);
    const home_key: []const u8 = if (builtin.target.os.tag == .windows) "USERPROFILE" else "HOME";
    const home = getEnv(allocator, home_key) orelse return error.NoHomeDirectory;
    defer allocator.free(home);
    var rest = path[1..];
    if (rest.len > 0 and (rest[0] == '/' or rest[0] == '\\')) rest = rest[1..];
    if (rest.len == 0) return allocator.dupe(u8, home);
    return std.fs.path.join(allocator, &.{ home, rest });
}

/// True when `cands[i]` equals one of the candidates before it (e.g. an env
/// override that mirrors a default path).
fn seenEarlier(cands: []const []const u8, i: usize, c: []const u8) bool {
    for (cands[0..i]) |prev| {
        if (std.mem.eql(u8, prev, c)) return true;
    }
    return false;
}

// ---------------------------------------------------------------------------
// Roots
// ---------------------------------------------------------------------------

/// Existing data directories for `kind`: the env override first, then every
/// per-OS default that exists. Caller owns the slice and every string
/// (release with `freeRoots`).
pub fn findRoots(allocator: Allocator, kind: Kind) ![][]const u8 {
    var threaded = makeThreaded();
    const io = threaded.io();

    // Owned strings backing `cands`; freed on every exit path (returned roots
    // are re-duped below, so nothing aliases this buffer).
    var owned: [6][]u8 = undefined;
    var n_owned: usize = 0;
    defer {
        for (owned[0..n_owned]) |s| allocator.free(s);
    }

    var cands: [4][]const u8 = undefined;
    var n_cand: usize = 0;

    // 1) Explicit override comes first, but defaults still get a chance —
    //    every path that exists is reported (env first).
    const env_key: []const u8 = switch (kind) {
        .prism => "PRISM_LAUNCHER_DATA_DIR",
        .modrinth => "THESEUS_CONFIG_DIR",
    };
    if (getEnv(allocator, env_key)) |raw| {
        owned[n_owned] = raw;
        n_owned += 1;
        if (expandHome(allocator, raw)) |expanded| {
            owned[n_owned] = expanded;
            n_owned += 1;
            cands[n_cand] = expanded;
            n_cand += 1;
        } else |_| {
            // `~` without a resolvable home → skip the override.
        }
    }

    // 2) Per-OS defaults, anchored at $HOME (%APPDATA% on Windows) so no
    //    literal `~`/`%VAR%` ever reaches `access`.
    const anchor_key: []const u8 = if (builtin.target.os.tag == .windows) "APPDATA" else "HOME";
    if (getEnv(allocator, anchor_key)) |anchor| {
        owned[n_owned] = anchor;
        n_owned += 1;
        const suffixes: []const []const u8 = switch (builtin.target.os.tag) {
            .macos => switch (kind) {
                .prism => &.{"Library/Application Support/PrismLauncher"},
                .modrinth => &.{
                    "Library/Application Support/ModrinthApp",
                    "Library/Application Support/com.modrinth.theseus",
                },
            },
            .windows => switch (kind) {
                .prism => &.{"PrismLauncher"},
                .modrinth => &.{ "ModrinthApp", "com.modrinth.theseus" },
            },
            else => switch (kind) {
                .prism => &.{
                    ".local/share/PrismLauncher",
                    ".var/app/org.prismlauncher.PrismLauncher/data/PrismLauncher",
                },
                .modrinth => &.{ ".local/share/ModrinthApp", ".local/share/com.modrinth.theseus" },
            },
        };
        for (suffixes) |suffix| {
            const path = try std.fs.path.join(allocator, &.{ anchor, suffix });
            owned[n_owned] = path;
            n_owned += 1;
            cands[n_cand] = path;
            n_cand += 1;
        }
    }

    // 3) Keep only paths that exist, deduping exact repeats.
    var existing: usize = 0;
    for (cands[0..n_cand], 0..) |c, i| {
        if (seenEarlier(cands[0..n_cand], i, c)) continue;
        if (dirExists(io, c)) existing += 1;
    }

    const roots = try allocator.alloc([]const u8, existing);
    errdefer allocator.free(roots);
    var n: usize = 0;
    errdefer {
        for (roots[0..n]) |r| allocator.free(r);
    }

    for (cands[0..n_cand], 0..) |c, i| {
        if (seenEarlier(cands[0..n_cand], i, c)) continue;
        if (!dirExists(io, c)) continue;
        roots[n] = try allocator.dupe(u8, c);
        n += 1;
    }
    return roots;
}

pub fn freeRoots(allocator: Allocator, roots: [][]const u8) void {
    for (roots) |r| allocator.free(r);
    allocator.free(roots);
}

// ---------------------------------------------------------------------------
// Profile enumeration
// ---------------------------------------------------------------------------

/// Prism instance dir marker (`<child>/instance.cfg`).
fn hasInstanceCfg(allocator: Allocator, io: anytype, dir_path: []const u8, name: []const u8) !bool {
    const cfg = try std.fs.path.join(allocator, &.{ dir_path, name, "instance.cfg" });
    defer allocator.free(cfg);
    return dirExists(io, cfg);
}

/// Counting pass for `listProfiles` (identical filtering to the fill pass).
fn countChildren(allocator: Allocator, io: anytype, kind: Kind, dir_path: []const u8) !usize {
    var d = try std.Io.Dir.openDirAbsolute(io, dir_path, .{ .iterate = true });
    defer d.close(io);
    var it = d.iterate(); // must be `var`: next() keeps a buffer inside `it`
    var n: usize = 0;
    while (try it.next(io)) |entry| {
        if (entry.kind != .directory) continue;
        if (kind == .prism and !(try hasInstanceCfg(allocator, io, dir_path, entry.name))) continue;
        n += 1;
    }
    return n;
}

/// The directory Minecraft runs from for one profile:
/// Modrinth → the profile dir itself; Prism → `minecraft/` if it exists, else
/// `.minecraft/` if it exists, else `minecraft/` (Prism's default, created on
/// the next refresh).
fn resolveGameDir(allocator: Allocator, io: anytype, kind: Kind, child: []const u8) ![]u8 {
    switch (kind) {
        .modrinth => return allocator.dupe(u8, child),
        .prism => {
            const minecraft = try std.fs.path.join(allocator, &.{ child, "minecraft" });
            if (dirExists(io, minecraft)) return minecraft;
            const dot = std.fs.path.join(allocator, &.{ child, ".minecraft" }) catch |err| {
                allocator.free(minecraft);
                return err;
            };
            if (dirExists(io, dot)) {
                allocator.free(minecraft);
                return dot;
            }
            allocator.free(dot);
            return minecraft;
        },
    }
}

/// Enumerate the profiles under one launcher `root`.
///
/// Prism: direct child dirs of `<root>/instances/` that contain an
/// `instance.cfg` marker. Modrinth: every direct child dir of
/// `<root>/profiles/` (no `mods/` required). Caller owns everything
/// (release with `freeProfiles`).
pub fn listProfiles(allocator: Allocator, kind: Kind, root: []const u8) ![]Profile {
    var threaded = makeThreaded();
    const io = threaded.io();

    const sub: []const u8 = switch (kind) {
        .prism => "instances",
        .modrinth => "profiles",
    };
    const dir_path = try std.fs.path.join(allocator, &.{ root, sub });
    defer allocator.free(dir_path);

    // Two passes over the directory: count, allocate exactly, fill. The fill
    // pass never writes past `profiles.len`; if the directory shrank between
    // passes (a launcher writing concurrently), the tail is trimmed with a
    // shrinking realloc.
    const count = try countChildren(allocator, io, kind, dir_path);
    const profiles = try allocator.alloc(Profile, count);
    errdefer allocator.free(profiles);
    var filled: usize = 0;
    errdefer {
        for (profiles[0..filled]) |p| freeProfile(allocator, p);
    }

    var d = try std.Io.Dir.openDirAbsolute(io, dir_path, .{ .iterate = true });
    defer d.close(io);

    var it = d.iterate(); // must be `var`: next() keeps a buffer inside `it`
    while (try it.next(io)) |entry| {
        if (entry.kind != .directory) continue;
        if (kind == .prism and !(try hasInstanceCfg(allocator, io, dir_path, entry.name))) continue;
        if (filled == profiles.len) break; // dir grew between passes: ignore extras

        const child = try std.fs.path.join(allocator, &.{ dir_path, entry.name });
        defer allocator.free(child);

        const name = try allocator.dupe(u8, entry.name);
        errdefer allocator.free(name);
        const root_owned = try allocator.dupe(u8, root);
        errdefer allocator.free(root_owned);
        const game_dir = try resolveGameDir(allocator, io, kind, child);
        errdefer allocator.free(game_dir);

        profiles[filled] = .{
            .kind = kind,
            .name = name,
            .gameDir = game_dir,
            .root = root_owned,
        };
        filled += 1;
    }

    if (filled == profiles.len) return profiles;
    return allocator.realloc(profiles, filled);
}

fn freeProfile(allocator: Allocator, p: Profile) void {
    allocator.free(p.name);
    allocator.free(p.gameDir);
    allocator.free(p.root);
}

pub fn freeProfiles(allocator: Allocator, profiles: []Profile) void {
    for (profiles) |p| freeProfile(allocator, p);
    allocator.free(profiles);
}

// ---------------------------------------------------------------------------
// Combined discovery
// ---------------------------------------------------------------------------

/// Every profile of every kind from every root that exists on this machine.
/// A root that exists but can't be read (e.g. permission denied) is recorded
/// in `errors` — one bad root never aborts the scan (decision D5). Caller
/// owns everything (release with `freeDiscovery`).
pub fn discoverAll(allocator: Allocator) !Discovery {
    const prism_roots = try findRoots(allocator, .prism);
    defer freeRoots(allocator, prism_roots);
    const modrinth_roots = try findRoots(allocator, .modrinth);
    defer freeRoots(allocator, modrinth_roots);

    // Per-root profile slices. findRoots produces at most 2 prism candidates
    // and 3 modrinth candidates, so 8 comfortably bounds both buffers.
    var pair_profiles: [8][]Profile = undefined;
    var n_pairs: usize = 0;
    var err_paths: [8][]const u8 = undefined;
    var n_err: usize = 0;
    // Until ownership is transferred below, each pair still owns its strings
    // and each collected error path is still owned here.
    errdefer {
        for (pair_profiles[0..n_pairs]) |p| freeProfiles(allocator, p);
        for (err_paths[0..n_err]) |e| allocator.free(e);
    }

    const scans = [_]struct { kind: Kind, roots: [][]const u8 }{
        .{ .kind = .prism, .roots = prism_roots },
        .{ .kind = .modrinth, .roots = modrinth_roots },
    };
    for (scans) |scan| {
        for (scan.roots) |root| {
            // D5: an unreadable root is recorded, never fatal.
            const profiles = listProfiles(allocator, scan.kind, root) catch {
                err_paths[n_err] = try allocator.dupe(u8, root);
                n_err += 1;
                continue;
            };
            pair_profiles[n_pairs] = profiles;
            n_pairs += 1;
        }
    }

    var total: usize = 0;
    for (pair_profiles[0..n_pairs]) |p| total += p.len;

    // Errors: move the collected paths into an exactly-sized slice.
    const errors = try allocator.alloc([]const u8, n_err);
    errdefer {
        for (errors) |e| allocator.free(e);
        allocator.free(errors);
    }
    for (err_paths[0..n_err], errors) |src, *dst| dst.* = src;
    n_err = 0; // ownership moved; the first errdefer must not free them

    // Profiles: copy the structs, transferring string ownership into one
    // contiguous slice, then drop the (now string-less) pair slices.
    const merged = try allocator.alloc(Profile, total);
    var at: usize = 0;
    for (pair_profiles[0..n_pairs]) |p| {
        for (p) |profile| {
            merged[at] = profile;
            at += 1;
        }
        allocator.free(p);
    }
    n_pairs = 0; // string ownership now lives in `merged`

    return .{ .profiles = merged, .errors = errors };
}

pub fn freeDiscovery(allocator: Allocator, d: Discovery) void {
    freeProfiles(allocator, d.profiles);
    for (d.errors) |e| allocator.free(e);
    allocator.free(d.errors);
}

// ---------------------------------------------------------------------------
// Hermetic test fixtures: per-test trees under /tmp/modsync-launcher-test/.
// Each test owns a distinct subtree so setup/teardown never races.
// ---------------------------------------------------------------------------

const test_root = "/tmp/modsync-launcher-test";

/// Best-effort recursive removal of a fixture tree (idempotent: a missing
/// path is not an error).
fn removeTestTree(io: anytype, path: []const u8) void {
    std.Io.Dir.cwd().deleteTree(io, path) catch {};
}

/// `createDirPath` errors with NotDir when the dir already exists (see
/// config.zig's saveTo), so probe with `access` first.
fn ensureTestDir(io: anytype, path: []const u8) !void {
    std.Io.Dir.cwd().access(io, path, .{}) catch {
        try std.Io.Dir.cwd().createDirPath(io, path);
    };
}

fn writeTestFile(io: anytype, path: []const u8, data: []const u8) !void {
    if (std.mem.lastIndexOfScalar(u8, path, '/')) |i| {
        try ensureTestDir(io, path[0..i]);
    }
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = data });
}

fn findProfile(profiles: []const Profile, name: []const u8) ?*const Profile {
    for (profiles) |*p| {
        if (std.mem.eql(u8, p.name, name)) return p;
    }
    return null;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "listProfiles(.prism) returns only child dirs containing instance.cfg" {
    const a = std.testing.allocator;
    var threaded = std.Io.Threaded.init(std.heap.page_allocator, .{});
    const io = threaded.io();
    const root = test_root ++ "/prism-basic";

    removeTestTree(io, root);
    defer removeTestTree(io, root);

    try ensureTestDir(io, root ++ "/instances/A");
    try writeTestFile(io, root ++ "/instances/A/instance.cfg", "InstanceType=OneSix\n");
    try ensureTestDir(io, root ++ "/instances/B"); // no instance.cfg → skipped

    const profiles = try listProfiles(a, .prism, root);
    defer freeProfiles(a, profiles);

    try std.testing.expectEqual(@as(usize, 1), profiles.len);
    const p = profiles[0];
    try std.testing.expectEqual(Kind.prism, p.kind);
    try std.testing.expectEqualStrings("A", p.name);
    try std.testing.expectEqualStrings(root, p.root);

    // No minecraft/ or .minecraft/ existed → default `<child>/minecraft`.
    const want = try std.fs.path.join(a, &.{ root, "instances", "A", "minecraft" });
    defer a.free(want);
    try std.testing.expectEqualStrings(want, p.gameDir);
}

test "listProfiles(.prism) gameDir prefers .minecraft, then minecraft, then default" {
    const a = std.testing.allocator;
    var threaded = std.Io.Threaded.init(std.heap.page_allocator, .{});
    const io = threaded.io();
    const root = test_root ++ "/prism-gamedir";

    removeTestTree(io, root);
    defer removeTestTree(io, root);

    try ensureTestDir(io, root ++ "/instances/C/.minecraft");
    try writeTestFile(io, root ++ "/instances/C/instance.cfg", "InstanceType=OneSix\n");
    try ensureTestDir(io, root ++ "/instances/D/minecraft");
    try writeTestFile(io, root ++ "/instances/D/instance.cfg", "InstanceType=OneSix\n");

    const profiles = try listProfiles(a, .prism, root);
    defer freeProfiles(a, profiles);
    try std.testing.expectEqual(@as(usize, 2), profiles.len);

    const c = findProfile(profiles, "C");
    try std.testing.expect(c != null);
    const c_want = try std.fs.path.join(a, &.{ root, "instances", "C", ".minecraft" });
    defer a.free(c_want);
    try std.testing.expectEqualStrings(c_want, c.?.gameDir);

    const d = findProfile(profiles, "D");
    try std.testing.expect(d != null);
    const d_want = try std.fs.path.join(a, &.{ root, "instances", "D", "minecraft" });
    defer a.free(d_want);
    try std.testing.expectEqualStrings(d_want, d.?.gameDir);
}

test "listProfiles(.modrinth) lists every profile dir; mods/ is not required" {
    const a = std.testing.allocator;
    var threaded = std.Io.Threaded.init(std.heap.page_allocator, .{});
    const io = threaded.io();
    const root = test_root ++ "/modrinth-basic";

    removeTestTree(io, root);
    defer removeTestTree(io, root);

    try ensureTestDir(io, root ++ "/profiles/Alpha"); // empty, no mods/
    try ensureTestDir(io, root ++ "/profiles/Beta/mods");

    const profiles = try listProfiles(a, .modrinth, root);
    defer freeProfiles(a, profiles);
    try std.testing.expectEqual(@as(usize, 2), profiles.len);

    const alpha = findProfile(profiles, "Alpha");
    try std.testing.expect(alpha != null);
    try std.testing.expectEqual(Kind.modrinth, alpha.?.kind);
    const alpha_want = try std.fs.path.join(a, &.{ root, "profiles", "Alpha" });
    defer a.free(alpha_want);
    try std.testing.expectEqualStrings(alpha_want, alpha.?.gameDir);

    const beta = findProfile(profiles, "Beta");
    try std.testing.expect(beta != null);
    const beta_want = try std.fs.path.join(a, &.{ root, "profiles", "Beta" });
    defer a.free(beta_want);
    try std.testing.expectEqualStrings(beta_want, beta.?.gameDir);
}

test "findRoots(.modrinth) does not error and returns a slice" {
    const roots = try findRoots(std.testing.allocator, .modrinth);
    defer freeRoots(std.testing.allocator, roots);
    // Contents are machine-dependent — only exercise the call + free path.
    _ = roots.len;
}

test "discoverAll produces a Discovery that freeDiscovery releases completely" {
    const d = try discoverAll(std.testing.allocator);
    defer freeDiscovery(std.testing.allocator, d);
    _ = d.profiles.len;
    _ = d.errors.len;
}
