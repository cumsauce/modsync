const std = @import("std");
const Allocator = std.mem.Allocator;

// ============================================================================
// Public types — Task 5 (network) and Task 6 (app wiring) import these names.
// ============================================================================

pub const Asset = struct {
    name: []const u8,
    size: u64,
    browserDownloadUrl: []const u8,
};

pub const Release = struct {
    tag: []const u8,
    draft: bool,
    prerelease: bool,
    assets: []Asset,
};

/// GitHub's wire format uses snake_case; `std.json` matches struct field
/// names exactly, so the raw shapes below mirror the JSON payload and are
/// mapped to the public camelCase/published shapes by `parseReleases`.
const RawAsset = struct {
    name: []const u8,
    size: u64,
    browser_download_url: []const u8,
};

const RawRelease = struct {
    tag_name: []const u8,
    draft: bool,
    prerelease: bool,
    assets: []RawAsset,
};

/// Parse a GitHub `/releases` JSON array into caller-owned `Release`s.
///
/// Every string in the result is duplicated into `allocator`, so the parse
/// buffers can be (and are) released before returning. Caller frees with
/// `freeReleases`. Prereleases are intentionally NOT filtered here — draft
/// skipping happens in `selectRelease`, and prereleases stay selectable.
pub fn parseReleases(allocator: Allocator, json: []const u8) ![]Release {
    const parsed = try std.json.parseFromSlice([]const RawRelease, allocator, json, .{
        // Real GitHub payloads carry many fields modsync ignores (url, id,
        // author, ...); fixtures are abridged, so unknown fields must pass.
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    const releases = try allocator.alloc(Release, parsed.value.len);
    errdefer allocator.free(releases);
    var built: usize = 0;
    errdefer {
        for (releases[0..built]) |r| {
            allocator.free(r.tag);
            for (r.assets) |a| freeAsset(allocator, a);
            allocator.free(r.assets);
        }
    }

    for (parsed.value, releases) |raw, *out| {
        const tag = try allocator.dupe(u8, raw.tag_name);
        errdefer allocator.free(tag);

        const assets = try allocator.alloc(Asset, raw.assets.len);
        errdefer allocator.free(assets);
        var assets_built: usize = 0;
        errdefer {
            for (assets[0..assets_built]) |a| freeAsset(allocator, a);
        }

        for (raw.assets, assets) |raw_asset, *aout| {
            const name = try allocator.dupe(u8, raw_asset.name);
            errdefer allocator.free(name);
            const url = try allocator.dupe(u8, raw_asset.browser_download_url);
            aout.* = .{
                .name = name,
                .size = raw_asset.size,
                .browserDownloadUrl = url,
            };
            assets_built += 1;
        }

        out.* = .{
            .tag = tag,
            .draft = raw.draft,
            .prerelease = raw.prerelease,
            .assets = assets,
        };
        built += 1;
    }

    return releases;
}

/// Free everything owned by a `parseReleases` result. The allocator must be
/// the one passed to `parseReleases`.
pub fn freeReleases(allocator: Allocator, releases: []Release) void {
    for (releases) |r| {
        allocator.free(r.tag);
        for (r.assets) |a| freeAsset(allocator, a);
        allocator.free(r.assets);
    }
    allocator.free(releases);
}

fn freeAsset(allocator: Allocator, a: Asset) void {
    allocator.free(a.name);
    allocator.free(a.browserDownloadUrl);
}

/// First non-draft release in API order, else null. Prereleases are kept —
/// drafts are unpublished work, prereleases are real releases.
pub fn selectRelease(releases: []const Release) ?Release {
    for (releases) |r| {
        if (!r.draft) return r;
    }
    return null;
}

/// Deterministic client-jar selection (Global Constraints, verbatim):
///  1. Qualifying = ends in `.jar` AND does not contain `cli` AND does not
///     contain `server` (case-sensitive substring match).
///  2. Exactly one qualifier → it.
///  3. Multiple → prefer names starting with `{repoName}-`; if that narrows
///     to one, it wins (even if smaller than another qualifier).
///  4. Still multiple → the largest `size`.
///  5. Zero → null.
///
/// Allocation-free; the `!` is kept for signature stability with Task 5.
pub fn selectJarAsset(allocator: Allocator, assets: []const Asset, repoName: []const u8) !?Asset {
    _ = allocator;

    var total: usize = 0;
    var prefixed_total: usize = 0;
    var best_all: Asset = undefined; // meaningful once total >= 1
    var best_prefixed: Asset = undefined; // meaningful once prefixed_total >= 1

    for (assets) |a| {
        if (!qualifiesJar(a.name)) continue;
        total += 1;
        if (total == 1 or a.size > best_all.size) best_all = a;
        if (hasRepoPrefix(a.name, repoName)) {
            prefixed_total += 1;
            if (prefixed_total == 1 or a.size > best_prefixed.size) best_prefixed = a;
        }
    }

    if (total == 0) return null;
    // Single qualifier resolves through the same path (its own prefix bucket
    // or best_all). With multiple qualifiers, any prefixed candidates form
    // the narrowed set (one → it; several → largest among them); none
    // prefixed → largest qualifier overall.
    return if (prefixed_total > 0) best_prefixed else best_all;
}

/// Case-sensitive `.jar` + not-cli + not-server rule.
fn qualifiesJar(name: []const u8) bool {
    if (!std.mem.endsWith(u8, name, ".jar")) return false;
    if (std.mem.indexOf(u8, name, "cli") != null) return false;
    if (std.mem.indexOf(u8, name, "server") != null) return false;
    return true;
}

/// True when `name` starts with `{repoName}-` (prefix includes the hyphen).
fn hasRepoPrefix(name: []const u8, repoName: []const u8) bool {
    if (name.len <= repoName.len) return false;
    if (name[repoName.len] != '-') return false;
    return std.mem.startsWith(u8, name, repoName);
}

// ============================================================================
// Fixtures — abridged shapes of real GitHub /repos/{owner}/{repo}/releases
// responses, containing only the fields modsync consumes (see Task 3 brief).
// ============================================================================

const gore_json =
    \\[{"tag_name":"v0.1.2","draft":false,"prerelease":false,"assets":[{"name":"gore-0.1.2.jar","size":12345,"browser_download_url":"https://example/gore-0.1.2.jar"}]}]
;

const earshot_json =
    \\[{"tag_name":"v0.1.0-alpha.43","draft":false,"prerelease":true,"assets":[{"name":"earshot-0.1.0-alpha.43.jar","size":4242,"browser_download_url":"https://example/earshot-0.1.0-alpha.43.jar"}]}]
;

const draft_json =
    \\[{"tag_name":"v0.2.0-unreleased","draft":true,"prerelease":false,"assets":[]},
    \\{"tag_name":"v0.1.9","draft":false,"prerelease":false,"assets":[]}]
;

const yakvc_json =
    \\[{"tag_name":"v0.1.0-alpha.3.dev.321","draft":false,"prerelease":true,"assets":[
    \\{"name":"SHA256SUMS","size":512,"browser_download_url":"https://example/SHA256SUMS"},
    \\{"name":"yakvc-0.1.0-alpha.3.dev.321-prism.zip","size":9000,"browser_download_url":"https://example/yakvc-prism.zip"},
    \\{"name":"yakvc-0.1.0-alpha.3.dev.321.jar","size":7000,"browser_download_url":"https://example/yakvc.jar"},
    \\{"name":"yakvc-0.1.0-alpha.3.dev.321.mrpack","size":8000,"browser_download_url":"https://example/yakvc.mrpack"},
    \\{"name":"yakvc-cli-linux-x86_64","size":99999,"browser_download_url":"https://example/yakvc-cli"},
    \\{"name":"yakvc-server-linux-x86_64","size":99999,"browser_download_url":"https://example/yakvc-server"}]}]
;

const nojar_json =
    \\[{"tag_name":"v1.0.0","draft":false,"prerelease":false,"assets":[
    \\{"name":"SHA256SUMS","size":10,"browser_download_url":"https://example/SHA256SUMS"},
    \\{"name":"notes.txt","size":5,"browser_download_url":"https://example/notes.txt"}]}]
;

// ============================================================================
// Tests (TDD — these must fail before src/github.zig's API exists)
// ============================================================================

test "parseReleases gore-shaped: parses tag/asset fields and selectJarAsset picks the jar" {
    const releases = try parseReleases(std.testing.allocator, gore_json);
    defer freeReleases(std.testing.allocator, releases);

    try std.testing.expectEqual(@as(usize, 1), releases.len);
    try std.testing.expectEqualStrings("v0.1.2", releases[0].tag);
    try std.testing.expect(!releases[0].draft);
    try std.testing.expect(!releases[0].prerelease);
    try std.testing.expectEqual(@as(usize, 1), releases[0].assets.len);

    const asset = releases[0].assets[0];
    try std.testing.expectEqualStrings("gore-0.1.2.jar", asset.name);
    try std.testing.expectEqual(@as(u64, 12345), asset.size);
    try std.testing.expectEqualStrings("https://example/gore-0.1.2.jar", asset.browserDownloadUrl);

    const selected = selectRelease(releases).?;
    try std.testing.expectEqualStrings("v0.1.2", selected.tag);

    const jar = (try selectJarAsset(std.testing.allocator, releases[0].assets, "gore")).?;
    try std.testing.expectEqualStrings("gore-0.1.2.jar", jar.name);
}

test "earshot-shaped: prerelease flag is preserved and selectRelease keeps it" {
    const releases = try parseReleases(std.testing.allocator, earshot_json);
    defer freeReleases(std.testing.allocator, releases);

    try std.testing.expectEqualStrings("v0.1.0-alpha.43", releases[0].tag);
    try std.testing.expect(!releases[0].draft);
    try std.testing.expect(releases[0].prerelease);

    // Prereleases must NOT be dropped: selectRelease returns this release.
    const selected = selectRelease(releases).?;
    try std.testing.expectEqualStrings("v0.1.0-alpha.43", selected.tag);
    try std.testing.expect(selected.prerelease);
}

test "selectRelease skips a leading draft and returns the first non-draft" {
    const releases = try parseReleases(std.testing.allocator, draft_json);
    defer freeReleases(std.testing.allocator, releases);

    try std.testing.expectEqual(@as(usize, 2), releases.len);
    try std.testing.expect(releases[0].draft);

    const selected = selectRelease(releases).?;
    try std.testing.expectEqualStrings("v0.1.9", selected.tag);
    try std.testing.expect(!selected.draft);
}

test "selectRelease returns null for empty and all-draft lists" {
    const empty: []const Release = &.{};
    try std.testing.expect(selectRelease(empty) == null);

    const all_draft_json =
        \\[{"tag_name":"v1.0.0","draft":true,"prerelease":false,"assets":[]}]
    ;
    const releases = try parseReleases(std.testing.allocator, all_draft_json);
    defer freeReleases(std.testing.allocator, releases);
    try std.testing.expect(selectRelease(releases) == null);
}

test "yakvc-shaped: mixed asset list resolves to exactly the plain .jar" {
    const releases = try parseReleases(std.testing.allocator, yakvc_json);
    defer freeReleases(std.testing.allocator, releases);

    try std.testing.expectEqualStrings("v0.1.0-alpha.3.dev.321", releases[0].tag);
    try std.testing.expectEqual(@as(usize, 6), releases[0].assets.len);

    const jar = (try selectJarAsset(std.testing.allocator, releases[0].assets, "yakvc")).?;
    // NOT prism.zip / mrpack / SHA256SUMS / cli / server — and the plain jar
    // is deliberately not the largest asset in the fixture (prism/mrpack/cli
    // are bigger), so size alone cannot produce this answer.
    try std.testing.expectEqualStrings("yakvc-0.1.0-alpha.3.dev.321.jar", jar.name);
}

test "selectJarAsset returns null when nothing qualifies as a jar" {
    const releases = try parseReleases(std.testing.allocator, nojar_json);
    defer freeReleases(std.testing.allocator, releases);

    try std.testing.expect((try selectJarAsset(std.testing.allocator, releases[0].assets, "gore")) == null);
}

test "selectJarAsset prefers the {repo}- prefix over raw size" {
    const assets = [_]Asset{
        .{ .name = "foo-1.0.jar", .size = 10, .browserDownloadUrl = "https://example/foo" },
        .{ .name = "unrelated-9.9.jar", .size = 2, .browserDownloadUrl = "https://example/other" },
    };
    const picked = (try selectJarAsset(std.testing.allocator, &assets, "foo")).?;
    try std.testing.expectEqualStrings("foo-1.0.jar", picked.name);

    // Stronger variant: prefixed jar is the SMALLER one — prefix must still
    // win over size.
    const reversed = [_]Asset{
        .{ .name = "foo-1.0.jar", .size = 3, .browserDownloadUrl = "https://example/foo" },
        .{ .name = "unrelated-9.9.jar", .size = 9000, .browserDownloadUrl = "https://example/other" },
    };
    const picked_reversed = (try selectJarAsset(std.testing.allocator, &reversed, "foo")).?;
    try std.testing.expectEqualStrings("foo-1.0.jar", picked_reversed.name);
}

test "selectJarAsset breaks ties between prefixed jars by largest size" {
    const assets = [_]Asset{
        .{ .name = "foo-1.0.jar", .size = 5, .browserDownloadUrl = "https://example/a" },
        .{ .name = "foo-2.0.jar", .size = 9, .browserDownloadUrl = "https://example/b" },
    };
    const picked = (try selectJarAsset(std.testing.allocator, &assets, "foo")).?;
    try std.testing.expectEqualStrings("foo-2.0.jar", picked.name);
}

test "selectJarAsset excludes cli/server names even when they end in .jar" {
    const assets = [_]Asset{
        .{ .name = "thing-1.0.jar", .size = 1, .browserDownloadUrl = "https://example/main" },
        .{ .name = "thing-cli-1.0.jar", .size = 100, .browserDownloadUrl = "https://example/cli" },
        .{ .name = "thing-server-1.0.jar", .size = 100, .browserDownloadUrl = "https://example/srv" },
    };
    const picked = (try selectJarAsset(std.testing.allocator, &assets, "thing")).?;
    // All three carry the "thing-" prefix, so only the cli/server filter can
    // produce this answer (the filtered-out jars are 100x larger).
    try std.testing.expectEqualStrings("thing-1.0.jar", picked.name);
}
