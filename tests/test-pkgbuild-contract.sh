#!/usr/bin/env bash
set -Eeuo pipefail

pkgbuild="${1:-}"
[[ -r "$pkgbuild" ]] || { printf 'PKGBUILD not readable: %s\n' "$pkgbuild" >&2; exit 1; }
grep -Eq '^pkgname=kdrive-arch$' "$pkgbuild" || die='missing package name'
grep -Eq '^pkgver=3\.8\.7\.1$' "$pkgbuild" || die='package must target 3.8.7.1'
grep -Fqx "options=('!strip' '!debug')" "$pkgbuild" || die='package must preserve builder stripping and separate debug symbols'
grep -Eq 'desktop-kDrive\.git#commit=b14222be555cc9f934e9ed2ec7bb36beb9c437a5' "$pkgbuild" || die='source must pin official upstream 3.8.7 commit'
grep -Eq 'kdrive\.service' "$pkgbuild" || die='package must ship the systemd unit'
grep -Eq 'kdrive-install\.sh.*--rollback|--rollback.*kdrive-install' "$pkgbuild" || die='rollback must remain documented'
if [[ -n "${die:-}" ]]; then
  printf 'PKGBUILD contract: %s\n' "$die" >&2
  exit 1
fi
