# kDrive Arch Red-Team Hardening Design

## Scope

This repository distributes one native x86_64 Arch-family package for
Infomaniak kDrive. The Arch product surface is the `PKGBUILD`, the native
build delta, the package-first installer, the user systemd unit, rollback
state, and the release metadata needed to retrieve those files.

Upstream macOS, Swift, Windows, mobile, and vendor CI sources are retained
only in the historical/upstream branch for provenance. They are not part of
the `arch-native` tree or the latest source archive and must not enter the
Arch release payload.

## Naming decision

Use `pkgname=kdrive-arch`. `kDrive` is the product name and `arch` is the
platform scope; `kde-arch` would incorrectly imply the KDE project. This is a
deliberate package identity migration from the previous `kdrive-native-arch`
name, so the installer must detect and replace the old package while retaining
its cached package and user-state rollback path.

Release tags use the clearer `kdrive-arch-<pkgver>-<pkgrel>` form; existing
`arch-3.8.7.1-*` tags remain immutable rollback references. The installer
remains release-name independent by consuming `releases/latest`.

## Security boundaries

The installer must treat the downloaded source archive as hostile input even
after checksum verification. Before extraction it will require one fixed root
directory, reject absolute/parent-relative names, reject symlink/hardlink
members, reject control characters, and verify the resolved source directory
stays inside its temporary directory. Extraction will not preserve archive
ownership or permissions.

The release source archive must contain only the Arch package surface. A
repository contract test will reject platform-specific source paths and a
release-fixture test will inspect the generated archive rather than only the
working tree.

## Sandbox acceptance

Red-team tests run with a local fake release, temporary `HOME`, XDG config and
state roots, and stubbed `makepkg`, `pacman`, and user `systemctl`. They must
prove checksum failure, traversal/symlink rejection, no writes outside the
sandbox, preservation of the old unit/autostart state, and rollback metadata.
No test may install a package or alter the host system.

## Non-goals

Do not delete upstream history, rename the installed pacman package, rebuild
the vendor application in another language, or replace systemd with a second
startup owner. Do not remove source files that are required by the official
3.8.7 build or the Arch patch merely because their upstream history is
cross-platform.
