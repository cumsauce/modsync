# modsync — Minecraft GitHub-release mod installer

**Date:** 2026-10-16
**Status:** approved in conversation; builder check pending

## Intent

Keep a single Minecraft installation's `mods` folder in sync with the newest
release jars from a set of GitHub repositories, with a small cross-platform
native app the user opens and hits **Refresh** in. Replaces manually watching
five repos, downloading jars, and swapping files.

## Goals

- Cross-platform: macOS first (user's machine), Windows and Linux supported by
  the same codebase and build.
- Small binary (single-digit MB), very quick build times (sub-second
  incremental). Language: **Zig**.
- Native window via a **webview** (WKWebView on macOS, WebView2 on Windows,
  WebKitGTK on Linux) — borrows the OS browser engine, no bundled Chromium.
  UI is HTML/CSS/JS embedded in the binary; app logic in Zig behind a thin
  JS↔Zig bridge.
- User specifies a Minecraft install folder once; app manages `<folder>/mods`
  (creates it if missing).
- Seeded tracked repos:
  - `cumsauce/gore`
  - `cumsauce/foley`
  - `cumsauce/earshot`
  - `cumsauce/stalker`
  - `desocketed/yakvc`
- **Refresh** checks every tracked repo for its latest release, downloads the
  jar asset, and installs it into `mods/`, replacing the previously installed
  jar for that mod (only jars modsync itself installed — never touches other
  files in `mods/`).
- Add any GitHub `owner/repo` later via UI (covers the not-yet-published
  "surprise mod"; shows "no releases" until one exists).
- Version tracking: per-mod state shows installed version vs. latest available.

## Non-goals (v1)

- Non-GitHub hosts (GitLab, Codeberg, etc.).
- CurseForge/Modrinth APIs.
- Minecraft version/loader compatibility filtering (user runs Fabric 26.3
  exclusively; assumed all tracked jars are compatible).
- Auto-refresh on a timer; multiple Minecraft installs; dependency
  resolution (Fabric API etc.).

## Constraints discovered (GitHub survey, 2026-10-16)

- **Prereleases are the norm, not the exception.** `foley` (v0.1.0-beta.55),
  `earshot` (v0.1.0-alpha.43), and `yakvc` publish *only* prereleases.
  Default release selection **includes prereleases**; a per-mod or global
  "stable only" toggle is a possible later refinement, not v1.
- `gore` latest: v0.1.2 (`gore-0.1.2.jar`); `stalker` latest: v0.4.0
  (`stalker-0.4.0.jar`) — both true stable releases.
- `yakvc` releases carry multiple assets (`.jar`, `.mrpack`, prism zip, CLI
  binaries, `SHA256SUMS`). Asset selection rule: **pick the `.jar` asset whose
  name does not contain `cli` or `server`** (i.e. the client mod jar). If
  exactly one `.jar` exists, take it regardless.
- `desocketed/yakvc` is the canonical tracked repo (user-named);
  `cumsauce/yakvc` exists as a fork and may be swapped/added by the user later
  via the add-repo feature.
- GitHub unauthenticated API: 60 requests/hr — ample for a handful of repos
  refreshed manually. Support optional `GITHUB_TOKEN` (or in-app setting) for
  higher limits and private-repo future-proofing; works without it.
- Latest-release lookup uses `GET /repos/{owner}/{repo}/releases` (list, not
  `/releases/latest`, because `/latest` excludes prereleases). Take the first
  non-draft release from the list (list is already newest-first).
- Jar download URL is the asset's `browser_download_url` (redirects to CDN;
  follow redirects).

## Decisions

- **Zig** for tiny binaries, instant builds, easy cross-compilation.
- **webview/webview** C library (compiled into the binary via Zig build system)
  for the native window; no heavyweight UI framework.
- Config and state in a JSON file in the platform config dir
  (`~/.config/modsync/config.json` on Linux, `~/Library/Application
  Support/modsync/config.json` on macOS, `%APPDATA%\modsync\config.json` on
  Windows). Holds: minecraft folder path, tracked repo list (with per-repo
  installed version + installed jar filename), optional GitHub token.
- On refresh, per repo:
  1. GET releases list.
  2. First non-draft release → tag, assets.
  3. Select jar asset (rule above).
  4. If installed version == tag and jar still present in `mods/`, skip.
  5. Else download to temp, delete previously-installed jar (by recorded
     filename) if present, move new jar into `mods/`, update state.
- Errors (repo not found, no releases, network failure) surface per-row in the
  UI without aborting the rest of the refresh.

## Builder-check resolutions (2026-10-16)

Independent reviewer flagged four questions; all settled here as design calls:

1. **Pre-existing hand-downloaded jars (first-run reality).** On install for
   repo `X`, modsync deletes any `mods/X-*.jar` that is not the jar it is
   installing (prefix match on the repo name). This adopts jars the user
   downloaded by hand on first run, prevents duplicate-mod launch failures,
   and still respects the invariant: only files matching the tracked repo's
   own jar naming pattern are ever touched; everything else in `mods/` is
   untouchable.
2. **Cross-platform bar for v1.** Acceptance = macOS binary built and
   smoke-tested; code has no platform-forked logic beyond path handling and
   webview bootstrap (so Windows/Linux builds remain drop-in later). No
   Windows/Linux binaries are built or tested in v1.
3. **Multiple qualifying jars.** Deterministic selection: (a) among `.jar`
   assets excluding `cli`/`server` in the name, prefer assets named
   `{repo}-*.jar`; (b) if still multiple, take the largest by byte size;
   (c) zero qualifying jars → that row errors, refresh continues.
4. **Networking dependencies.** Zig standard library only (`std.http.Client`,
   `std.json`). No vendored curl or C HTTP stack — keeps the binary small and
   builds fast. `std.http` follows redirects automatically (covers
   `browser_download_url` CDN redirects). If std TLS proves unworkable during
   implementation, surface it rather than silently vendoring a dependency.

## Out of scope for the builder to decide

- Exact HTML/CSS styling (functional, minimal, dark-mode-friendly).
- Zig package layout / module names beyond what's needed.
- CI / release packaging for the app itself (v1 is a local build).

## What's left

- Implementation plan (superpowers:writing-plans), then build.
