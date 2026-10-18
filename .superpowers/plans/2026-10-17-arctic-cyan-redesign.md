# Arctic Cyan Redesign — Implementation Plan

**Source spec**: `.superpowers/specs/2026-10-17-figma-arctic-cyan-spec.md` (extracted from Figma file `9OIjkFQ4Eikr7yoPTkFpqB`)
**User decision**: "Everything in one pass" — full contract including new Zig bindings and staged update pipeline.
**Target release**: v0.7.0 (major UI + capability release)

---

## Current Architecture (from survey)

### Bridge bindings (src/app.zig)
- `getConfig` → `jsGetConfig` — returns saved Minecraft dir + tracked repos as JSON
- `setMinecraftDir` → `jsSetMinecraftDir` — updates config, reloads launcher list
- `addRepo` → `jsAddRepo` — validates owner/name, fetches latest release, adds to config
- `removeRepo` → `jsRemoveRepo` — removes from tracked repos
- `startRefresh` → `jsStartRefresh` — spawns thread, fetches latest for all repos
- `listLaunchers` → `jsListLaunchers` — detects Prism/Modrinth/custom installs
- `selectProfile` → `jsSelectProfile` — switches active install folder
- `restoreDefaults` → `jsRestoreDefaults` — resets to seeded repos

### State JSON shape (buildStateJson in app.zig)
```json
{
  "minecraftDir": "~/Library/...",
  "repos": [
    {
      "owner": "cumsauce",
      "name": "foley",
      "installed": true,
      "latest": true,
      "status": "up to date",
      "installedVersion": "v2.0.0",
      "latestVersion": "v2.0.0"
    }
  ]
}
```

### Threading model
- `startRefresh` calls `std.Thread.spawn(.{}, refreshWorker, .{...})` with `detach()`
- Worker loops over `config.repos` sequentially, calls `net.fetchLatestRelease(owner, name)`
- After each repo, acquires mutex, updates `statuses[i]`, calls `webview_dispatch(.{ pushStateToWebview })`
- `pushStateToWebview` evals `renderState({...})` into the page

### net.zig capabilities
- `fetchLatestRelease(owner, name)` → GitHub API, returns release struct
- `downloadJar(url, dest_path)` → HTTP download to temp file
- `replaceJarAtomic(temp_path, final_path)` → rename() with rollback on failure
- NO system browser opening
- NO clipboard operations

### Seeded repos (config.zig seed_defaults)
```zig
.{ .owner = "cumsauce", .name = "gore" },
.{ .owner = "cumsauce", .name = "foley" },
.{ .owner = "cumsauce", .name = "earshot" },
.{ .owner = "cumsauce", .name = "stalker" },
.{ .owner = "cumsauce", .name = "aorta" },
.{ .owner = "desocketed", .name = "yakvc" },
```

---

## Phase 1: Backend (src/app.zig + src/net.zig)

**Goal**: Add new bridge bindings, implement staged update pipeline, extend state JSON.

### 1.1 New bridge bindings (additive)

Add these to `webview_bind`:
- `updateRepo(owner, name)` — scoped per-repo update with staged progress
- `installRepo(owner, name)` — install missing mod (wrapper around updateRepo with different status tracking)
- `retryRepo(owner, name)` — retry failed update (same as updateRepo, clears error state)
- `openUrl(url)` — open URL in system browser (platform-specific: `open` on macOS, `xdg-open` on Linux, `start` on Windows)
- `copyToClipboard(text)` — copy text to clipboard (platform-specific: NSPasteboard on macOS, xclip/pbcopy on Linux, clip.exe on Windows)
- `validateFolder(path)` — check if folder exists and is writable, return JSON `{valid: bool, error?: string}`

### 1.2 Staged update pipeline

**New state**: `RepoStage` enum in app.zig
```zig
const RepoStage = enum {
    idle,
    checking,
    downloading,
    installing,
    success,
    error,
};
```

