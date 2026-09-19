#!/usr/bin/env bash
set -Eeuo pipefail

root="${1:-}"
[[ -n "$root" && -d "$root" ]] || { printf 'usage: %s <runtime-root>\n' "$0" >&2; exit 2; }
root="$(cd -- "$root" && pwd -P)"
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"

die() { printf 'kdrive-package-check: %s\n' "$*" >&2; exit 1; }
[[ -x "$root/bin/kDrive" ]] || die 'missing bin/kDrive'
[[ -x "$root/bin/kDrive_client" ]] || die 'missing bin/kDrive_client'
[[ -r "$root/share/applications/kDrive_client.desktop" ]] || die 'missing desktop entry'
[[ -r "$root/MANIFEST" ]] || die 'missing MANIFEST'

forbidden="$(find "$root" -type f \( \
  -name '*.a' -o \
  -path '*/include/*' -o \
  -name crashpad_handler -o \
  -name kdrive-install.sh -o \
  -path '*/systemd/*.service' \
\) -print -quit)"
[[ -z "$forbidden" ]] || die "forbidden runtime file: $forbidden"

for binary in "$root/bin/kDrive" "$root/bin/kDrive_client"; do
  readelf -S "$binary" | grep -Eq '\.(debug_info|debug_line|debug_str)([[:space:]]|$)' &&
    die "debug sections remain in $binary"
  readelf -d "$binary" | grep -Eq 'RPATH.*\$ORIGIN/\.\./lib' ||
    die "bundled ELF must carry a transitive runtime RPATH: $binary"
  env -u LD_LIBRARY_PATH ldd "$binary" | grep -q 'not found' && die "missing ELF dependency in $binary"
done

"$script_dir/test-desktop-contract.sh" "$root/share/applications/kDrive_client.desktop"
desktop-file-validate "$root/share/applications/kDrive_client.desktop"
if grep -Eq '  /|  \.\./' "$root/SHA256SUMS"; then
  die 'SHA256SUMS contains an absolute or parent-relative build path'
fi
grep -q '^lifecycle=pacman-package-owned systemd-user-only;' "$root/MANIFEST" ||
  die 'package-owned systemd lifecycle is not documented'
grep -q '^runtime_pruned=.*installer, systemd unit' "$root/MANIFEST" ||
  die 'runtime pruning of duplicate launch paths is not documented'
grep -q '^sentry_policy=.*activation forced off at compile time' "$root/MANIFEST" || die 'Sentry policy is not compile-time disabled'

printf 'OK kDrive runtime package: ABI, pruning, desktop contract, and policy\n'
