# kDrive for Arch

Native Arch Linux package for Infomaniak kDrive on Arch Linux, CachyOS, and Omarchy.

This is a community package, not an official Infomaniak binary. It builds the
official upstream source for the host's Qt/OpenSSL ABI and keeps startup under
one user systemd unit.

## Install or update

```bash
curl -fL https://github.com/shubinlab/kdrive-arch/releases/latest/download/install.sh | bash
```

The installer builds the latest verified release, installs `kdrive-native-arch`,
migrates an older archive installation when present, enables `kdrive.service`,
and preserves rollback state. It never removes kDrive account data, caches, or
synchronized folders.

## Check or rollback

```bash
curl -fL https://github.com/shubinlab/kdrive-arch/releases/latest/download/install.sh | bash -s -- --verify
curl -fL https://github.com/shubinlab/kdrive-arch/releases/latest/download/install.sh | bash -s -- --rollback
```

The package runtime is `RelWithDebInfo`. Static archives, public headers,
debug sections, and the Crashpad helper are removed from runtime; debug symbols
are published separately. The Sentry SDK remains linked for ABI compatibility,
but activation is disabled at compile time and the unit clears Sentry
environment variables.

## Manual package build

```bash
git clone --depth 1 https://github.com/shubinlab/kdrive-arch.git
cd kdrive-arch
makepkg -si
```

The package is x86_64-only and must be rebuilt on the target Arch-family host
when system Qt6/OpenSSL ABIs change.

## Source and license

The package pins the official [Infomaniak desktop-kDrive source](https://github.com/Infomaniak/desktop-kDrive)
and applies the Arch runtime delta. See [LICENSE](LICENSE) and
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
