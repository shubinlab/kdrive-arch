# Third-party notices

This repository packages the official GPLv3 Infomaniak desktop-kDrive source
for Arch-family systems. The exact runtime is assembled by the root
`PKGBUILD` and the host's system libraries.

## Runtime and build components

- Qt 6, OpenSSL, glib2, libsecret, libzip, curl, c-ares, Wayland, and systemd
  are host Arch dependencies installed by pacman.
- Poco, log4cplus, xxHash, SQLite, zlib, and Sentry Native are resolved by the
  pinned Conan build graph and remain subject to their upstream licenses.
- The Sentry SDK is linked for ABI compatibility. `KDRIVE_DISABLE_SENTRY=ON`
  disables activation at compile time; the runtime does not ship
  `crashpad_handler` and the user unit clears Sentry environment variables.
- Runtime static archives, public headers, and debug sections are removed.
  Debug symbols are distributed separately for crash analysis.

See the upstream project's license and dependency sources at
<https://github.com/Infomaniak/desktop-kDrive>.

## Project license

The package and Arch integration are distributed under
[GPL-3.0-or-later](LICENSE), subject to the licenses of the components listed
above.