**Extend `RepoStatus`**:
```zig
const RepoStatus = struct {
    owner: []const u8,
    name: []const u8,
    installed: bool = false,
    latest: bool = false,
    status: []const u8 = "",
    installed_version: ?[]const u8 = null,
    latest_version: ?[]const u8 = null,
    stage: RepoStage = .idle,  // NEW
    error: ?[]const u8 = null,  // NEW: detailed error message
};
```

**New update worker**: `updateRepoWorker(owner, name, single_repo: bool)`
- If `single_repo: false` (Update all): loop over all repos sequentially
- For each repo:
  1. Set `stage = .checking`, push state
  2. Call `net.fetchLatestRelease(owner, name)`
  3. If already up to date: `stage = .success`, continue
  4. Set `stage = .downloading`, push state
  5. Call `net.downloadJar(url, temp_path)`
  6. Set `stage = .installing`, push state
  7. Call `net.replaceJarAtomic(temp_path, final_path)`
  8. Set `stage = .success`, update `installed_version`, push state
  9. On any error: `stage = .error`, set `error` field, push state

**Batch completion**: For Update all, preserve pre-run versions/counts during the run, publish one coherent snapshot when the batch completes. Individual successes are retained even if another task fails.

**Lock conflicting writes**: While updates run, block install switching with message "Install can't be changed while updates are running." Disable repeated Update all and conflicting per-row writes/removal. Read-only GitHub/Copy may remain available.

### 1.3 State JSON extension

Add to `buildStateJson`:
- `repos[].stage` — string: "idle", "checking", "downloading", "installing", "success", "error"
- `repos[].error` — string or null, detailed error message
- `repos[].availableVersion` — string or null, for missing mods showing "Available release v1.0.3"
- Top-level `updating: bool` — true while any update is running

### 1.4 Platform-specific helpers

**src/os.zig** (new file):
- `openUrl(url: []const u8) !void` — platform-specific system browser opening
- `copyToClipboard(text: []const u8) !void` — platform-specific clipboard write
- `validateFolderWritable(path: []const u8) !bool` — check write access

Use `builtin.os.tag` to branch:
- macOS: `open`, NSPasteboard (requires linking AppKit — already done for webview)
- Linux: `xdg-open`, `xclip` or `wl-copy`
- Windows: `start`, `clip.exe`

Fallback: If platform helper not available, return error and show "Couldn't open browser" / "Couldn't copy" in UI.

### 1.5 Tests

Add tests for:
- `RepoStage` enum serialization
- `updateRepoWorker` stage transitions (mock net layer)
- `validateFolder` with real temp directories
- `buildStateJson` includes new fields

Target: 39 existing tests + ~8 new tests = 47 tests

---

## Phase 2: Frontend (src/ui.html)

**Goal**: Full rewrite matching Figma spec.

### 2.1 Palette

Replace violet with Arctic Cyan:
```css
--bg: #090D10;
--titlebar: #0D1317;
--field: #111B21;
--tile: #171F25;
--line: #263B44;        /* picker border */
--input-border: #303D43;
--primary: #00C8F247;   /* cyan ~28% alpha */
--primary-border: #28505E;
--text: #F3F1FA;
--dim: #A7A7B5;
--faint: #8E8E96;
--chevron: #9ABFCB;
--latest: #22C55E;
--outdated: #F6B84D;
--missing: #F9708A;
--keyline: #FFFFFF14;
--tile-border: #333337;
--focus: #80D5EC;
```

Keep Inter woff2 embedded.

### 2.2 Dimensions

```css
--titlebar-h: 34px;
--install-h: 76px;
--toolbar-h: 56px;
--tools-h: 88px;
--inset: 20px;
--picker-w: 480px;
--picker-h: 56px;
--row-h: 40px;
--tile-size: 24px;
--edge-w: 2px;
--edge-h: 25px;
--control-h: 32px;
--radius: 4px;
--row-gap: 10px;
--section-gap: 14px;
--input-add-gap: 8px;
```

### 2.3 DOM structure

