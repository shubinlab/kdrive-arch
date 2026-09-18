#!/usr/bin/env bash
set -Eeuo pipefail

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
failures=0

active_files=(
  PKGBUILD .SRCINFO README.md THIRD_PARTY_NOTICES.md
  kdrive-arch.in kdrive.service
  build/build-package.sh build/install.sh build/kdrive.service
  tests/test-pkgbuild-contract.sh
)

for file in "${active_files[@]}"; do
  [[ -f "$root/$file" ]] || continue
  if rg -n 'kdrive-native-arch' "$root/$file" >/dev/null; then
    printf 'legacy package name leaked into active file: %s\n' "$file" >&2
    failures=$((failures + 1))
  fi
done

grep -Eq '^pkgname=kdrive-arch$' "$root/PKGBUILD" || failures=$((failures + 1))
grep -Eq 'kdrive-arch-[^ ]+\.pkg\.tar' "$root/install.sh" || failures=$((failures + 1))
grep -Eq '^PACKAGE_NAME=kdrive-arch$' "$root/install.sh" || failures=$((failures + 1))
grep -Eq 'LEGACY_PACKAGE_NAME=kdrive-native-arch' "$root/install.sh" || failures=$((failures + 1))

if ((failures)); then
  printf 'package name contract: %d failure(s)\n' "$failures" >&2
  exit 1
fi
printf 'OK package name contract\n'
