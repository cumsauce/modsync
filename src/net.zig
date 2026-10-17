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

/// UI-facing failure taxonomy for the staged update pipeline (Phase 1).
///
/// These values are deliberately coarser than `FetchError`: app.zig maps each
/// one to an exact user-facing string, so the distinction between, say, a TLS
/// failure and a DNS failure does not belong here. `RateLimited` cannot carry
/// a payload (Zig error sets cannot), so the server's `X-RateLimit-Reset`
/// epoch is reported through `fetchLatestReleaseDetailed`'s `rate_reset_out`.
pub const ReleaseError = error{
    /// 404 from the GitHub API: wrong owner/name, private, or deleted repo.
    NotFound,
    /// 403/429 from the GitHub API, including secondary/abuse limits.
    RateLimited,
    /// Connection, DNS, TLS, timeout, or an unexpected non-2xx response.
    Offline,
    /// A release exists, but none of its assets qualifies as a client `.jar`.
    NoCompatibleJar,
    /// The selected asset URL could not be fetched or written to disk.
    DownloadFailed,
    /// The releases response body was not parseable release JSON.
    InvalidPayload,
} || std.mem.Allocator.Error;

/// Result of `classifyStatus`; `rate_limited` carries the parsed reset epoch.
pub const StatusClass = union(enum) {
    ok,
    not_found,
    rate_limited: ?i64,
    unexpected,
};

/// Pure HTTP-status classifier for the releases endpoint.
///
/// 2xx → `ok`, 404 → `not_found`, 403/429 → `rate_limited` (with the
/// `X-RateLimit-Reset` epoch threaded through), everything else
/// (401, 5xx, …) → `unexpected`, which callers map to their connectivity copy.
pub fn classifyStatus(code: u16, rate_reset: ?i64) StatusClass {
    if (code >= 200 and code < 300) return .ok;
    if (code == 404) return .not_found;
    if (code == 403 or code == 429) return .{ .rate_limited = rate_reset };
    return .unexpected;
}

/// Extract the epoch-seconds value of `X-RateLimit-Reset` from raw HTTP head
/// bytes. Pure and case-insensitive; null when the header is absent or not an
/// integer.
pub fn parseRateLimitReset(head_bytes: []const u8) ?i64 {
    var lines = std.mem.splitSequence(u8, head_bytes, "\r\n");
    _ = lines.next(); // status line
    while (lines.next()) |line| {
        if (line.len == 0) break;
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const name = std.mem.trim(u8, line[0..colon], " \t");
        if (!std.ascii.eqlIgnoreCase(name, "x-ratelimit-reset")) continue;
        const value = std.mem.trim(u8, line[colon + 1 ..], " \t");
        return std.fmt.parseInt(i64, value, 10) catch null;
    }
    return null;
}

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
    const json = try fetchReleasesJson(allocator, client, owner, repo, token);
    defer allocator.free(json);

    return chooseFromReleases(allocator, json, repo);
}

/// A selected jar asset including its `browser_download_url`.
pub const FetchedAsset = struct {
    tag: []const u8,
    name: []const u8,
    size: u64,
    /// `browser_download_url` of the selected asset — pass straight to `downloadJar`.
    url: []const u8,
};

/// Like `fetchLatest`, but also returns the selected asset's
/// `browser_download_url` so the caller can hand it straight to `downloadJar`.
/// Additive companion to `fetchLatest` (which does not expose the URL);
/// ownership rules are the same — caller frees `tag`, `name`, and `url` with
/// the allocator. Returns null only via error.NoReleases/NoJarAsset, matching
/// `fetchLatest`.
pub fn fetchLatestAsset(
    allocator: std.mem.Allocator,
    client: *std.http.Client,
    owner: []const u8,
    repo: []const u8,
    token: ?[]const u8,
) FetchError!?FetchedAsset {
    const json = try fetchReleasesJson(allocator, client, owner, repo, token);
    defer allocator.free(json);

    return chooseAssetFromReleases(allocator, json, repo);
}

