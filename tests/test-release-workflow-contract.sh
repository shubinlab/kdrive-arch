#!/usr/bin/env bash
set -Eeuo pipefail

workflow="${1:-}"
[[ -r "$workflow" ]] || { printf 'workflow not readable: %s\n' "$workflow" >&2; exit 2; }

require() {
  local pattern="$1" message="$2"
  grep -Eq -- "$pattern" "$workflow" || {
    printf 'release workflow: %s\n' "$message" >&2
    exit 1
  }
}

require '^    container: archlinux:base-devel$' \
  'package build must run in the Arch base-devel container'
require '^  build:$' 'release workflow must isolate the build job'
require '^      contents: read$' 'build job must have read-only repository access'
require '^  publish:$' 'release workflow must isolate the privileged publish job'
require '^    needs: build$' 'publish job must consume only completed build artifacts'
require 'runuser -u builder -- env HOME=/home/builder makepkg --noconfirm --cleanbuild --dir' \
  'release must build the pacman package from PKGBUILD as an unprivileged user'
require 'pacman -Syu --needed --noconfirm git' \
  'Arch build container must install git before source archiving'
require 'makepkg --printsrcinfo.*diff -u.*\.SRCINFO' \
  'release must reject stale package metadata before building'
if grep -Eq '(^|[[:space:]])sudo([[:space:]]|$)' "$workflow"; then
  printf 'release workflow: builder must not receive sudo access\n' >&2
  exit 1
fi
require 'expected="kdrive-arch-\$\{pkgver\}-\$\{pkgrel\}"' \
  'kdrive release tag must match the PKGBUILD package identity'
require 'expected="arch-\$\{pkgver\}-\$\{pkgrel\}"' \
  'legacy arch release tag must match the PKGBUILD package identity'
require 'kdrive-arch-\$\{pkgver\}-\$\{pkgrel\}-x86_64\.pkg\.tar\.zst' \
  'package asset name must include pkgver and pkgrel'
require 'kdrive-arch-\$\{pkgver\}-\$\{pkgrel\}-debug\.tar\.gz' \
  'debug asset name must include pkgver and pkgrel'
require 'kdrive-arch-source\.tar\.gz' \
  'release must retain the installer-compatible source asset name'
require 'git -C .* archive --format=tar --prefix=kdrive-arch/ HEAD' \
  'source archive must retain the installer-validated root'
require 'gzip -n >.*release/kdrive-arch-source\.tar\.gz' \
  'source archive gzip header must be deterministic'
require 'release/install\.sh' 'release must publish the installer'
require '>SHA256SUMS' 'release must generate checksums in the release directory'
require 'sha256sum -c SHA256SUMS' 'release must verify its checksum manifest'
require '^[[:space:]]+id-token: write$' 'attestation needs OIDC permission'
require '^[[:space:]]+attestations: write$' 'attestation needs repository permission'
require '^[[:space:]]+artifact-metadata: write$' 'attestation needs artifact metadata permission'
require 'uses: actions/checkout@[0-9a-f]{40}' 'checkout action must be pinned to a commit'
require 'uses: actions/upload-artifact@[0-9a-f]{40}' \
  'CI artifact upload must be pinned to a commit'
require 'uses: actions/download-artifact@[0-9a-f]{40}' \
  'CI artifact download must be pinned to a commit'
require 'uses: actions/attest@[0-9a-f]{40}' 'attestation action must be pinned to a commit'
require 'subject-path: release/' 'attestation subjects must be the staged release assets'
require 'uses: softprops/action-gh-release@[0-9a-f]{40}' \
  'release publisher must be pinned to a commit'
require 'files: release/' 'GitHub release must upload only staged release assets'

printf 'OK release workflow contract\n'