```html
<body>
  <div class="chrome">
    <header class="topbar">
      <span class="side-spacer"></span>
      <h1 class="wordmark">modsync</h1>
      <span class="side-spacer"></span>
    </header>
    
    <section class="install-section">
      <div class="install-picker" id="installToggle" role="button" aria-haspopup="listbox">
        <div class="install-identity">
          <span class="install-label">MINECRAFT INSTALL</span>
          <span class="install-path" id="installValue">~/Library/...</span>
        </div>
        <svg class="chevron" id="installChevron">...</svg>
      </div>
      <div class="install-menu" id="installMenu" hidden>
        <div class="install-list" id="installList" role="listbox"></div>
        <div class="install-footer">
          <label class="footer-label" for="folder">Or use a folder path</label>
          <div class="footer-row">
            <input class="input" id="folder" type="text" />
            <button class="btn" id="saveFolder">Save</button>
          </div>
          <button class="btn-ghost" id="rescan">Rescan</button>
        </div>
      </div>
    </section>
    
    <section class="toolbar">
      <div class="list-summary">
        <h2 class="heading">Tracked mods</h2>
        <span class="installed-count" id="summary">0 of 0 installed</span>
      </div>
      <button class="btn-primary" id="refresh" style="min-width: 98px">Update all</button>
    </section>
    
    <main class="status-sections" id="list">
      <!-- Populated by renderList: groups by status -->
    </main>
    
    <section class="repository-tools">
      <div class="add-row">
        <input class="input" id="new-repo" placeholder="owner/name" />
        <button class="btn" id="add">Add</button>
      </div>
      <div class="state-summary" id="stateSummary"></div>
    </section>
  </div>
  
  <!-- Remove confirmation modal -->
  <div class="modal-backdrop" id="removeModal" hidden>
    <div class="modal" role="dialog" aria-labelledby="modalTitle">
      <h3 id="modalTitle">Remove from tracking?</h3>
      <p id="modalBody">This will stop tracking owner/name. Installed files are kept.</p>
      <div class="modal-actions">
        <button class="btn-ghost" id="cancelRemove">Cancel</button>
        <button class="btn-danger" id="confirmRemove">Remove</button>
      </div>
    </div>
  </div>
  
  <!-- Row menu (context-sensitive, positioned absolutely) -->
  <div class="row-menu" id="rowMenu" hidden role="menu"></div>
</body>
```

### 2.4 Row structure

```html
<div class="status-section">
  <div class="section-caption">
    <span class="state-heading">Up to date</span>
    <span class="section-count">4</span>
  </div>
  <div class="mod-row" data-owner="cumsauce" data-name="foley">
    <span class="status-edge" style="background: var(--latest)"></span>
    <div class="icon-tile">
      <svg class="glyph">...</svg>
    </div>
    <span class="identity">cumsauce/foley</span>
    <span class="version">v2.0.0</span>
    <button class="row-menu-trigger" aria-label="Actions for cumsauce/foley">⋯</button>
  </div>
</div>
```

For missing mods:
```html
<div class="mod-row" data-status="missing">
  <span class="status-edge" style="background: var(--missing)"></span>
  <div class="icon-tile">
    <svg class="glyph">...</svg>
  </div>
  <span class="identity">cumsauce/earshot</span>
  <div class="available-release">
    <svg class="download-glyph">...</svg>
    <span class="available-version">v1.0.3</span>
  </div>
  <button class="row-menu-trigger">⋯</button>
</div>
```

### 2.5 Grouping logic (renderList)

Change from grouping by owner to grouping by status:
1. Compute status for each repo: `latest`, `outdated`, `missing`, `error`, `not checked`
2. Group into sections: "Up to date", "Update available", "Not installed", "Not checked", "Errors"
3. Each section gets a caption with state heading + count
4. Sections appear in priority order: Errors → Update available → Not installed → Not checked → Up to date
5. Only render non-empty sections

### 2.6 Context-sensitive row menu

