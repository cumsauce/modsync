# modsync CI & Release Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Publish `modsync` to `github.com/cumsauce/modsync` and add CI that builds per-platform binaries and attaches them to tagged GitHub Releases.

**Architecture:** Make `build.zig` link each platform's native webview libs behind per-OS guards (macOS already done; add Linux + Windows). Add a GitHub Actions workflow with a test job and a tag-triggered release matrix. Push to a new public repo.

**Tech Stack:** Zig 0.17.0, vendored webview/webview, GitHub Actions, `mlugg/setup-zig`, `gh` CLI.

**Spec:** `docs/superpowers/specs/2026-10-16-modsync-ci-design.md`

## Global Constraints

- Zig 0.17.0 exactly (`build.zig.zon` minimum_zig_version).
- Release assets: `modsync-macos-arm64`, `modsync-linux-x86_64`, `modsync-windows-x86_64.exe`.
- Test job: `zig build test` must stay green (28/28). Compile job runs on all 3 OSes.
- macOS verified by launching the binary; Linux/Windows verified by successful link only.
- Repo: `github.com/cumsauce/modsync`, public. Branch `modsync-build` → `main`.
- No committed build outputs. No secrets in the repo (gh auth handles tokens).

## Review Focus

- `build.zig` per-OS guards must not regress macOS (the verified target).
- CI must fail loudly on a broken build, never green-with-missing-artifact.
- The Linux link-flag set is empirical; iterate on real runner logs.
- Windows: confirm whether webview needs explicit `linkSystemLibrary` calls.
- Tests using `/tmp` may be OS-specific; keep the test job scoped if so.

---

### Task 1: Make build.zig platform-portable

**Files:**
- Modify: `build.zig`
- Modify: `build.zig.zon` (drop/replace missing LICENSE entry)
- Create: `LICENSE` (MIT)

**Interfaces:**
- Produces: `zig build -Doptimize=ReleaseSafe` links cleanly on macOS; Linux/Windows guards added.

- [ ] **Step 1:** Add `LICENSE` (MIT, copyright cumsauce) and keep `"LICENSE"` in `build.zig.zon` `.paths`. Also add `"README.md"` to `.paths`.
- [ ] **Step 2:** In `build.zig`, replace the macOS-only `if` with a per-OS block:
  - macOS: WebKit, Cocoa, objc (unchanged).
  - Linux: `linkSystemLibrary("webkit2gtk-4.1")`, `"gtk-3"`, `"gobject-2.0"`, `"glib-2.0"`, `"javascriptcoregtk-4.1"` (each `.{}`), plus `linkSystemLibrary("pthread")` if needed.
  - Windows: add any `linkSystemLibrary` webview requires (start with none; add if CI link fails — win32 loads WebView2 at runtime).
- [ ] **Step 3:** `zig build` (macOS) → exit 0, binary unaffected.
- [ ] **Step 4:** `zig build test` → 28/28 still green.
- [ ] **Step 5:** Commit.

### Task 2: CI workflow

**Files:**
- Create: `.github/workflows/ci.yml`

**Interfaces:**
- Consumes: Task 1's build.zig.
- Produces: green checks on push/PR; release assets on `v*` tag.

- [ ] **Step 1:** Job `test` (matrix macos-14, ubuntu-latest, windows-latest): checkout, setup-zig 0.17.0, install Linux deps on ubuntu (`libgtk-3-dev libwebkit2gtk-4.1-dev`), run `zig build test` (or `zig build` on non-mac if tests are OS-specific — decide from the first run).
- [ ] **Step 2:** Job `release` (`if: startsWith(github.ref, 'refs/tags/v')`, `needs: test`): matrix over the 3 OSes; checkout, setup-zig, install Linux deps, `zig build -Doptimize=ReleaseSafe`, rename the binary per platform, `actions/upload-artifact`.
- [ ] **Step 3:** Job `publish` (needs release, `permissions: contents: write`): `actions/download-artifact`, then `gh release create "$TAG" <files> --title ... --notes ...` with `GH_TOKEN`.
- [ ] **Step 4:** Validate YAML locally (`python3 -c "import yaml,sys;yaml.safe_load(open('.github/workflows/ci.yml'))"`). Commit.

### Task 3: Create repo, push, tag, verify CI

**Files:** none (git/gh operations)

- [ ] **Step 1:** `gh repo create cumsauce/modsync --public --source=. --remote=origin` (or `--push`).
- [ ] **Step 2:** Push `modsync-build` → `main`; ensure default branch is `main`.
- [ ] **Step 3:** Watch the `test` job go green (`gh run watch`).
- [ ] **Step 4:** Tag `v0.1.0`, push tag; watch the release job.
- [ ] **Step 5:** Iterate on link flags / apt packages until all 3 platform builds succeed.
- [ ] **Step 6:** Confirm the release has 3 assets; verify the macOS asset by downloading and launching it.
- [ ] **Step 7:** Report the release URL.

---

## Execution note

Tasks 1-2 are code (TDD-ish: build + test gate). Task 3 is empirical — it will
loop on real CI logs until green. Task 3 is where most of the work is.
