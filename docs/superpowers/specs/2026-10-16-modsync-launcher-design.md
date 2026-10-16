# modsync launcher & profile detection — design

**Date:** 2026-10-16
**Status:** approved (user: "sounds good"; scope confirmed via Q&A)
**Builds on:** `2026-10-16-modsync-design.md` (v0.1.0, shipped)

## Intent

Today you point modsync at a Minecraft folder by typing a path. This adds
**launcher detection**: modsync finds Prism Launcher and Modrinth App installs on
the machine, lists their instances/profiles, and lets you pick one — which sets
the game directory modsync manages. It then keeps that profile's tracked jars
updated, independently of what Modrinth itself does. No communication with the
launcher beyond both writing into the same `mods/` folder.

User's words: *"it should be able to select a profile and keep its jars updated
while modrinth keeps its mods updated, theres no communication outside of that"*
and *"detection must be available on all systems"*.

## Goals

- Detect Prism Launcher and Modrinth App on **macOS, Linux, and Windows**.
- Enumerate profiles/instances under each detected root.
- Let the user pick a profile; that sets the managed game directory.
- Keep everything downstream unchanged: modsync only ever touches
  `<gameDir>/mods/{repo}-*.jar`.

## Non-goals

- No writing to launcher metadata (`instance.cfg`, `mmc-pack.json`, `app.db`).
- No reading Modrinth's SQLite `app.db` (folder names are the labels — user's call).
- No launching the game, no Java args, no loader management.
- No "which mods belong to this profile" reconciliation — the user has explicitly
  accepted that modsync and Modrinth may each overwrite the other's jars.

## Anti-goals

- Detection that reports a profile that isn't real, or a path modsync can't write.
- Crashing or erroring when no launcher is installed (must degrade to manual path).

## Constraints

- Zig 0.17.0, stdlib only (no new third-party deps).
- Cross-platform; per-OS paths differ but the logic is shared.
- Must not regress the existing manual-path flow or v0.1.0 behaviour.

## Research findings (primary sources; see spec appendix)

### Prism Launcher
- Data-dir resolution order: `-d/--dir` flag → env `PRISM_LAUNCHER_DATA_DIR` →
  `QStandardPaths::AppDataLocation/..` (the per-OS default below). Portable mode
  via a `UserData`/`portable.txt` beside the binary (not on macOS).
- Default roots: macOS `~/Library/Application Support/PrismLauncher`;
  Linux `~/.local/share/PrismLauncher` (+ Flatpak
  `~/.var/app/org.prismlauncher.PrismLauncher/data/PrismLauncher`); Windows
  `%APPDATA%\PrismLauncher`.
- Config file `prismlauncher.cfg` (legacy `polymc.cfg`, `multimc.cfg`).
- **There is no `instances.json`.** Instances are directories under
  `instances/<id>/` that contain `instance.cfg`. (`instgroups.json` holds groups
  only.)
- Per-instance: metadata in `instance.cfg` (INI, has a `name` key) and
  `mmc-pack.json`. **Game dir = `instances/<id>/minecraft/`** (fallback
  `instances/<id>/.minecraft/` for legacy imports); mods = `<gameDir>/mods`.

### Modrinth App
- Data-dir resolution: env `THESEUS_CONFIG_DIR` → `dirs::data_dir()/ModrinthApp`
  (legacy `com.modrinth.theseus`). Default roots: macOS
  `~/Library/Application Support/ModrinthApp`; Linux `~/.local/share/ModrinthApp`;
  Windows `%APPDATA%\ModrinthApp`.
- A valid root contains `app.db` (SQLite, not parsed).
- Profiles live under `<root>/profiles/<path>/`; **the profile folder IS the game
  directory**, so mods = `<root>/profiles/<path>/mods`.

## Design

### New module `src/launcher.zig`