/// Like `fetchLatestAsset`, but classifies every failure into the UI-facing
/// `ReleaseError` taxonomy and reports the rate-limit reset epoch.
///
/// On success the caller owns `tag`, `name`, and `url` (free with the same
/// allocator). On `error.RateLimited`, `rate_reset_out` (when supplied) is set
/// to the epoch from `X-RateLimit-Reset`, or null when the header was absent.
/// The out-parameter is always cleared on entry, so it is meaningful only
/// after a `RateLimited` return.
///
/// Additive: `fetchLatestAsset` remains the unclassified path used by the
/// existing refresh worker.
pub fn fetchLatestReleaseDetailed(
    allocator: std.mem.Allocator,
    client: *std.http.Client,
    owner: []const u8,
    repo: []const u8,
    token: ?[]const u8,
    rate_reset_out: ?*?i64,
) ReleaseError!FetchedAsset {
    if (rate_reset_out) |out| out.* = null;

    const response = try requestReleaseResponse(allocator, client, owner, repo, token);
    defer allocator.free(response.body);

    switch (classifyStatus(response.status, response.rate_reset)) {
        .ok => {},
        .not_found => return error.NotFound,
        .rate_limited => |reset| {
            if (rate_reset_out) |out| out.* = reset;
            return error.RateLimited;
        },
        .unexpected => return error.Offline,
    }

    return chooseAssetDetailed(allocator, response.body, repo);
}

/// GET the releases list of `{owner}/{repo}` and return the raw response body
/// (caller frees). Shared by `fetchLatest` and `fetchLatestAsset`.
fn fetchReleasesJson(
    allocator: std.mem.Allocator,
    client: *std.http.Client,
    owner: []const u8,
    repo: []const u8,
    token: ?[]const u8,
) FetchError![]u8 {
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

    return try allocator.dupe(u8, body.writer.buffered());
}

/// Raw releases response: status code, body, and the rate-limit reset epoch.
const RawResponse = struct {
    status: u16,
    body: []u8,
    rate_reset: ?i64,
};

/// GET the releases list with response headers intact.
///
/// `client.fetch` (used by `fetchReleasesJson`) discards headers, but the
/// detailed path needs `X-RateLimit-Reset`; this uses the lower-level request
/// API for exactly that. Identity encoding is forced so the body can be
/// streamed without a decompressor buffer.
fn requestReleaseResponse(
    allocator: std.mem.Allocator,
    client: *std.http.Client,
    owner: []const u8,
    repo: []const u8,
    token: ?[]const u8,
) ReleaseError!RawResponse {
    const url = std.fmt.allocPrint(
        allocator,
        "https://api.github.com/repos/{s}/{s}/releases?per_page=100",
        .{ owner, repo },
    ) catch |err| return err;
    defer allocator.free(url);

    const uri = std.Uri.parse(url) catch return error.Offline;

    // "Bearer {token}" must stay alive across the request.
    var bearer: ?[]const u8 = null;
    defer if (bearer) |b| allocator.free(b);

    var extra: [2]std.http.Header = undefined;
    var extra_len: usize = 0;
    if (token) |t| {
        bearer = std.fmt.allocPrint(allocator, "Bearer {s}", .{t}) catch |err| return err;
        extra[extra_len] = .{ .name = "Authorization", .value = bearer.? };
        extra_len += 1;
    }
    extra[extra_len] = .{ .name = "Accept", .value = "application/vnd.github+json" };
    extra_len += 1;

    var req = client.request(.GET, uri, .{
        .redirect_behavior = .init(5),
        .headers = .{
            .user_agent = .{ .override = "modsync" },
            .accept_encoding = .{ .override = "identity" },
        },
        .extra_headers = extra[0..extra_len],
    }) catch |err| return mapNetworkError(err);
    defer req.deinit();

    req.sendBodiless() catch |err| return mapNetworkError(err);

    // Same budget as `client.fetch` uses for redirects.
    var redirect_buffer: [8 * 1024]u8 = undefined;
    var response = req.receiveHead(&redirect_buffer) catch |err| return mapNetworkError(err);

    // `response.reader` invalidates `head.bytes`, so read headers first.
    const rate_reset = parseRateLimitReset(response.head.bytes);
    const status: u16 = @backingInt(response.head.status);

    var body = std.Io.Writer.Allocating.init(allocator);
    defer body.deinit();
    var transfer_buffer: [64]u8 = undefined;
    const reader = response.reader(&transfer_buffer);
    _ = reader.streamRemaining(&body.writer) catch |err| return mapNetworkError(err);

    const bytes = allocator.dupe(u8, body.writer.buffered()) catch |err| return err;
    return .{ .status = status, .body = bytes, .rate_reset = rate_reset };
}

