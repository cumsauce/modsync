# modsync CI & release design

**Date:** 2026-10-16
**Status:** approved (user: "ci for all platforms", "yes go for it")

## Intent

Ship `modsync` as a downloadable thing. Create the GitHub repo
(`github.com/cumsauce/modsync`, public), push the finished branch, and set up
GitHub Actions so that pushing a version tag produces a GitHub Release with a
runnable binary attached for every major desktop platform.

## Why multi-platform CI (not cross-compile)

Recon established this: `zig build -Dtarget=x86_64-linux` fails with
`'gtk/gtk.h' file not found`. The vendored webview needs each platform's native
webview headers/libs at compile time:

| OS | Backend | Needs |
|----|---------|-------|
| macOS | cocoa_webkit | WebKit + Cocoa frameworks (system SDK) |
| Linux | gtk_webkitgtk | `libgtk-3-dev`, `libwebkit2gtk-4.1-dev` (dev headers) |
| Windows | win32_edge | WebView2 (loaded at runtime by the OS; no dev headers needed to link) |

Those dev packages exist only on the target OS, so binaries are built on native
GitHub runners. All three backends are already vendored under
`lib/webview/webview/detail/backends/`, so this is build config, not a port.

## Goals

- A public repo at `github.com/cumsauce/modsync` with the full history on `main`.
- Tag push (`v*`) → GitHub Release with per-platform binary assets.
- macOS binary verified to launch (I can run it); Linux/Windows built and
  packaged but runtime-unverified (accepted).
- `zig build test` runs in CI on every push/PR so regressions are caught.

## Non-goals

- No code signing / notarization (macOS Gatekeeper will warn on first run; user
  right-clicks → Open, or `xattr -d com.apple.quarantine`). Out of scope.
- No Linux packaging (.deb/.rpm/AppImage) — a bare binary is enough for v1.
- No Windows installer — a bare `.exe` is enough for v1.
- No auto-update.

## Anti-goals

- CI that reports green while the binary is broken. Every job must build the
  actual artifact and (where the runner allows) run `zig build test`.
- Committing build outputs.

## Decisions (mine, as the builder)

1. **Workflow triggers:** `on: push: tags: ['v*']` for releases; separate
   `on: push/pull_request` job for tests. Tag vs. test split keeps release
   artifacts tied to a real version.
2. **Zig install:** `mlugg/setup-zig` pinned to `0.17.0` (confirmed released;
   `build.zig.zon` requires `0.17.0`).
3. **Matrix:** `macos-14` (arm64 — matches the machine we built on),
   `ubuntu-latest` (x86_64), `windows-latest` (x86_64). Arm64 mac only for v1.
4. **Release creation:** a final job using `softprops/action-gh-release` (or
   `gh release create`) that downloads each platform artifact and attaches it.
   **My call:** use `gh release create` via the `GH_TOKEN` — fewer third-party
   actions, already authed, and it can attach multiple files in one call.
5. **Artifact naming:** `modsync-macos-arm64`, `modsync-linux-x86_64`,
   `modsync-windows-x86_64.exe`. Windows gets `.exe`.
6. **Linux link flags** to add to `build.zig` (guarded `os.tag == .linux`):
   `webkit2gtk-4.1`, `gtk-3`, `gobject-2.0`, `glib-2.0`, `javascriptcoregtk-4.1`.
   These are what upstream webview's own CMake links; confirm names against the
   runner's `pkg-config --libs` output on first CI run and adjust.
7. **Windows:** webview's win32 backends link against system libs via
   `pragmas`/loaders; if extra `linkSystemLibrary` calls are needed they get the
   same per-OS guard. Verify on first CI run.
8. **`build.zig.zon`:** remove the nonexistent `LICENSE` from `.paths` (or add a
   LICENSE file). **My call:** add a LICENSE (MIT, matching the vendored
   webview's) — better for a public repo than deleting the entry.
9. **`build.zig`:** add an option so CI can strip/optimize release builds
   (`-Doptimize=ReleaseSafe` passed on the tag build).

## What's left to the builder (me)

- The exact Linux/Windows link-flag set is empirical: first CI run reveals
  missing libs; iterate until all three jobs are green.
- Whether `zig build test` can run on Windows/Linux runners as-is (the tests use
  `/tmp` paths — macOS-isms). If they fail on other OSes, gate the test job to
  run `zig build test` only on macOS, and `zig build` (compile) on all three.
- The release job's exact shape (needs `contents: write`).

## Risks

- Windows/Linux binaries are unverified at runtime. Mitigation: they at least
  must *link*; a runtime smoke test is impossible without those OSes. Stated
  clearly in the release notes.
- `ubuntu-latest` may not have `libwebkit2gtk-4.1-dev` by default → the workflow
  `apt-get install`s it explicitly.
- Zig 0.17 is very new; `mlugg/setup-zig` must have the `0.17.0` index entry.
  Confirmed the download index lists it.
