#!/usr/bin/env bash
set -Eeuo pipefail

pkgbuild="${1:-}"
[[ -r "$pkgbuild" ]] || { printf 'PKGBUILD not readable: %s\n' "$pkgbuild" >&2; exit 1; }
grep -Eq '^pkgname=kdrive-native-arch$' "$pkgbuild" || die='missing package name'
grep -Eq '^pkgver=3\.8\.7\.1$' "$pkgbuild" || die='package must target 3.8.7.1'
grep -Eq 'desktop-kDrive\.git#tag=3\.8\.7' "$pkgbuild" || die='source must pin upstream 3.8.7'
grep -Eq 'kdrive\.service' "$pkgbuild" || die='package must ship the systemd unit'
grep -Eq 'kdrive-install\.sh.*--rollback|--rollback.*kdrive-install' "$pkgbuild" || die='rollback must remain documented'
if [[ -n "${die:-}" ]]; then
  printf 'PKGBUILD contract: %s\n' "$die" >&2
  exit 1
fi
