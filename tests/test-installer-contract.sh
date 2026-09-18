#!/usr/bin/env bash
set -Eeuo pipefail

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
installer="$root/install.sh"
[[ -f "$installer" ]] || { printf 'MISSING install.sh\n' >&2; exit 1; }

grep -q '^set -Eeuo pipefail$' "$installer" || { printf 'installer must use Bash strict mode\n' >&2; exit 1; }
grep -q 'releases/latest/download' "$installer" || { printf 'installer must use latest release assets\n' >&2; exit 1; }
for option in --dry-run --verify --rollback --uninstall; do
  grep -q -- "$option" "$installer" || { printf 'installer missing %s\n' "$option" >&2; exit 1; }
done

if grep -Eq -- '--proto|--tlsv1\.2|--yes' "$root/README.md" 2>/dev/null; then
  printf 'public README must not require curl hardening or yes flags\n' >&2
  exit 1
fi

if grep -Eq 'refs/(heads|tags)/[^ ]*install\.sh' "$root/README.md" 2>/dev/null; then
  printf 'public README must not use a versioned installer URL\n' >&2
  exit 1
fi

printf 'OK installer contract\n'
