# kDrive Arch package-first installer Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn the existing upstream fork into a compact Arch-family package repository with a versionless latest-release installer and verified systemd-user-only migration/rollback.

**Architecture:** Keep the official kDrive source as the pinned `PKGBUILD` source rather than vendoring the upstream multi-platform tree. Move the Arch builder, package metadata, and contract tests to a small root-level layout. Publish a stable release asset `install.sh`; it downloads the latest package-source archive, verifies `SHA256SUMS`, builds with `makepkg`, migrates legacy user state, and enables only the packaged user unit.

**Tech Stack:** Bash, makepkg/pacman, CMake, Conan 2, systemd user units, GitHub Actions releases.

**Spec:** `docs/superpowers/specs/2026-09-18-kdrive-arch-installer.md`

## Global Constraints

- Primary command: `curl -fL https://github.com/shubinlab/kdrive-arch/releases/latest/download/install.sh | bash`.
- Keep `pkgname=kdrive-native-arch` for this release.
- Build `RelWithDebInfo`; runtime excludes `.a`, public headers, debug sections, and Crashpad helper.
- Systemd user service is the only startup owner.
- Never delete kDrive account databases, caches, or synchronized folders.
- Preserve existing rollback tags and do not rewrite Git history.
- Do not run makepkg as root or install Conan into system Python.

---

### Task 1: Add failing package-first and installer contract tests

**Files:**
- Create: `tests/test-repository-contract.sh`
- Create: `tests/test-installer-contract.sh`

**Interfaces:**
- Tests consume root `PKGBUILD`, root `install.sh`, root `build/`, and root `tests/` paths.
- Tests produce non-zero exit status until the new root layout and installer options exist.

- [ ] **Step 1: Write the failing repository layout test**

Assert root `PKGBUILD`, `.SRCINFO`, `install.sh`, `build/build-package.sh`, `build/install.sh`, `build/arch-native-3.8.7.1.patch`, and `tests/test-pkgbuild-contract.sh` exist; assert `packaging/arch`, `infomaniak-build-tools`, and root `src` do not exist.

- [ ] **Step 2: Run the test and verify it fails**

Run: `bash tests/test-repository-contract.sh`
Expected: FAIL because the current package metadata is nested under `packaging/arch` and the upstream tree is still present.

- [ ] **Step 3: Write the failing installer contract test**

Assert `install.sh` has Bash strict mode, the stable release URL, `--dry-run`, `--verify`, `--rollback`, and `--uninstall` cases; reject versioned URLs, `--proto`, `--tlsv1.2`, and `--yes` in the public command documentation.

- [ ] **Step 4: Run the installer test and verify it fails**

Run: `bash tests/test-installer-contract.sh`
Expected: FAIL because root `install.sh` does not exist.

- [ ] **Step 5: Commit the red tests**

```bash
git add tests/test-repository-contract.sh tests/test-installer-contract.sh
git commit -m "test(arch): define package-first installer contract"
```

### Task 2: Move the package implementation to the root layout

**Files:**
- Move: `packaging/arch/PKGBUILD` -> `PKGBUILD`
- Move: `packaging/arch/.SRCINFO` -> `.SRCINFO`
- Move: `packaging/arch/kdrive-native-arch.in` -> `kdrive-native-arch.in`
- Move: `packaging/arch/kdrive-native-arch.service.in` -> `kdrive.service`
- Move: `packaging/arch/check-package.sh` -> `tests/check-package.sh`
- Move: `packaging/arch/tests/*` -> `tests/*`
- Move: `infomaniak-build-tools/linux/arch-native/*` -> `build/*`
- Modify: `PKGBUILD`
- Modify: `.github/workflows/arch-package-contract.yml`

**Interfaces:**
- `PKGBUILD` invokes `build/build-package.sh` and installs `kdrive.service`.
- Existing runtime contract tests continue to accept the same runtime bundle.

- [ ] **Step 1: Move files without changing behavior**

Use `git mv` for the package and builder files, then update only path references in `PKGBUILD` and the workflow.

- [ ] **Step 2: Run shell syntax and metadata tests**

Run: `bash -n PKGBUILD tests/*.sh build/*.sh && makepkg --printsrcinfo --dir .`
Expected: syntax succeeds and `.SRCINFO` output matches after regeneration.

- [ ] **Step 3: Fix the Conan path contract**

Make `build/build-package.sh` register the local recipe directory as an isolated `localrecipes` remote and pass `-r=localrecipes -r=conancenter`; set a pinned Conan version variable and an isolated `CONAN_HOME`.

- [ ] **Step 4: Add the minimal Conan lock/manifest check**

Fail with an actionable error if the release source lacks the exact dependency manifest required by the Arch build. Do not silently use a pre-existing global Conan cache.

- [ ] **Step 5: Run contract tests**

Run: `bash tests/test-pkgbuild-contract.sh PKGBUILD && bash tests/test-build-output-contract.sh build/build-package.sh && bash tests/test-desktop-contract.sh <(printf ...)`
Expected: PASS.

- [ ] **Step 6: Commit the root package layout**

```bash
git add PKGBUILD .SRCINFO kdrive-native-arch.in kdrive.service build tests .github/workflows/arch-package-contract.yml
git commit -m "refactor(arch): make package layout root-first"
```

### Task 3: Implement the stable latest-release installer

**Files:**
- Create: `install.sh`
- Modify: `tests/test-installer-contract.sh`
- Create: `tests/fixtures/manifest.env`

**Interfaces:**
- `install.sh --dry-run|--verify|--rollback|--uninstall|--no-start`.
- Environment overrides `KDRIVE_INSTALL_REPO`, `KDRIVE_RELEASE_BASE_URL`, and `KDRIVE_INSTALL_ROOT` exist only for tests and are not required in the public command.

