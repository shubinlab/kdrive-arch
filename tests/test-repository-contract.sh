#!/usr/bin/env bash
set -Eeuo pipefail

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
failures=0

require_file() {
  if [[ ! -f "$root/$1" ]]; then
    printf 'MISSING %s\n' "$1" >&2
    failures=$((failures + 1))
  fi
}

for path in \
  PKGBUILD \
  .SRCINFO \
  install.sh \
  build/build-package.sh \
  build/install.sh \
  build/arch-native-3.8.7.1.patch \
  tests/check-package.sh \
  tests/test-pkgbuild-contract.sh; do
  require_file "$path"
done

for path in packaging/arch infomaniak-build-tools src; do
  if [[ -e "$root/$path" ]]; then
    printf 'UNEXPECTED %s\n' "$path" >&2
    failures=$((failures + 1))
  fi
done

if ((failures)); then
  printf 'repository contract: %d failure(s)\n' "$failures" >&2
  exit 1
fi

printf 'OK repository contract\n'
