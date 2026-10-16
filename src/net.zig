const std = @import("std");
const github = @import("github.zig");

// ============================================================================
// Types consumed by Task 6 (app wiring), which owns the std.http.Client.
// ============================================================================

pub const FetchedMod = struct {
    tag: []const u8,
    jarName: []const u8,
    jarSize: u64,
};

pub const FetchError = error{
    /// GitHub returned no releases, or every release was a draft.
    NoReleases,
    /// The selected release has no asset that qualifies as a client jar.
    NoJarAsset,
    /// Non-2xx HTTP status (or a redirect loop beyond the allowed budget).
    Http,
    /// The releases response body was not parseable JSON.
    InvalidPayload,
} || std.mem.Allocator.Error || std.http.Client.FetchError;

/// GET the newest (first non-draft) release of `{owner}/{repo}` and select its
/// client jar. Returns null only via error.NoReleases/NoJarAsset — the `?` in
/// the return type is kept for signature stability with the brief.
///
/// On success the caller owns `tag` and `jarName` (freed with
/// `allocator.free`); the FetchedMod itself needs no deinit.
pub fn fetchLatest(
    allocator: std.mem.Allocator,
    client: *std.http.Client,
    owner: []const u8,
    repo: []const u8,
    token: ?[]const u8,
) FetchError!?FetchedMod {
    const url = try std.fmt.allocPrint(
        allocator,
        "https://api.github.com/repos/{s}/{s}/releases?per_page=100",
        .{ owner, repo },
    );
    defer allocator.free(url);

    // "Bearer {token}" must stay alive across the fetch call.
    var bearer: ?[]const u8 = null;
    defer if (bearer) |b| allocator.free(b);

    var extra: [2]std.http.Header = undefined;
    var extra_len: usize = 0;
    if (token) |t| {
        bearer = try std.fmt.allocPrint(allocator, "Bearer {s}", .{t});
        extra[extra_len] = .{ .name = "Authorization", .value = bearer.? };
        extra_len += 1;
    }
    // GitHub's REST API versioning header.
    extra[extra_len] = .{ .name = "Accept", .value = "application/vnd.github+json" };
    extra_len += 1;

    var body = std.Io.Writer.Allocating.init(allocator);
    defer body.deinit();

    const result = try client.fetch(.{
        .location = .{ .url = url },
        .method = .GET,
        .response_writer = &body.writer,
        .headers = .{ .user_agent = .{ .override = "modsync" } },
        .extra_headers = extra[0..extra_len],
        .redirect_behavior = .init(5),
    });
    if (result.status.class() != .success) return error.Http;

    return chooseFromReleases(allocator, body.writer.buffered(), repo);
}

/// GET `url` (following up to 5 redirects — GitHub asset URLs 302 to a CDN)
/// and write the response body to `destTmpPath`.
pub fn downloadJar(
    allocator: std.mem.Allocator,
    client: *std.http.Client,
    url: []const u8,
    destTmpPath: []const u8,
    token: ?[]const u8,
) !void {
    var bearer: ?[]const u8 = null;
    defer if (bearer) |b| allocator.free(b);

    var extra: [1]std.http.Header = undefined;
    var extra_len: usize = 0;
    if (token) |t| {
        bearer = try std.fmt.allocPrint(allocator, "Bearer {s}", .{t});
        extra[extra_len] = .{ .name = "Authorization", .value = bearer.? };
        extra_len += 1;
    }

    var body = std.Io.Writer.Allocating.init(allocator);
    defer body.deinit();

    const result = try client.fetch(.{
        .location = .{ .url = url },
        .method = .GET,
        .response_writer = &body.writer,
        .headers = .{ .user_agent = .{ .override = "modsync" } },
        .extra_headers = extra[0..extra_len],
        .redirect_behavior = .init(5),
    });
    if (result.status.class() != .success) return error.Http;

    try std.Io.Dir.cwd().writeFile(client.io, .{
        .sub_path = destTmpPath,
        .data = body.writer.buffered(),
    });
}

/// Pure composition of Task 3: parse → select release → select jar → dupes.
/// Split out so the selection logic is unit-testable without a network.
/// Returned strings are caller-owned; the release list is freed before return.
fn chooseFromReleases(allocator: std.mem.Allocator, json: []const u8, repo: []const u8) FetchError!?FetchedMod {
    const releases = github.parseReleases(allocator, json) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidPayload,
    };
    defer github.freeReleases(allocator, releases);

    const rel = github.selectRelease(releases) orelse return error.NoReleases;
    const asset = (try github.selectJarAsset(allocator, rel.assets, repo)) orelse return error.NoJarAsset;

    const tag = try allocator.dupe(u8, rel.tag);
    errdefer allocator.free(tag);
    const jar_name = try allocator.dupe(u8, asset.name);
    errdefer allocator.free(jar_name);

    return .{ .tag = tag, .jarName = jar_name, .jarSize = asset.size };
}

// ============================================================================
// Offline tests — exercise the pure composition only (no network).
// ============================================================================

const gore_fixture =
    \\[{"tag_name":"v0.1.2","draft":false,"prerelease":false,"assets":[{"name":"gore-0.1.2.jar","size":12345,"browser_download_url":"https://example/gore-0.1.2.jar"}]}]
;

const nojar_fixture =
    \\[{"tag_name":"v1.0.0","draft":false,"prerelease":false,"assets":[
    \\{"name":"SHA256SUMS","size":10,"browser_download_url":"https://example/SHA256SUMS"},
    \\{"name":"notes.txt","size":5,"browser_download_url":"https://example/notes.txt"}]}]
;

test "chooseFromReleases: gore fixture yields tag + jarName + size" {
    const got = (try chooseFromReleases(std.testing.allocator, gore_fixture, "gore")).?;
    defer std.testing.allocator.free(got.tag);
    defer std.testing.allocator.free(got.jarName);

    try std.testing.expectEqualStrings("v0.1.2", got.tag);
    try std.testing.expectEqualStrings("gore-0.1.2.jar", got.jarName);
    try std.testing.expectEqual(@as(u64, 12345), got.jarSize);
}

test "chooseFromReleases: release without a qualifying jar → error.NoJarAsset" {
    try std.testing.expectError(
        error.NoJarAsset,
        chooseFromReleases(std.testing.allocator, nojar_fixture, "gore"),
    );
}

test "chooseFromReleases: empty releases list → error.NoReleases" {
    try std.testing.expectError(
        error.NoReleases,
        chooseFromReleases(std.testing.allocator, "[]", "gore"),
    );
}