- [ ] **Step 1: Implement preflight and source download**

Check non-root execution, `x86_64`, `/etc/os-release` with Arch in `ID`/`ID_LIKE`, `makepkg`, `pacman`, `curl`, writable state/cache directories, and a user systemd bus. Download `kdrive-arch-source.tar.gz` and `SHA256SUMS` from `releases/latest/download/`; verify the source checksum before extraction.

- [ ] **Step 2: Implement local package build/install**

Run `makepkg --syncdeps --install` as the normal user from the extracted root. Keep the generated package in `$XDG_STATE_HOME/kdrive-arch/packages/` before installation. Never run `makepkg` through sudo.

- [ ] **Step 3: Implement migration with rollback state**

Before package activation, snapshot and disable any user `kdrive.service` fragment under `$XDG_CONFIG_HOME/systemd/user/`, existing launcher links, and kDrive autostart desktop files. On failure, restore the snapshot and reload the user manager.

- [ ] **Step 4: Implement service activation and verification**

Reload the user manager, enable/start `kdrive.service` unless `--no-start`, then verify the fragment path is `/usr/lib/systemd/user/kdrive.service`, the service is active when requested, and the executable resolves under `/opt/kdrive-native-arch/<version>/`.

- [ ] **Step 5: Implement rollback/uninstall**

Rollback selects the newest saved package, runs `pacman -U` with authorization, restores the previous migration state, and never removes account or sync data. Uninstall disables the service and removes only package-owned files.

- [ ] **Step 6: Run installer tests**

Run: `bash tests/test-installer-contract.sh`
Expected: PASS with no network or root access by using fixture URLs and dry-run mode.

- [ ] **Step 7: Commit the installer**

```bash
git add install.sh tests/test-installer-contract.sh tests/fixtures/manifest.env
git commit -m "feat(arch): add stable latest-release installer"
```

### Task 4: Reduce the public repository surface

**Files:**
- Modify: `README.md`
- Modify: `THIRD_PARTY_NOTICES.md`
- Modify: `.gitignore`
- Modify: `.github/workflows/arch-package-contract.yml`
- Delete: upstream multi-platform source, internal `AGENTS.md`, `docs/superpowers`, and unrelated upstream workflows/actions.
- Create: `.github/CONTRIBUTING.md`
- Create: `.github/SECURITY.md`
- Create: `.github/SUPPORT.md`

**Interfaces:**
- README contains one install command, one update command, verify/rollback commands, compatibility boundary, and concise Sentry policy.
- CI references only root package/build/test paths.

- [ ] **Step 1: Rewrite README package-first**

Use the stable command without `--proto`, `--tlsv1.2`, `-s`, `--`, or `--yes`. Keep advanced flags in a short optional block. Remove duplicated upstream product documentation and legacy installer walkthrough.

- [ ] **Step 2: Correct notices**

Document actual Arch runtime dependencies and the exact Sentry 0.7.10/compile-time-disabled policy; remove claims that Crashpad is redistributed.

- [ ] **Step 3: Remove non-package files**

Delete only tracked upstream multi-platform files after verifying the root package source is fetched by `PKGBUILD`; preserve `LICENSE`, release tags, and Git history.

- [ ] **Step 4: Keep only package CI**

Retain contract workflow and issue templates; remove upstream macOS/Windows/release workflows that do not describe this package.

- [ ] **Step 5: Run link and content checks**

Run a relative-link checker over README and notices, `git diff --check`, shell syntax checks, and the repository contract tests.

- [ ] **Step 6: Commit the public surface cleanup**

```bash
git add -A
git commit -m "docs(arch): simplify public package repository"
```

### Task 5: Add release asset workflow and verify on clean Arch

**Files:**
- Create: `.github/workflows/release-arch.yml`
- Modify: `.github/workflows/arch-package-contract.yml`
- Create: `release/SHA256SUMS` generation step in workflow only

**Interfaces:**
- Tagged release publishes `install.sh`, package-source archive, and `SHA256SUMS`.
- `releases/latest/download/install.sh` is the stable public entry point.

- [ ] **Step 1: Add release packaging job**

On an `arch-*` tag, create the package-source archive from the clean package tree, generate `SHA256SUMS`, and upload both plus `install.sh` as release assets.

- [ ] **Step 2: Add clean-container metadata verification**

Run `makepkg --printsrcinfo`, shell checks, relative-link checks, and package contract tests in `archlinux:base-devel` without relying on the host Conan cache.

- [ ] **Step 3: Run local release dry-run**

Build the source archive and checksum in a temporary directory, run `install.sh --dry-run` with fixture URLs, and verify the archive checksum and selected release metadata.

- [ ] **Step 4: Run project checks**

Run `git diff --check`, the complete contract suite, and `./tools/ci-check.sh` only if the workspace repository contains that script and the changed files are in its scope.

- [ ] **Step 5: Commit release automation**

```bash
git add .github/workflows/release-arch.yml .github/workflows/arch-package-contract.yml
git commit -m "ci(arch): publish latest-release installer assets"
```

## Verification checklist

- `bash -n` passes for every shell file in root, `build/`, `tests/`, and `.github` scripts.
- Root package metadata and `.SRCINFO` agree.
- No package branch file references deleted `packaging/arch` or `infomaniak-build-tools` paths.
- README contains exactly one canonical install command and no versioned installer URL.
- Relative README/notices links resolve.
- Installer dry-run, verify, rollback, and uninstall contracts pass without root.
- Clean Arch container metadata checks pass without a pre-existing Conan cache.
- Actual host package build/install/verify is run before publishing completion claims.