```zig
pub const Kind = enum { prism, modrinth };

pub const Profile = struct {
    kind: Kind,
    /// Display label: the folder name under instances/ (Prism) or profiles/ (Modrinth).
    name: []const u8,
    /// Absolute path to the game directory (what becomes Config.minecraftDir).
    /// This is the unique identity used by selectProfile(gameDir).
    gameDir: []const u8,
    /// Absolute path to the launcher root it came from (for grouping/debug).
    root: []const u8,
};

pub const Discovery = struct {
    profiles: []Profile,
    /// Roots that existed but could not be read (permission errors etc.).
    errors: [][]const u8,
};

/// Discover all launcher roots on this machine (existing dirs only).
pub fn findRoots(allocator: std.mem.Allocator, kind: Kind) ![][]const u8;

/// Enumerate profiles under a single root (direct child dirs; no mods/ required).
pub fn listProfiles(allocator: std.mem.Allocator, kind: Kind, root: []const u8) ![]Profile;

/// Convenience: all profiles across all detected roots of both launchers.
pub fn discoverAll(allocator: std.mem.Allocator) !Discovery;

// Free helpers.
pub fn freeProfiles(allocator: std.mem.Allocator, profiles: []Profile) void;
pub fn freeRoots(allocator: std.mem.Allocator, roots: [][]const u8) void;
pub fn freeDiscovery(allocator: std.mem.Allocator, d: Discovery) void;
```
All strings are allocator-owned by the caller. `Kind` serializes as its
`@tagName` (`"prism"`/`"modrinth"`).

**Root resolution (per OS), in priority order** — check `PRISM_LAUNCHER_DATA_DIR`
/ `THESEUS_CONFIG_DIR` first if set, then the candidates below; a candidate is a
root only if the directory exists:

| Kind | macOS | Linux | Windows |
|------|-------|-------|---------|
| Prism | `~/Library/Application Support/PrismLauncher` | `~/.local/share/PrismLauncher`, `~/.var/app/org.prismlauncher.PrismLauncher/data/PrismLauncher` | `%APPDATA%\PrismLauncher` |
| Modrinth | `~/Library/Application Support/ModrinthApp`, `…/com.modrinth.theseus` | `~/.local/share/ModrinthApp`, `…/com.modrinth.theseus` | `%APPDATA%\ModrinthApp`, `…\com.modrinth.theseus` |

**Profile enumeration:**
- Prism: for each dir in `<root>/instances/*`, if `<dir>/instance.cfg` exists →
  profile with `name = basename(dir)`, `gameDir = <dir>/minecraft` if that exists
  else `<dir>/.minecraft` if that exists else `<dir>/minecraft` (default; created
  on refresh).
- Modrinth: for each dir in `<root>/profiles/*` → profile with
  `name = basename(dir)`, `gameDir = <dir>`.

Scope decision (my call): enumerate **directory entries only**; a Prism dir
without `instance.cfg` is skipped (not an instance); a Modrinth `profiles/*` dir
is always a profile.

### Config changes (`src/config.zig`)

Add to `Config`:
```zig
/// The profile the user picked, for display. minecraftDir stays authoritative.
selectedProfile: ?ProfileRef = null,
```
```zig
pub const ProfileRef = struct {
    kind: []const u8,      // "prism" | "modrinth"
    name: []const u8,      // display label (folder name)
    gameDir: []const u8,   // absolute; equals minecraftDir when set via a pick
};
```
`minecraftDir` remains the single source of truth for where mods go — selecting a
profile just sets it. Persisted as today (pretty JSON); the new field is optional
with a default, so pre-existing configs load unchanged. Absent field = manual path.

### App/bridge changes (`src/app.zig`)

New bound JS function:
```zig
listLaunchers() -> JSON
// { "profiles": [ {kind,name,gameDir,root}, ... ], "errors": [ "..." ] }
// `errors` lists roots that existed but could not be read (so "no launchers"
// and "permission denied" aren't indistinguishable to the user).
```
Because discovery touches the filesystem, it runs once per call (cheap: a few
`openDir` scans). Sibling to `setMinecraftDir`:
```zig
selectProfile(gameDir) -> "true"/"false"
```
**Identity is `gameDir`, not `name`** (see Decision 1). The callback sets
`minecraftDir = gameDir`, records `selectedProfile = {kind,name,gameDir}` for
display, and saves.

### Decisions on the builder-check questions

