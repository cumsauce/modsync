# modsync Launcher Detection Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Detect Prism Launcher and Modrinth App installs on macOS/Linux/Windows, list their instances/profiles, and let the user pick one to become modsync's managed game directory.

**Architecture:** New `src/launcher.zig` module (roots + profile enumeration, filesystem-driven, no launcher-metadata writes). `Config` gains an optional `selectedProfile` for display. Two new webview bindings (`listLaunchers`, `selectProfile`) in `src/app.zig`, and a "Detected launchers" section in `src/ui.html`.

**Tech Stack:** Zig 0.17.0 (stdlib only), vendored webview, vanilla-JS UI.

**Spec:** `docs/superpowers/specs/2026-10-16-modsync-launcher-design.md`

## Global Constraints

- Zig 0.17.0 exactly. stdlib only — no new dependencies (no SQLite).
- Zig 0.17 idioms: file I/O is `std.Io.Dir` with an `io: Io` param (from `std.Io.Threaded`); `@cImport` removed (translate-c); NO `std.Thread.Mutex`/`std.Thread.sleep`; `std.Io.Dir.openDirAbsolute(io,path,.{.iterate=true})` + `dir.iterate()` + `entry.kind == .directory`.
- Env lookup uses the portable `getEnv` pattern (NOT `Threaded.environString`, which is empty on Windows). Currently private in `config.zig`/`install.zig` — `launcher.zig` gets its own copy.
- `Config.minecraftDir` remains the SINGLE source of truth for where mods go. Selecting a profile only sets it.
- NEVER write launcher metadata (`instance.cfg`, `mmc-pack.json`, `app.db`). Only `<gameDir>/mods/{repo}-*.jar` is ever touched.
- All strings returned by `launcher.zig` are allocator-owned by the caller.
- `zig build test` must stay green after every task; `zig build` must succeed.

### Exact detection values (from the spec — verbatim)

Root candidates, checked in order (a candidate counts only if the dir EXISTS); env override first:
- Prism: `PRISM_LAUNCHER_DATA_DIR` env, else per-OS: macOS `~/Library/Application Support/PrismLauncher`; Linux `~/.local/share/PrismLauncher` then `~/.var/app/org.prismlauncher.PrismLauncher/data/PrismLauncher`; Windows `%APPDATA%\PrismLauncher`.
- Modrinth: `THESEUS_CONFIG_DIR` env, else per-OS: macOS `~/Library/Application Support/ModrinthApp` then `…/com.modrinth.theseus`; Linux `~/.local/share/ModrinthApp` then `…/com.modrinth.theseus`; Windows `%APPDATA%\ModrinthApp` then `…\com.modrinth.theseus`.
- Prism root marker: has `instances/` (enumerate `instances/*/` where `<d>/instance.cfg` exists).
- Prism gameDir: `<instance>/minecraft` if it exists, else `<instance>/.minecraft` if it exists, else `<instance>/minecraft`.
- Modrinth root marker: has `profiles/` (enumerate every `profiles/*/` dir; no `mods/` required).
- Modrinth gameDir: `<profile>` itself.

## Review Focus

- A Prism instance dir WITHOUT `instance.cfg` must NOT be listed (stray dirs) — test it.
- An environment with NO launchers must degrade to an empty list, never an error that blocks the app.
- An unreadable root must not abort discovery; it goes to `errors`.
- `selectProfile` must not accept a `gameDir` that wasn't offered (path safety) and must persist.
- Adding `selectedProfile` must not break loading a pre-existing v0.1.0 config file.

---

### Task 1: `src/launcher.zig` — types, roots, enumeration

**Files:**
- Create: `src/launcher.zig`
- Modify: `src/main.zig` (add `_ = @import("launcher.zig");` to the test block)

**Interfaces:**
- Consumes: nothing from other modules (self-contained; copies the `makeThreaded`/`getEnv` idiom).
- Produces (exact):
```zig
pub const Kind = enum { prism, modrinth };
pub const Profile = struct { kind: Kind, name: []const u8, gameDir: []const u8, root: []const u8 };
pub const Discovery = struct { profiles: []Profile, errors: [][]const u8 };
pub fn findRoots(allocator: std.mem.Allocator, kind: Kind) ![][]const u8;
pub fn listProfiles(allocator: std.mem.Allocator, kind: Kind, root: []const u8) ![]Profile;
pub fn discoverAll(allocator: std.mem.Allocator) !Discovery;
pub fn freeProfiles(allocator: std.mem.Allocator, profiles: []Profile) void;
pub fn freeRoots(allocator: std.mem.Allocator, roots: [][]const u8) void;
pub fn freeDiscovery(allocator: std.mem.Allocator, d: Discovery) void;
```

