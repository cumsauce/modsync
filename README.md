# modsync

A small native desktop app that keeps **one** Minecraft install's `mods` folder in
sync with the newest GitHub *release* jars from a configurable set of repos.

Built with [Zig](https://ziglang.org) + the vendored
[webview/webview](https://github.com/webview/webview) C library — a native OS
window (WKWebView on macOS, WebView2 on Windows, WebKitGTK on Linux) with no
bundled browser engine. Single ~1.7 MB binary (macOS, ReleaseSafe).

**v0.7.3** ships the **Arctic Cyan** theme: a dark, single-column window with a cyan
accent, status-coloured rows, and an inline ⋯ menu per tracked repo. Row icons
are read from the installed jar (the same artwork Minecraft shows), the window
is resizable, and the titlebar can be dragged.

![modsync window](docs/images/modsync.png)

## Install

### Download a release

Grab the asset for your platform from the
[**Releases page**](../../releases/latest):

| Platform | Asset |
|----------|-------|
| macOS (Apple Silicon) | `modsync-macos-arm64.tar.gz` |
| Linux (x86_64) | `modsync-linux-x86_64.tar.gz` |
| Windows (x86_64) | `modsync-windows-x86_64.exe` |

macOS and Linux ship as `.tar.gz` because a release asset carries no POSIX
permission bits — a bare binary always downloads as non-executable.

On macOS the archive contains **`modsync.app`**, so it launches as a normal
application with its own icon and no terminal window:

```sh
tar -xzf modsync-macos-arm64.tar.gz
mv modsync.app /Applications/
open /Applications/modsync.app
```

On Linux the archive contains a bare `modsync` binary that runs directly:

```sh
tar -xzf modsync-linux-x86_64.tar.gz
./modsync
```

The macOS app is ad-hoc signed but **not notarised**, so Gatekeeper warns on
first launch. Either right-click → Open, or clear the quarantine flag once:

```sh
xattr -dr com.apple.quarantine /Applications/modsync.app
```

To build the bundle yourself (icon included):

```sh
zig build -Doptimize=ReleaseSafe
bash scripts/make-app.sh zig-out/bin/modsync "$(git describe --tags --abbrev=0 | tr -d v)" dist
open dist/modsync.app
```

macOS and Linux assets are built and tested in CI. The Windows asset is built
and linked in CI (MSVC toolchain) but has not been runtime-tested.

### Nix (flake)

Runs on any machine with [Nix](https://nixos.org) — no manual toolchain setup:

```sh
# Run it directly
nix run github:cumsauce/modsync

# ...or from a clone
nix run .

# Development shell (zig 0.17 + GTK/WebKit deps on Linux)
nix develop
```

The flake pins `nixos-unstable` on purpose: Zig 0.17 lives there as
`pkgs.zig_0_17` (the stable branch still ships 0.16, which this project cannot
build with).


## What it does

- Point it at a Minecraft folder (e.g. `~/Library/Application Support/minecraft`).
- It tracks a list of GitHub repos and, on **Update all**, downloads the newest
  release jar from each into `<minecraft>/mods/`.
- When it installs a new version of a mod, it removes that mod's older jars
  (`{repo}-*.jar`) and leaves every other file in `mods/` untouched.
- Already-up-to-date mods are skipped (same tag **and** the jar is present).
- Rows are grouped by status — **Up to date**, **Update available**,
  **Not installed**, **Not checked**, **Errors** — with problem groups first,
  instead of being grouped by author.
- Updates run one repo at a time and each row reports its stage: Checking →
  Downloading → Installing → Success/Error.
- Seed repos: `cumsauce/gore`, `cumsauce/foley`, `cumsauce/earshot`,
  `cumsauce/stalker`, `cumsauce/aorta`, `cumsauce/doorswing`,
  `desocketed/yakvc` — configurable via `defaults.json` (see Config below), and
  you can add or remove any repo.
- Row icons come from the installed jar (the artwork Minecraft shows); when a
  mod isn't installed or its jar has no icon, the row falls back to the repo
  name's first letter.
- Prereleases count (foley/earshot/yakvc are prerelease-only), so "newest" means
  the first non-draft release on the `releases?per_page=100` list.

## Build & run

Requires **Zig 0.17.0** (`brew install zig`), or use `nix develop` above.

```sh
zig build            # -> zig-out/bin/modsync
zig build test       # runs the unit tests
zig build run        # builds and launches the app
```

On Linux you also need the GTK/WebKit dev packages:

```sh
# Debian/Ubuntu
sudo apt-get install libgtk-3-dev libwebkit2gtk-4.1-dev
```

Then launch it directly:

```sh
./zig-out/bin/modsync
```

## Using the app

- **Detected launchers** — modsync finds Prism Launcher and Modrinth App installs
  automatically (macOS, Linux, Windows) and lists their instances/profiles. Pick
  one to make it the managed game directory. Only `<profile>/mods/`
  is ever touched; launcher metadata is never written.
- **Minecraft folder** — type the path and press **Save** (manual alternative to
  picking a profile).
- **Window** — the layout is fluid, so widening the window stretches the list and
  controls to fill it. Drag the top strip to move the window.
- **Update all** — fetches each tracked repo's newest release and installs it
  through a staged pipeline: Checking → Downloading → Installing →
  Success/Error, reported on each row. The button reads **Updating…** and is
  disabled during a run; the install can't be switched while updates run.
- **Tracked mods** — grouped by status rather than author: **Up to date**,
  **Update available**, **Not installed**, **Not checked**, and **Errors**,
  with only non-empty groups drawn. Problems come first; each row shows its
  installed version, or the available release for a mod that isn't installed.
- **⋯ menu** — per-repo actions: **Update mod** / **Install mod** / **Retry**
  depending on the row's status, **View on GitHub**, **Copy repo name**, and
  **Remove from tracking**. Removing asks for confirmation and keeps the
  installed jars in `mods/`.
- **Add a repo** — enter `owner/name` and press **Add**; malformed names and
  duplicates are rejected inline.

## Config

A JSON file, auto-created and updated:

| OS      | Path |
|---------|------|
| macOS   | `~/Library/Application Support/modsync/config.json` |
| Linux   | `~/.config/modsync/config.json` |
| Windows | `%APPDATA%\modsync\config.json` |

### Changing the default (seed) repos — no rebuild needed

Which repos a fresh install starts with lives in a **data file**, not the code:

```
<config-dir>/defaults.json      # e.g. ~/Library/Application Support/modsync/defaults.json
```

It's written on first run as a copy of the built-in list. Edit it any time, then
either delete `config.json` (to re-seed on next start) or hit **Restore defaults**
in the app to re-apply it to your current list. A bundled copy in the source
(`src/defaults.json`) is the fallback when the user file is missing or malformed,
so editing the file never requires recompiling.

```json
{ "repos": [ { "owner": "cumsauce", "name": "gore" } ] }
```

Optional: set a GitHub token in `config.json`'s `githubToken` for higher API rate limits.

## Layout

```
src/main.zig      entry point: load config -> App.init -> run
src/config.zig    Config/Repo model, JSON persistence, seeded repos, config paths
src/github.zig    release JSON parsing + deterministic jar-asset selection
src/net.zig       GitHub fetch + jar download over std.http (stdlib only)
src/install.zig   mods-folder ops: mkdir, stale-jar detection, place jar
src/app.zig       webview bridge (JS <-> Zig), staged background update worker
src/os.zig        platform helpers: open URL, clipboard, folder validation
src/ui.html       the UI (vanilla JS, embedded via @embedFile + webview_set_html)
lib/webview/      vendored webview/webview C library (see TOOLCHAIN.md)
```

## Known limitations

- The macOS `.app` is ad-hoc signed but **not notarised**, so Gatekeeper warns
  on first launch (see Install above).
- The Windows build is compiled and linked in CI but has not been
  runtime-tested.
- The clipboard and open-in-browser helpers behind the ⋯ menu are untested on
  Linux and Windows.

## Notes

- v0.7.0 is verified on macOS (builds, launches, live-fetches). Path handling,
  the webview bootstrap, and the `src/os.zig` helpers are the only
  platform-specific code.
- Implementation plan and design doc live under `docs/superpowers/`.