**D1 — Profile identity is `gameDir` (absolute), not `name`.** Folder names are
only unique within a root, and we support multiple roots per launcher (native +
Flatpak for Prism; `ModrinthApp` + legacy `com.modrinth.theseus`). So:
- `selectProfile(gameDir)` — the UI passes the row's `gameDir`.
- `ProfileRef` stores all three: `{ kind, name, gameDir }` — `gameDir` is the
  resolvable key, `name`/`kind` are for display.
- The "selected row" highlight compares `Config.minecraftDir == profile.gameDir`
  after normalizing both to absolute (see D3).

**D2 — Modrinth enumeration is one level: `profiles/*/`.** Verified against
Modrinth source: profiles are created as exactly one path component
(`instances_dir().join(path)`), the name sanitizer replaces `/`, so no nesting
is produced by the app. There is **no per-profile marker file on disk** — a
profile whose mods folder doesn't exist yet is still a real profile, so we do
**not** require `mods/` to exist. Enumerate every direct child directory of
`profiles/`. (A user-set custom `path` containing slashes is representable in the
DB but rare; documented as a known limitation, not handled.)

**D3 — Profile paths are stored absolute.** `findRoots` expands env/`~` to an
absolute root, so derived `gameDir`s are absolute and stored as-is. This is
deliberate: `Config.minecraftDir` may be a hand-typed `~`-literal, but a picked
profile is always absolute. The UI's selected-row match normalizes by expanding
a leading `~` on the config side before comparing.

**D4 — Prism instances without a game dir: list them anyway; `ensureModsDir`
creates `<gameDir>/mods` on refresh.** Chosen behaviour: if neither `minecraft/`
nor `.minecraft/` exists, `gameDir` = `<instance>/minecraft`. This does **not**
violate the no-metadata-writes non-goal — we never touch `instance.cfg` or
`mmc-pack.json`; Prism itself creates `minecraft/` on first launch, and creating
a `mods/` dir inside a game directory is exactly what modsync already does for
any manual path. An instance is only listed if `<instance>/instance.cfg` exists
(so we never list a stray directory).

**D5 — Discovery errors are collected, not swallowed silently.**
`listProfiles`/`discoverAll` `catch continue` per-root (one unreadable root does
not abort the whole scan), but each failure is recorded and surfaced in
`listLaunchers()`'s `errors` array. The UI shows "No launchers found" only when
`profiles` is empty *and* `errors` is empty; otherwise it shows the profiles it
found plus a short note about what couldn't be read.

### UI changes (`src/ui.html`)

Add a "Detected launchers" section above the folder input:
- On load (and a "Rescan" button), call `listLaunchers()`.
- Render grouped by `kind` (Prism / Modrinth), one row per profile: name (+ short
  gameDir), and a "Use" button → `selectProfile(kind, name)` then re-fetch state.
- Show "No launchers found" when the list is empty (manual path still works).
- If the current `minecraftDir` matches a detected profile's gameDir, mark that
  row as selected.

## Testing

- `launcher.zig` gets inline tests using a **fake launcher tree** built in a temp
  dir (like `install.zig`'s tests): create `<tmp>/PrismLauncher/instances/A/minecraft/mods`
  + `instance.cfg`, `<tmp>/ModrinthApp/profiles/B/mods`, then point the enumerators
  at the temp root (the `listProfiles(kind, root)` form makes this hermetic — the
  OS-specific `findRoots` is tested only for "returns empty when nothing exists").
- A test that Prism enumerates only dirs with `instance.cfg`.
- A test that Modrinth game dir == profile dir and Prism game dir == `<id>/minecraft`.
- Config round-trip keeps `selectedProfile`.

## What is left to the builder (me)

- Exact Windows path joining/`%APPDATA%` via the existing portable `getEnv`.
- Whether to also probe Scoop (`%HOMEPATH%\scoop\persist\prismlauncher`) — my
  call: skip for v1, note it.
- Reading `instance.cfg` for a nicer display name — my call: **skip**, use folder
  name (user approved).

## Risks

- Prism portable/Snap layouts are edge cases; we cover defaults + Flatpak, note
  the rest as future.
- Modrinth profile folders can be renamed in-app while the DB keeps the real
  name — acceptable, we show folder names by user's choice.