- [ ] **Step 1: Write failing tests** (inline in `src/launcher.zig`), building a fake tree in a temp dir under `/tmp/modsync-launcher-<pid-or-fixed>` (mirror `install.zig`'s temp-dir style; clean up with `defer`):
  - `listProfiles(.prism, fakeRoot)` where fakeRoot has `instances/A/instance.cfg` and `instances/B/` (no cfg) → returns exactly 1 profile, `name == "A"`, `gameDir == "<root>/instances/A/minecraft"` (none existed), `kind == .prism`.
  - Prism gameDir prefers existing: add `instances/C/instance.cfg` + `instances/C/.minecraft/` → `gameDir` ends `/instances/C/.minecraft`; add `instances/D/instance.cfg` + `instances/D/minecraft/` → `gameDir` ends `/instances/D/minecraft`.
  - `listProfiles(.modrinth, fakeMroot)` where fakeMroot has `profiles/Alpha/` (empty) and `profiles/Beta/mods/` → returns 2 profiles, `gameDir == "<root>/profiles/Alpha"` (no mods needed), sorted/stable order not required but assert set membership by name.
  - `findRoots` on a machine with nothing → returns len 0 (do NOT assert a specific machine state; just assert it doesn't error and returns a slice).
  - `discoverAll` frees cleanly under `std.testing.allocator` (leak-detecting).

- [ ] **Step 2: Run tests to verify they fail**

Run: `zig build test`
Expected: FAIL (launcher.zig undefined / functions missing).

- [ ] **Step 3: Implement `src/launcher.zig`**

Copy the `makeThreaded`/`getEnv` helpers from `src/config.zig` (same 0.17 env idiom). Root resolution: build candidate list, expand `~`/env, keep only existing dirs. Enumerate with `std.Io.Dir.openDirAbsolute(io, path, .{ .iterate = true })`, `var it = d.iterate(); while (try it.next(io)) |e| { if (e.kind != .directory) continue; ... }`, `d.close(io)`. Per-root read errors: `catch { record into errors; continue; }`. Join paths with `std.fs.path.join`. `name` = the entry's basename (dupe it). Game dir: for Prism check `minecraft/` then `.minecraft/` via `access`, default `minecraft/`.

- [ ] **Step 4: Run tests to verify they pass**

Run: `zig build test` → all pass, pristine; `zig build` → exit 0.

- [ ] **Step 5: Commit**

```bash
git add src/launcher.zig src/main.zig
git commit -m "feat: launcher detection (Prism + Modrinth profiles on all platforms)"
```

---

### Task 2: Config `selectedProfile`

**Files:**
- Modify: `src/config.zig`
- Test: inline in `src/config.zig`

**Interfaces:**
- Consumes: nothing.
- Produces:
```zig
pub const ProfileRef = struct { kind: []const u8, name: []const u8, gameDir: []const u8 };
// Config gains: selectedProfile: ?ProfileRef = null,
```
`dupeConfig`/`freeConfig` must deep-copy/free the new nested strings.

- [ ] **Step 1: Write failing test** — a `Config` with `selectedProfile = .{ .kind="prism", .name="A", .gameDir="/tmp/x/instances/A/minecraft" }` round-trips through `saveTo`/`loadFrom` with exact equality; and a second test that a JSON string WITHOUT the `selectedProfile` key parses with `selectedProfile == null` (backward compat).

- [ ] **Step 2: Run test to verify it fails** → `zig build test` FAIL (field doesn't exist).

- [ ] **Step 3: Implement** — add `ProfileRef` + the field; extend `dupeConfig` (dupe all three strings when present) and `freeConfig` (free them). `std.json` handles the optional field natively with the default.

- [ ] **Step 4: Run test to verify it passes** → `zig build test` all pass; `zig build` exit 0.

- [ ] **Step 5: Commit**

```bash
git add src/config.zig
git commit -m "feat: config selectedProfile field with backward-compatible load"
```

---

### Task 3: App bridge — `listLaunchers` + `selectProfile`

**Files:**
- Modify: `src/app.zig`

**Interfaces:**
- Consumes: `launcher.discoverAll`/`freeDiscovery` (Task 1), `config.ProfileRef` (Task 2).
- Produces (new bound JS functions):
```zig
listLaunchers() -> JSON  // {"profiles":[{"kind","name","gameDir","root"}],"errors":["..."]}
selectProfile(gameDir) -> "true" | "false"
```
Plus a pure, testable `pub fn buildLaunchersJson(allocator, d: *const launcher.Discovery) ![]u8`.

- [ ] **Step 1: Write failing test** — `buildLaunchersJson` on a `Discovery` with one prism profile `{name:"A",gameDir:"/m/A"}` and one error `"denied"` yields JSON containing `"prism"`, `"A"`, `"/m/A"`, and `"denied"`. Empty discovery → contains `"profiles":[]`.

- [ ] **Step 2: Run test to verify it fails** → `zig build test` FAIL.

- [ ] **Step 3: Implement** — `buildLaunchersJson` (use `std.json.Stringify.valueAlloc` with a locally-built serializable struct, or manual `ArrayList` + `Stringify` — either, must assert on substrings). Bind `"listLaunchers"`/`"selectProfile"` next to the existing binds in `run()`. `cbSelectProfile`: parse the first string arg as `gameDir`, look it up via `launcher.discoverAll` (match `gameDir` exactly), on match set `cfg.minecraftDir` (dupe) + `cfg.selectedProfile` (dupe fields), `save`, return `"true"`; else `"false"`. Follow the existing mutex discipline (lock around cfg mutation).

- [ ] **Step 4: Run test to verify it passes** → `zig build test` all pass; `zig build` exit 0.

- [ ] **Step 5: Commit**

```bash
git add src/app.zig
git commit -m "feat: listLaunchers/selectProfile bridge functions"
```

---

### Task 4: UI — Detected launchers section

**Files:**
- Modify: `src/ui.html`

**Interfaces:**
- Consumes: `listLaunchers()` / `selectProfile(gameDir)` (Task 3) and the existing `getConfig()`/`renderState()`.

- [ ] **Step 1: Add the section** (no automated test — GUI is verified by build + manual smoke): a "Detected launchers" block above the Minecraft folder input with a **Rescan** button. On load and on Rescan, `await listLaunchers()`; group rows by `kind` (Prism / Modrinth); each row shows `name` + a muted `gameDir`, and a **Use** button → `await selectProfile(row.gameDir)` then `await load()` (re-fetch state). If `profiles` is empty and `errors` empty → "No launchers found — enter a path below." If `errors` non-empty → show the profiles found plus a muted note listing the unreadable roots. Highlight the row whose `gameDir` equals the current `minecraftDir`. Keep the existing manual path input + Save.

- [ ] **Step 2: Verify build** → `zig build` exit 0; `zig build test` still green.

- [ ] **Step 3: Manual smoke** (best-effort): `./zig-out/bin/modsync` launches; the section renders (even if empty). Note GUI is otherwise unverifiable headless.

- [ ] **Step 4: Commit**

```bash
git add src/ui.html
git commit -m "feat: UI launcher/profile picker section"
```

---

### Task 5: README + release

**Files:**
- Modify: `README.md`

- [ ] **Step 1:** Add a short "Launcher support" note: modsync detects Prism Launcher and Modrinth App installs and can manage a selected instance/profile; it only writes `<profile>/mods/` and never touches launcher metadata.
- [ ] **Step 2:** Commit, push to `main`, confirm CI green on all three OSes, tag `v0.2.0`, confirm the release publishes.

---

## Self-review notes

- Spec coverage: roots/enumeration (Task 1), config (Task 2), bridge (Task 3), UI (Task 4), docs/release (Task 5). Each Decision D1–D5 is realized: D1 `selectProfile(gameDir)` in Task 3; D2 one-level Modrinth scan in Task 1; D3 absolute gameDir in Task 1; D4 list-without-gamedir + create-on-refresh in Task 1; D5 `errors` in Tasks 1/3/4.
- Type consistency: `Profile`/`Discovery`/`Kind` used identically across Tasks 1/3/4; `ProfileRef.gameDir` matches `Profile.gameDir`.
- The one genuinely untestable piece (GUI rendering) is called out in Task 4 Step 3.