/// Collapse the many transport failures into the two values app.zig cares
/// about, while never swallowing an allocation failure.
fn mapNetworkError(err: anyerror) ReleaseError {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.Offline,
    };
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

/// `downloadJar` with the UI-facing classification: every transport/status
/// failure becomes `DownloadFailed`, allocation failure stays `OutOfMemory`.
/// The destination-is-temporary contract is unchanged.
pub fn downloadJarDetailed(
    allocator: std.mem.Allocator,
    client: *std.http.Client,
    url: []const u8,
    destTmpPath: []const u8,
    token: ?[]const u8,
) ReleaseError!void {
    downloadJar(allocator, client, url, destTmpPath, token) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.DownloadFailed,
    };
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

/// Pure selection for `fetchLatestAsset`: parse → select release → select jar
/// → dupes (including the asset's `browser_download_url`). Caller-owned output.
fn chooseAssetFromReleases(allocator: std.mem.Allocator, json: []const u8, repo: []const u8) FetchError!?FetchedAsset {
    const releases = github.parseReleases(allocator, json) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidPayload,
    };
    defer github.freeReleases(allocator, releases);

    const rel = github.selectRelease(releases) orelse return error.NoReleases;
    const asset = (try github.selectJarAsset(allocator, rel.assets, repo)) orelse return error.NoJarAsset;

    const tag = try allocator.dupe(u8, rel.tag);
    errdefer allocator.free(tag);
    const name = try allocator.dupe(u8, asset.name);
    errdefer allocator.free(name);
    const url = try allocator.dupe(u8, asset.browserDownloadUrl);
    errdefer allocator.free(url);

    return .{ .tag = tag, .name = name, .size = asset.size, .url = url };
}

/// Detailed-path selection: same parse → release → jar pipeline as
/// `chooseAssetFromReleases`, but empty release lists and releases without a
/// qualifying `.jar` collapse to `error.NoCompatibleJar` so the UI can say
/// "No compatible .jar release found for this install." instead of exposing
/// GitHub internals.
fn chooseAssetDetailed(allocator: std.mem.Allocator, json: []const u8, repo: []const u8) ReleaseError!FetchedAsset {
    const releases = github.parseReleases(allocator, json) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidPayload,
    };
    defer github.freeReleases(allocator, releases);

    const rel = github.selectRelease(releases) orelse return error.NoCompatibleJar;
    // `selectJarAsset` is allocation-free today; the catch only exists to keep
    // this helper's error set closed.
    const asset = (github.selectJarAsset(allocator, rel.assets, repo) catch return error.NoCompatibleJar) orelse
        return error.NoCompatibleJar;

    const tag = try allocator.dupe(u8, rel.tag);
    errdefer allocator.free(tag);
    const name = try allocator.dupe(u8, asset.name);
    errdefer allocator.free(name);
    const url = try allocator.dupe(u8, asset.browserDownloadUrl);
    errdefer allocator.free(url);

    return .{ .tag = tag, .name = name, .size = asset.size, .url = url };
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

test "chooseAssetFromReleases: gore fixture yields tag + name + size + url" {
    const got = (try chooseAssetFromReleases(std.testing.allocator, gore_fixture, "gore")).?;
    defer std.testing.allocator.free(got.tag);
    defer std.testing.allocator.free(got.name);
    defer std.testing.allocator.free(got.url);

    try std.testing.expectEqualStrings("v0.1.2", got.tag);
    try std.testing.expectEqualStrings("gore-0.1.2.jar", got.name);
    try std.testing.expectEqual(@as(u64, 12345), got.size);
    try std.testing.expectEqualStrings("https://example/gore-0.1.2.jar", got.url);
}

