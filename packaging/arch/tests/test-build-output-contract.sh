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
