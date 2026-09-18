#!/usr/bin/env bash
set -Eeuo pipefail

desktop_file="${1:-}"
[[ -n "$desktop_file" ]] || { printf 'usage: %s <desktop-file>\n' "$0" >&2; exit 2; }
[[ -r "$desktop_file" ]] || { printf 'desktop file not readable: %s\n' "$desktop_file" >&2; exit 1; }

grep -Eq '^Exec=[^[:space:]]+([[:space:]]+[^#]*)?%u([[:space:]]|$)' "$desktop_file" || {
  printf 'desktop entry must pass one URL with %%u: %s\n' "$desktop_file" >&2
  exit 1
}
grep -E '^MimeType=' "$desktop_file" | sed 's/^MimeType=//' | tr ';' '\n' | grep -qx 'x-scheme-handler/kdrive' || {
  printf 'desktop entry must register x-scheme-handler/kdrive: %s\n' "$desktop_file" >&2
  exit 1
}
