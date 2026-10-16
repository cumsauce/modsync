//! Mods-folder install operations: locate the `mods` dir (expanding a `~`
//! minecraftDir against $HOME), create it, find stale `{repoName}-*.jar`
//! files, and move a freshly downloaded jar into place.
const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

/// A Threaded Io instance seeded with the real process environment so that
/// `environString` works (same pattern as config.zig's makeThreaded — the
/// default InitOptions.environ is `.empty`, which makes environString always
/// return null).
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

/// Expand a leading `~` to `$HOME` (config.defaultMinecraftDir returns a
/// `~`-literal). Any other path is duped as-is. Caller owns.
fn expandHome(allocator: Allocator, path: []const u8) ![]u8 {
    if (path.len == 0 or path[0] != '~') return try allocator.dupe(u8, path);
    var threaded = makeThreaded();
    const home = threaded.environString("HOME") orelse return error.NoHomeDirectory;
    var rest = path[1..];
    if (rest.len > 0 and (rest[0] == '/' or rest[0] == '\\')) rest = rest[1..];
    if (rest.len == 0) return try allocator.dupe(u8, home);
    return try std.fs.path.join(allocator, &.{ home, rest });
}

/// Absolute `{minecraftDir}/mods` path, expanding a leading `~` against
/// $HOME. Caller owns the returned slice.
pub fn modsDir(allocator: Allocator, minecraftDir: []const u8) ![]const u8 {
    const base = try expandHome(allocator, minecraftDir);
    defer allocator.free(base);
    return try std.fs.path.join(allocator, &.{ base, "mods" });
}

/// Create `{minecraftDir}/mods` (and its parents) if missing; no-op when
/// already present.
pub fn ensureModsDir(minecraftDir: []const u8) !void {
    var threaded = makeThreaded();
    const io = threaded.io();

    const dir = try modsDir(std.heap.page_allocator, minecraftDir);
    defer std.heap.page_allocator.free(dir);

    // Probe first: an existing dir (even a symlinked one like macOS /tmp)
    // makes createDirPath return NotDir.
    std.Io.Dir.cwd().access(io, dir, .{}) catch {
        try std.Io.Dir.cwd().createDirPath(io, dir);
    };
}

/// Names in `modsDirPath` matching the glob `{repoName}-*.jar` except
/// `keepJar` (the jar we are about to install). Caller owns each returned
/// name and the slice.
pub fn staleJarNames(allocator: Allocator, modsDirPath: []const u8, repoName: []const u8, keepJar: []const u8) ![][]const u8 {
    var threaded = makeThreaded();
    const io = threaded.io();

    var d = try std.Io.Dir.openDirAbsolute(io, modsDirPath, .{ .iterate = true });
    defer d.close(io);

    var names: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (names.items) |n| allocator.free(n);
        names.deinit(allocator);
    }

    var it = d.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file) continue;
        const name = entry.name;
        if (name.len <= repoName.len) continue;
        if (!std.mem.startsWith(u8, name, repoName)) continue;
        if (name[repoName.len] != '-') continue;
        if (!std.mem.endsWith(u8, name, ".jar")) continue;
        if (std.mem.eql(u8, name, keepJar)) continue;
        try names.append(allocator, try allocator.dupe(u8, name));
    }
    return try names.toOwnedSlice(allocator);
}

/// Move `tmpPath` into `modsDirPath/jarName`. Prefers an atomic rename;
/// falls back to copy+delete when rename fails (e.g. cross-device: macOS
/// /tmp lives on a different volume than $HOME).
pub fn placeJar(modsDirPath: []const u8, tmpPath: []const u8, jarName: []const u8) !void {
    var threaded = makeThreaded();
    const io = threaded.io();

    const dest = try std.fs.path.join(std.heap.page_allocator, &.{ modsDirPath, jarName });
    defer std.heap.page_allocator.free(dest);

    std.Io.Dir.renameAbsolute(tmpPath, dest, io) catch {
        const bytes = try std.Io.Dir.cwd().readFileAlloc(io, tmpPath, std.heap.page_allocator, .unlimited);
        defer std.heap.page_allocator.free(bytes);
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = dest, .data = bytes });
        try std.Io.Dir.deleteFileAbsolute(io, tmpPath);
    };
}

