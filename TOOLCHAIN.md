# Toolchain

- **Zig:** `0.17.0` (installed via `brew install zig`, macOS/arm64)
- **Build:** `zig build` → `zig-out/bin/modsync`; `zig build test` → test step (test files added in later tasks); `zig build run` → run the app.
- **Link requirements (macOS):** frameworks `WebKit`, `Cocoa`, and library `objc` — declared in `build.zig`.

## Vendored webview

- The [webview/webview](https://github.com/webview/webview) C API library is vendored in-tree at `lib/webview/` (committed, pinned by being in-tree — not fetched at build time).
- Upstream commit: `cbbdee44afff22867de9fd88a9fc8350d9bdd399` (master, fetched 2026-10-16).
- Layout: `lib/webview/webview.h` is the canonical entry point (compat shim including `webview/webview.h`); the rest of upstream `core/include/` is mirrored underneath (`lib/webview/webview/…`). The library is header-only: `lib/webview/webview_impl.cc` includes the header with the implementation compiled in (upstream guards the implementation with `__cplusplus && !WEBVIEW_HEADER`; the historical `WEBVIEW_IMPLEMENTATION` define is kept for compatibility).
- Note: upstream no longer ships a single-file `webview.h` at the repo root (the `master` raw URL 404s), so the whole `core/include/` tree was vendored instead.
