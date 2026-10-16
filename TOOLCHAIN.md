# Toolchain

- **Zig:** `0.17.0` (installed via `brew install zig`, macOS/arm64)
- **Build:** `zig build` → `zig-out/bin/modsync`; `zig build test` → test step (test files added in later tasks); `zig build run` → run the app.
- **Link requirements:** none beyond the platform default. The `wio` backend pulls in its own OpenGL/windowing libs via the dvui dependency.

## UI stack (dvui + wio)

The UI is [dvui](https://github.com/david-vanderson/dvui) (immediate-mode GUI) on the pure-Zig [wio](https://github.com/ypsvlq/wio) backend (own windowing + OpenGL; no SDL/GTK/WebKit). Both are fetched as Zig packages via `build.zig.zon` (dvui pinned to a git commit; its transitive deps are locked by `build.zig.zon` hashes). No vendored C library ships in-tree.