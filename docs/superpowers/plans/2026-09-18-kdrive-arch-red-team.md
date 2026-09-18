# kDrive Arch Red-Team Hardening Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the Arch-only repository and latest installer resistant to hostile release archives while proving that cross-platform upstream code is not shipped in the Arch source payload.

**Architecture:** Use `kdrive-arch` as the pacman identity, migrate the former `kdrive-native-arch` package once, and add a strict archive-validation boundary to `install.sh`. Add shell contract/red-team fixtures that operate entirely under temporary directories, plus an Arch-scope check over the repository/archive surface.

**Tech Stack:** Bash, GNU tar, coreutils, makepkg/pacman contracts, systemd user-unit stubs, GitHub release archive fixtures.

**Spec:** `docs/superpowers/specs/2026-09-18-kdrive-arch-red-team-design.md`

## Global Constraints

- Use `pkgname=kdrive-arch`; migrate the old `kdrive-native-arch` package once
  and preserve its rollback cache/state.
- Keep official upstream commit `b14222be555cc9f934e9ed2ec7bb36beb9c437a5`.
- Keep systemd as the only startup owner and preserve rollback state.
- Never modify the host package database or user service during sandbox tests.
- Reject unsafe tar members before extraction.

### Task 1: Establish red-team fixtures

**Files:**
- Create: `tests/test-installer-redteam.sh`
- Modify: `tests/test-repository-contract.sh`

- [x] Write failing tests for traversal and symlink release archives, using a
  temporary `KDRIVE_RELEASE_BASE_URL=file://...`, checksum manifests, and a
  marker outside the extraction directory.
- [x] Run the red-team test and confirm the current installer extracts or
  accepts at least one hostile fixture.
- [x] Add an Arch-scope assertion that tracked files and the generated source
  archive contain no Swift/macOS/Windows/Android source paths.
- [x] Add a package-identity assertion that every active package/service/
  installer reference uses `kdrive-arch` and that old-name references appear
  only in the explicit migration path and historical documentation.
- [x] Run the tests again and record the expected failures before changing the
  installer.

### Task 2: Harden release archive handling

**Files:**
- Modify: `install.sh:150-180`
- Modify: `tests/test-installer-contract.sh`

- [x] Add a validator that checks every tar member for one exact
  `kdrive-arch/` root, no absolute or `..` path component, no control bytes,
  and no symlink/hardlink entries.
- [x] Extract with `--no-same-owner --no-same-permissions` and verify the
  resolved `SOURCE_ROOT` remains below `TEMP_ROOT`.
- [x] Add static contract assertions for the validator and safe tar flags.
- [x] Run traversal, symlink, checksum, and normal dry-run fixtures; confirm
  the hostile cases fail before `PKGBUILD` is executed.

### Task 3: Sandbox install/rollback boundary

**Files:**
- Modify: `tests/test-installer-redteam.sh`
- Modify: `README.md`

- [x] Stub only `makepkg`, `pacman`, and `systemctl` inside a temporary PATH;
  redirect `HOME`, XDG paths, and `KDRIVE_INSTALL_ROOT` to the sandbox.
- [x] Exercise normal install with `--no-start`, failed download, and rollback
  state capture; assert no file appears outside the sandbox and the old unit
  and autostart files are restored.
- [x] Document `--dry-run`, `--verify`, and rollback as explicit safe checks,
  while keeping the main one-line install command unchanged.

### Task 4: Verify and publish

**Files:**
- Modify: `.github/workflows/arch-package-contract.yml`
- Modify: `.github/workflows/release-arch.yml`

- [x] Run shell syntax, all contract/red-team tests, source archive inspection,
  `makepkg --nobuild --nodeps --cleanbuild`, and `git diff --check`.
- [x] Reuse the previously verified full native build for the unchanged
  upstream/build recipe; verify the current rename and packaging boundary with
  `makepkg --nobuild --nodeps --cleanbuild` and the complete contract suite.
- [x] Commit focused changes, push a new `kdrive-arch-*` tag without moving old
  rollback tags, and verify the release assets plus green CI.
