# Native Arch Linux build

This directory contains the Arch-family packaging path for kDrive. It keeps
the upstream CMake/Conan project layout intact while adding a native Linux
runtime contract for Arch Linux, CachyOS, and Omarchy hosts.

The build is pinned to the official `3.8.6` tag (`bf2040056efef79f39287178afab0ee7614deab3`). It produces a
`RelWithDebInfo` runtime archive and a separate debug-symbol archive. Qt6 and
OpenSSL are resolved from the target system; the bundle carries only the
remaining private shared libraries. The host must provide the current ABI:

```text
qt6-base qt6-svg glib2 libsecret libzip curl c-ares openssl wayland
```

## Build

Start from a clean upstream tag checkout with submodules initialized. The
script does not change system files and writes only to the selected output
directory:

```bash
git clone --branch 3.8.6 --recurse-submodules \
  https://github.com/Infomaniak/desktop-kDrive.git desktop-kDrive-3.8.6
python -m venv .venv
. .venv/bin/activate
pip install conan
infomaniak-build-tools/linux/arch-native/build-package.sh \
  --source "$PWD/desktop-kDrive-3.8.6" \
  --output "$PWD/dist"
```

The output contains:

```text
kdrive-<version>-native-arch.tar.gz
kdrive-<version>-native-arch-debug.tar.gz
```

The first archive is the runtime. The second contains the `.dbg` files used
by `coredumpctl`/`gdb`; it is deliberately not installed into the runtime
prefix.

## Lifecycle and Sentry policy

`kdrive.service` is the only startup owner. It is a user systemd unit attached
to `graphical-session.target`; the native desktop autostart entry is removed
by the installer and by the Linux source patch when `APPIMAGE` is empty.

The Sentry SDK remains linked for ABI compatibility, but activation is
disabled with `KDRIVE_SENTRY_ENVIRONMENT=` in the unit. Crashpad is omitted;
local systemd-coredump is the diagnostic path. This policy avoids silently
uploading account or file metadata while retaining a reproducible symbolized
crash workflow.

## Install, check, rollback

The installer is user-scoped and never touches `~/.config/kDrive` or synced
folders. Each version gets an immutable prefix under `~/.local/opt/`; only
launcher/resource symlinks and the user unit are switched. A state backup is
created before every apply:

```bash
tar -xzf dist/kdrive-<version>-native-arch.tar.gz -C /tmp
./kdrive-<version>-native-arch/kdrive-install.sh \
  --apply /tmp/kdrive-<version>-native-arch
./kdrive-<version>-native-arch/kdrive-install.sh --check
./kdrive-<version>-native-arch/kdrive-install.sh --rollback
```

Rollback restores the previous launcher, desktop entry, autostart state, and
unit state. It does not remove account databases, caches, or synchronized
data.

## Portability boundary

This is a native Arch-family build, not a universal Linux binary. Rebuild on
the target Arch/CachyOS release when Qt6/OpenSSL or other system ABIs change.
The upstream Linux release guide remains authoritative for Ubuntu release
artifacts; this directory is the separately maintained Arch path.