// ---------------------------------------------------------------------------
// Tests (real temp dirs under /tmp)
// ---------------------------------------------------------------------------

test "modsDir appends /mods to a literal path and expands a leading ~" {
    const a = std.testing.allocator;

    const p = try modsDir(a, "/tmp/mc");
    defer a.free(p);
    try std.testing.expectEqualStrings("/tmp/mc/mods", p);

    const t = try modsDir(a, "~/some/mc");
    defer a.free(t);
    try std.testing.expect(std.mem.startsWith(u8, t, "/"));
    try std.testing.expect(std.mem.endsWith(u8, t, "/mods"));
}

test "ensureModsDir creates a missing mods dir and is a no-op when present" {
    var threaded = std.Io.Threaded.init(std.heap.page_allocator, .{});
    const io = threaded.io();

    const root = "/tmp/modsync-task4-ensure";
    const base = "/tmp/modsync-task4-ensure/mc";
    std.Io.Dir.cwd().deleteTree(io, root) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};

    const dir = try modsDir(std.testing.allocator, base);
    defer std.testing.allocator.free(dir);

    try ensureModsDir(base);
    std.Io.Dir.cwd().access(io, dir, .{}) catch return error.ExpectedModsDirToExist;

    // Second call: dir already present -> no-op, no error.
    try ensureModsDir(base);
    std.Io.Dir.cwd().access(io, dir, .{}) catch return error.ExpectedModsDirToStillExist;
}

test "staleJarNames returns exactly the older {repoName}- jars" {
    var threaded = std.Io.Threaded.init(std.heap.page_allocator, .{});
    const io = threaded.io();

    const root = "/tmp/modsync-task4-stale";
    const base = "/tmp/modsync-task4-stale/mc";
    std.Io.Dir.cwd().deleteTree(io, root) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};

    try ensureModsDir(base);

    const dir = try modsDir(std.testing.allocator, base);
    defer std.testing.allocator.free(dir);

    const files = [_][]const u8{ "gore-0.1.1.jar", "gore-0.1.2.jar", "unrelated.jar", "notes.txt" };
    for (files) |f| {
        const p = try std.fs.path.join(std.testing.allocator, &.{ dir, f });
        defer std.testing.allocator.free(p);
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = p, .data = "jar-bytes" });
    }

    const stale = try staleJarNames(std.testing.allocator, dir, "gore", "gore-0.1.2.jar");
    defer {
        for (stale) |n| std.testing.allocator.free(n);
        std.testing.allocator.free(stale);
    }

    // Exactly ["gore-0.1.1.jar"]: the kept jar, unrelated.jar and notes.txt
    // must never be returned.
    try std.testing.expectEqual(@as(usize, 1), stale.len);
    try std.testing.expectEqualStrings("gore-0.1.1.jar", stale[0]);
}

test "placeJar moves the tmp jar into mods/ and removes the tmp file" {
    var threaded = std.Io.Threaded.init(std.heap.page_allocator, .{});
    const io = threaded.io();

    const root = "/tmp/modsync-task4-place";
    const base = "/tmp/modsync-task4-place/mc";
    std.Io.Dir.cwd().deleteTree(io, root) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};

    try ensureModsDir(base);
    const dir = try modsDir(std.testing.allocator, base);
    defer std.testing.allocator.free(dir);

    try std.Io.Dir.cwd().createDirPath(io, "/tmp/modsync-task4-place/tmp");
    const tmp_path = "/tmp/modsync-task4-place/tmp/gore-0.1.2.jar.tmp";
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = tmp_path, .data = "fake jar bytes v0.1.2" });

    const dest = try std.fs.path.join(std.testing.allocator, &.{ dir, "gore-0.1.2.jar" });
    defer std.testing.allocator.free(dest);

    try placeJar(dir, tmp_path, "gore-0.1.2.jar");

    std.Io.Dir.cwd().access(io, dest, .{}) catch return error.ExpectedJarInModsDir;
    const tmp_still_there = blk: {
        std.Io.Dir.cwd().access(io, tmp_path, .{}) catch break :blk false;
        break :blk true;
    };
    try std.testing.expect(!tmp_still_there);
}