On ⋯ click:
1. Build menu items based on repo status:
   - Outdated: `Update mod` / View on GitHub / Copy repo name / Remove from tracking…
   - Missing: `Install mod` / View on GitHub / Copy repo name / Remove from tracking…
   - Error: `Retry` (default focus) / View on GitHub / Copy repo name / Remove from tracking…
   - Latest: View on GitHub / Copy repo name / Remove from tracking…
   - No install selected: View on GitHub / Copy repo name / Remove from tracking…
2. Position menu inside window, flip upward near bottom edge
3. Wire up actions:
   - Update/Install/Retry → call `updateRepo(owner, name)`
   - View on GitHub → call `openUrl("https://github.com/" + owner + "/" + name)`
   - Copy repo name → call `copyToClipboard(owner + "/" + name)`, announce "Copied owner/name"
   - Remove from tracking… → open confirmation modal

### 2.7 Remove confirmation modal

On "Remove from tracking…":
1. Set modal body: `This will stop tracking owner/name. Installed files are kept.`
2. Store owner/name in data attribute
3. Show modal, focus Cancel button
4. On Cancel/Escape: hide modal, return focus to ⋯ trigger
5. On Remove: call `removeRepo(owner, name)`, hide modal, focus next row's ⋯ or list heading

### 2.8 Add repo validation

On Add button click or Enter in input:
1. **Normalize**: trim whitespace; if exact `https://github.com/owner/name` URL, convert to `owner/name`; reject non-GitHub URLs and extra path/query
2. **Validate syntax**: owner and name segments must be valid (alphanumeric, hyphens)
3. **Check duplicate**: case-insensitive comparison against existing repos
4. **Pending**: disable Add button, show "Adding…", call `addRepo(owner, name)`
5. **Success**: clear input, announce "Repository added", show "Checking…" until status known
6. **Failure**: preserve input AND focus, show specific inline message:
   - Malformed: `Use owner/name, for example cumsauce/newmod.`
   - Already tracked: `This repository is already tracked.`
   - Not found: `Repository not found or unavailable. Check owner/name.`
   - No compatible jar: `No compatible .jar release found for this install.`
   - Rate limit: `GitHub rate limit reached. Try again after [reset time].`
   - Offline: `Couldn't reach GitHub. Check your connection and retry.`

### 2.9 Install picker with pinned footer

- Overlay at picker's 20px inset, 480px wide, below trigger
- Overlays toolbar/list, **never pushes content down**
- Structure: scrollable list (max-height 240px) + pinned footer (never scrolls)
- Footer: separator, "Or use a folder path" label, path input, Save, Rescan
- Options: primary name + secondary launcher/source metadata (e.g. `Modrinth · minecraft (1)`)
- Selected: tinted fill + check + `aria-current="true"`
- Keyboard: arrows navigate, Enter commits, Escape/outside discards unapplied input
- Save enabled only for nonempty valid folder (validate before enabling)
- Rescan: show "Scanning…" while detecting, prevent duplicate scans

### 2.10 Accessibility

