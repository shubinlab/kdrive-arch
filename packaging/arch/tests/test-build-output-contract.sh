#!/usr/bin/env bash
set -Eeuo pipefail

builder="${1:-}"
[[ -r "$builder" ]] || { printf 'builder not readable: %s\n' "$builder" >&2; exit 1; }
grep -q 'RUNTIME_DIR="\$OUTPUT_DIR/kdrive-\${version}-native-arch"' "$builder" || {
  printf 'runtime prefix must include the built version\n' >&2
  exit 1
}
grep -q 'SYMBOL_DIR="\$OUTPUT_DIR/kdrive-\${version}-native-arch-debug"' "$builder" || {
  printf 'debug prefix must include the built version\n' >&2
  exit 1
}
grep -q 'sha256sum bin/kDrive bin/kDrive_client bin/sync-exclude.lst' "$builder" || {
  printf 'SHA256SUMS must use relative runtime paths\n' >&2
  exit 1
}
grep -q -- "-DCMAKE_EXE_LINKER_FLAGS='-Wl,--disable-new-dtags'" "$builder" || {
  printf 'executable linker must emit transitive DT_RPATH\n' >&2
  exit 1
}
grep -q 'strip --strip-unneeded "\$target"' "$builder" || {
  printf 'bundled shared libraries must be stripped before checksums\n' >&2
  exit 1
}
grep -q 'objcopy --strip-unneeded "\$RUNTIME_DIR/bin/\$binary"' "$builder" || {
  printf 'runtime executables must be stripped before checksums\n' >&2
  exit 1
}
