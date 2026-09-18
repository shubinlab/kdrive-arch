# Arch kDrive 3.8.7.1 packaging design

## Goal

Ship a package-first native Arch Linux/CachyOS kDrive workflow based on the
official Linux 3.8.7 source (build 3.8.7.1), while preserving the existing
3.8.6 native package as an explicit rollback.

## Source policy

- `arch/stable-3.8.7.1` is based on the signed upstream `3.8.7` tag plus the
  native Arch compatibility delta.
- `arch-native-3.8.6` remains available as the previous rollback branch and
  installed prefixes are never overwritten.
- `arch/next` is reserved for upstream `develop`; it is not part of the
  stable install instructions.

## Runtime contract

- Build type is `RelWithDebInfo`.
- Runtime contains stripped executables, private shared libraries, desktop
  integration, and the user systemd unit.
- Debug symbols are a separate archive.
- Runtime excludes static archives, public headers, debug sections, and the
  Crashpad helper.
- User systemd is the only startup owner. Native desktop autostart is removed
  and the desktop entry remains only for launch/MIME/OAuth integration.
- Sentry policy is explicit in the manifest and unit environment; no event is
  uploaded by the default package.
- Install is user-scoped, versioned, reversible, and never edits account or
  sync data.

## Distribution contract

- `makepkg -si` is the canonical Arch/CachyOS installation path.
- The repository README leads with the package use case, compatibility matrix,
  update/rollback commands, and known Wayland/keyring boundaries.
- Release assets contain runtime and debug archives plus checksums and a build
  manifest; no credentials or host-specific state is published.

## Verification

- Source tag and patch identity are checked before building.
- Package checks reject `.a`, headers, debug sections, Crashpad, missing ELF
  dependencies, invalid desktop files, and invalid systemd units.
- A reproducibility check compares two archives built from the same source.
- OAuth registration is tested for `x-scheme-handler/kdrive` and `%u`.
- The installed service is checked through `systemctl --user`; GUI launch and
  long-running sync remain host-level acceptance tests, not build claims.