- Tab order: install selector → Update all → row menu triggers → add input → Add
- Focus-visible: 2px cyan ring (#80D5EC) on all interactive elements
- Disabled controls: expose reason via `aria-description` ("Select an install first", "Update in progress", validation reason)
- Menus: `role="menu"`, `aria-expanded`, `aria-haspopup="menu"` on trigger
- Listbox: `role="listbox"`, `aria-selected`, `aria-activedescendant`
- Modal: `role="dialog"`, `aria-modal="true"`, focus trap inside modal only
- Live regions: `aria-live="polite"` for status updates, `aria-live="alert"` for blocking errors
- Tooltips: show on keyboard focus, not just hover
- On truncation: expose full owner/name, path, source, version via `title` and `aria-label`

### 2.11 Icon tiles

Add inline SVGs for per-repo glyphs (or letter fallback):
- Waveform (foley)
- Door (doorswing)
- Ear (earshot)
- Droplet (stalker)
- Letter fallback: first letter of repo name for others

### 2.12 Update all / Updating…

- On Update all click: call `startRefresh()`, show "Updating…", disable button
- During run: preserve pre-run versions/counts, publish one coherent snapshot at batch completion
- Lock install switching with message "Install can't be changed while updates are running."
- On completion: re-enable button, restore "Update all" label

### 2.13 Per-row progress

During update, show stage in row:
- Checking: show "Checking…" text
- Downloading: show "Downloading…" text
- Installing: show "Installing…" text
- Success: show new version, update status edge
- Error: show error message in red, status edge coral

### 2.14 Tests

Manual testing checklist:
- [ ] Resting state shows 6 repos grouped by status
- [ ] Update all button shows "Updating…" and disables during run
- [ ] Row ⋯ menu shows correct items for each status
- [ ] View on GitHub opens browser
- [ ] Copy repo name copies to clipboard
- [ ] Remove opens confirmation modal, Cancel/Escape dismisses
- [ ] Remove confirm removes repo and regroups
- [ ] Add repo validates syntax, rejects duplicates
- [ ] Install picker overlay doesn't push content down
- [ ] Pinned footer stays visible while scrolling options
- [ ] Save disabled until valid folder path entered
- [ ] Rescan shows "Scanning…" and prevents duplicate scans
- [ ] Tab order follows visual order
- [ ] Focus-visible cyan ring on all interactive elements
- [ ] Modal traps focus, Escape dismisses
- [ ] Live regions announce status updates
- [ ] No console errors, all bridge calls succeed
- [ ] Screenshot matches Figma frame 01 (Resting)

---

## Phase 3: Verification + Release

1. Run `zig build test --summary all` — expect 47/47 tests pass
2. Build app: `bash scripts/make-icon.sh build && bash scripts/make-app.sh zig-out/bin/modsync 0.7.0 dist`
3. Run app, take screenshot, compare to Figma frame 01
4. Manual test checklist (above)
5. Commit with trailer: `Co-authored-by: mimo-v2.6-flash <noreply@opencode.ai>`
6. Tag: `v0.7.0`
7. Push: `git push origin HEAD:main && git push origin v0.7.0`
8. Verify release: `gh release view v0.7.0`

---

## Files to Modify

- **src/app.zig**: Add 6 new bridge bindings, extend RepoStatus/RepoStage, rewrite updateRepoWorker, extend buildStateJson
- **src/net.zig**: Add temp file download helper if missing, expose error details
- **src/os.zig** (new): Platform-specific openUrl, copyToClipboard, validateFolderWritable
- **src/config.zig**: No changes (seeded repos unchanged)
- **src/ui.html**: Full rewrite (~1200 lines, up from ~950)
- **build.zig**: Add linking for AppKit on macOS if needed for clipboard (may already be linked for webview)

---

## Risks

1. **Platform-specific clipboard/browser code**: May need to link additional frameworks or spawn external processes. Fallback: show "Feature not available on this platform" if implementation fails.

2. **Thread safety**: Staged updates require more frequent state pushes. Ensure mutex protects all status mutations.

3. **Test coverage**: New tests for staged pipeline may be complex. Use mock net layer to simulate failures.

4. **UI complexity**: 1200-line single HTML file is large but necessary for self-contained constraint. Keep CSS organized with clear sections.

5. **Backward compatibility**: Existing config files must still load. New fields have sensible defaults (stage: idle, error: null).

---

## Success Criteria

- [ ] All 47 tests pass
- [ ] Build succeeds on macOS
- [ ] App launches and shows Arctic Cyan theme
- [ ] Mods grouped by status, not author
- [ ] Status edges, icon tiles, ⋯ menus all functional
- [ ] Update all runs staged pipeline with progress
- [ ] Remove confirmation modal works
- [ ] Add repo validation rejects duplicates and malformed input
- [ ] Install picker has pinned footer with Save/Rescan
- [ ] Accessibility: keyboard navigation, focus rings, ARIA roles
- [ ] Screenshot matches Figma frame 01
- [ ] v0.7.0 tagged and released with assets