test "chooseAssetFromReleases: release without a qualifying jar → error.NoJarAsset" {
    try std.testing.expectError(
        error.NoJarAsset,
        chooseAssetFromReleases(std.testing.allocator, nojar_fixture, "gore"),
    );
}

// ============================================================================
// Phase 1 error taxonomy — pure classification and `.jar` scan tests.
// ============================================================================

const excludedjar_fixture =
    \\[{"tag_name":"v1.0.0","draft":false,"prerelease":false,"assets":[
    \\{"name":"tool-cli.jar","size":10,"browser_download_url":"https://example/tool-cli.jar"},
    \\{"name":"tool-server.jar","size":20,"browser_download_url":"https://example/tool-server.jar"}]}]
;

fn expectClass(expected: StatusClass, actual: StatusClass) !void {
    try std.testing.expectEqual(std.meta.activeTag(expected), std.meta.activeTag(actual));
    switch (expected) {
        .rate_limited => |expected_reset| {
            const actual_reset = switch (actual) {
                .rate_limited => |reset| reset,
                else => unreachable,
            };
            try std.testing.expectEqual(expected_reset, actual_reset);
        },
        else => {},
    }
}

test "classifyStatus: 2xx is ok" {
    try expectClass(.ok, classifyStatus(200, null));
    try expectClass(.ok, classifyStatus(204, 1_700_000_000));
}

test "classifyStatus: 404 is not_found" {
    try expectClass(.not_found, classifyStatus(404, null));
}

test "classifyStatus: 403/429 is rate_limited and keeps the reset epoch" {
    try expectClass(.{ .rate_limited = 1_700_000_000 }, classifyStatus(403, 1_700_000_000));
    try expectClass(.{ .rate_limited = null }, classifyStatus(429, null));
}

test "classifyStatus: 401/5xx are unexpected" {
    try expectClass(.unexpected, classifyStatus(401, null));
    try expectClass(.unexpected, classifyStatus(500, null));
    try expectClass(.unexpected, classifyStatus(0, null));
}

test "parseRateLimitReset: reads the epoch case-insensitively" {
    const head = "HTTP/1.1 403 Forbidden\r\n" ++
        "Server: github.com\r\n" ++
        "x-ratelimit-reset: 1700000000\r\n" ++
        "X-RateLimit-Remaining: 0\r\n\r\n";
    try std.testing.expectEqual(@as(?i64, 1_700_000_000), parseRateLimitReset(head));
}

test "parseRateLimitReset: absent or malformed value is null" {
    const absent = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n\r\n";
    try std.testing.expectEqual(@as(?i64, null), parseRateLimitReset(absent));

    const malformed = "HTTP/1.1 429 Too Many Requests\r\nX-RateLimit-Reset: soon\r\n\r\n";
    try std.testing.expectEqual(@as(?i64, null), parseRateLimitReset(malformed));
}

test "chooseAssetDetailed: gore fixture yields tag + jar name + url" {
    const got = try chooseAssetDetailed(std.testing.allocator, gore_fixture, "gore");
    defer std.testing.allocator.free(got.tag);
    defer std.testing.allocator.free(got.name);
    defer std.testing.allocator.free(got.url);

    try std.testing.expectEqualStrings("v0.1.2", got.tag);
    try std.testing.expectEqualStrings("gore-0.1.2.jar", got.name);
    try std.testing.expectEqual(@as(u64, 12345), got.size);
    try std.testing.expectEqualStrings("https://example/gore-0.1.2.jar", got.url);
}

test "chooseAssetDetailed: release with no qualifying jar → error.NoCompatibleJar" {
    try std.testing.expectError(
        error.NoCompatibleJar,
        chooseAssetDetailed(std.testing.allocator, nojar_fixture, "gore"),
    );
}

test "chooseAssetDetailed: cli/server jars are excluded → error.NoCompatibleJar" {
    try std.testing.expectError(
        error.NoCompatibleJar,
        chooseAssetDetailed(std.testing.allocator, excludedjar_fixture, "tool"),
    );
}

test "chooseAssetDetailed: empty release list → error.NoCompatibleJar" {
    try std.testing.expectError(
        error.NoCompatibleJar,
        chooseAssetDetailed(std.testing.allocator, "[]", "gore"),
    );
}
