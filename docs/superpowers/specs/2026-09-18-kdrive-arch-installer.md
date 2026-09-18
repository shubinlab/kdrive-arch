# kDrive Arch package-first installer

## Goal

Provide a small Arch-family package repository with one stable installer URL that always selects the latest verified release while preserving local rollback and the systemd-user-only lifecycle.

## User contract

The primary command is:

```bash
curl -fL https://github.com/shubinlab/kdrive-arch/releases/latest/download/install.sh | bash
```

The command must not require a version, branch, `cd`, manual `makepkg`, Conan setup, or manual `systemctl` invocation. Advanced operations remain optional flags to the downloaded script.

## Package contract

- The package is built locally for the target Arch/CachyOS/Omarchy host.
- `PKGBUILD` is at repository root.
- The package name remains `kdrive-native-arch` for upgrade and rollback compatibility in this release.
- The package uses `/usr/lib/systemd/user/kdrive.service` as the only packaged startup owner.
- Existing user-scoped archive units and native autostart entries are migrated with backups before activation.
- kDrive account databases, caches, and synchronized folders are never removed by install, update, uninstall, or rollback.
- Runtime remains `RelWithDebInfo`; runtime `.a`, public headers, debug sections, and Crashpad helper are excluded; debug symbols remain a separate build artifact.
- Sentry policy is documented as: SDK linked for ABI compatibility, activation disabled at compile time, Crashpad helper omitted, and the unit clears Sentry environment variables.

## Reproducibility contract

- Conan is isolated under the package build directory or cache, never installed into system Python.
- Conan version and the local recipe remote are explicit.
- `localrecipes` is registered before dependency resolution.
- A lockfile or equivalent exact dependency manifest is required before the release bootstrap is declared complete.
- The release bootstrap downloads the latest release source bundle and verifies its checksum before invoking `makepkg`.

## Repository surface

The default branch exposes only README, package metadata, installer/build helpers, tests, license notices, and the Arch package workflow. Upstream multi-platform source, internal agent instructions, and legacy planning artifacts are not part of the package branch.

## Rollback

Each successful install stores the built package and migration state under `$XDG_STATE_HOME/kdrive-arch/`. `install.sh --rollback` reinstalls the previous saved package and restores the previous user unit/autostart state. The installer refuses destructive rollback when no saved package exists.
