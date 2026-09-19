#!/usr/bin/env bash
set -Eeuo pipefail

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
installer="$root/install.sh"

grep -q 'validate_release_archive' "$installer" || {
  printf 'installer must validate archive members before extraction\n' >&2
  exit 1
}
grep -q -- '--no-same-owner' "$installer" || {
  printf 'installer must not preserve archive ownership\n' >&2
  exit 1
}
grep -q -- '--no-same-permissions' "$installer" || {
  printf 'installer must not preserve archive permissions\n' >&2
  exit 1
}
grep -q 'kdrive-arch/' "$installer" || {
  printf 'installer must require the release archive root\n' >&2
  exit 1
}

tmp_root="$(mktemp -d "${TMPDIR:-/tmp}/kdrive-redteam.XXXXXX")"
trap 'rm -rf -- "$tmp_root"' EXIT
release="$tmp_root/release"
fixture="$tmp_root/fixture"
mkdir -p "$release" "$fixture/kdrive-arch"
printf 'pkgname=kdrive-arch\n' >"$fixture/kdrive-arch/PKGBUILD"

make_release() {
  local source_dir="$1"
  tar -C "$(dirname -- "$source_dir")" -czf "$release/kdrive-arch-source.tar.gz" "$(basename -- "$source_dir")"
  (cd "$release" && sha256sum kdrive-arch-source.tar.gz >SHA256SUMS)
}

run_dry_run() {
  KDRIVE_RELEASE_BASE_URL="file://$release" \
    KDRIVE_INSTALL_ROOT="$tmp_root/state" \
    TMPDIR="$tmp_root" \
    bash "$installer" --dry-run >/dev/null
}

make_release "$fixture/kdrive-arch"
run_dry_run

printf 'pkgname=unexpected-package\n' >"$fixture/kdrive-arch/PKGBUILD"
make_release "$fixture/kdrive-arch"
if run_dry_run 2>/dev/null; then
  printf 'wrong package identity was accepted\n' >&2
  exit 1
fi

printf 'pkgname=kdrive-arch\n' >"$fixture/kdrive-arch/PKGBUILD"
make_release "$fixture/kdrive-arch"

outside="$tmp_root/escape-marker"
rm -f -- "$outside"
tar -C "$fixture" --transform='s,^kdrive-arch,../escape,' \
  -czf "$release/kdrive-arch-source.tar.gz" kdrive-arch
(cd "$release" && sha256sum kdrive-arch-source.tar.gz >SHA256SUMS)
if run_dry_run 2>/dev/null; then
  printf 'path traversal archive was accepted\n' >&2
  exit 1
fi
[[ ! -e "$outside" ]] || { printf 'path traversal wrote outside sandbox\n' >&2; exit 1; }

rm -rf -- "$fixture/kdrive-arch"
mkdir -p "$fixture/kdrive-arch"
printf 'pkgname=kdrive-arch\n' >"$fixture/kdrive-arch/PKGBUILD"
ln -s /etc/passwd "$fixture/kdrive-arch/unsafe-link"
make_release "$fixture/kdrive-arch"
if run_dry_run 2>/dev/null; then
  printf 'symlink archive was accepted\n' >&2
  exit 1
fi

rm -rf -- "$fixture/kdrive-arch"
mkdir -p "$fixture/kdrive-arch"
printf 'pkgname=kdrive-arch\n' >"$fixture/kdrive-arch/PKGBUILD"
mkfifo "$fixture/kdrive-arch/unsafe-fifo"
make_release "$fixture/kdrive-arch"
if run_dry_run 2>/dev/null; then
  printf 'special-file archive was accepted\n' >&2
  exit 1
fi

bin_dir="$tmp_root/bin"
config_dir="$tmp_root/config"
state_dir="$tmp_root/xdg-state"
home_dir="$tmp_root/home"
mkdir -p "$bin_dir" "$config_dir/systemd/user" "$config_dir/autostart" "$state_dir" "$home_dir"
printf 'old-unit\n' >"$config_dir/systemd/user/kdrive.service"
printf 'old-autostart\n' >"$config_dir/autostart/kDrive.desktop"
printf '%s\n' "$*" >"$tmp_root/expected-empty"

cat >"$bin_dir/systemctl" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
case "$*" in
  "--user show-environment") exit 0 ;;
  "--user is-enabled kdrive.service") printf 'disabled\n'; exit 0 ;;
  "--user is-active kdrive.service") printf 'inactive\n'; exit 0 ;;
  *) exit 0 ;;
esac
EOF
cat >"$bin_dir/pacman" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
printf '%s\n' "$*" >>"$KDRIVE_REDTEAM_ROOT/pacman-log"
case "$1" in
  -Q)
    if [[ "${KDRIVE_ROLLBACK_MODE:-0}" == 1 && "${2:-}" == kdrive-arch ]]; then
      printf 'kdrive-arch 3.8.7.1-13\n'
      exit 0
    fi
    if [[ "${KDRIVE_LEGACY_MODE:-0}" == 1 && "${2:-}" == kdrive-native-arch ]]; then
      printf 'kdrive-native-arch 3.8.7.1-12\n'
      exit 0
    fi
    exit 1
    ;;
  -U)
    if [[ "${KDRIVE_PACMAN_FAIL:-0}" == 1 && "$*" == *kdrive-arch-* ]]; then
      exit 1
    fi
    : >"$KDRIVE_REDTEAM_ROOT/pacman-installed"
    exit 0
    ;;
  -R*) : >"$KDRIVE_REDTEAM_ROOT/pacman-removed"; exit 0 ;;
  *) exit 0 ;;
esac
EOF
cat >"$bin_dir/find" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
if [[ -n "${KDRIVE_LEGACY_CACHE:-}" && "${1:-}" == "$KDRIVE_LEGACY_CACHE" ]]; then
  printf '%s\n' "$KDRIVE_LEGACY_CACHE/kdrive-native-arch-3.8.7.1-12-x86_64.pkg.tar.zst"
  exit 0
fi
exec /usr/bin/find "$@"
EOF
cat >"$bin_dir/pacman-conf" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
printf '%s/\n' "${KDRIVE_LEGACY_CACHE:-/var/cache/pacman/pkg}"
EOF
cat >"$bin_dir/sudo" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
exec "$@"
EOF
cat >"$bin_dir/makepkg" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
: >"$PWD/kdrive-arch-3.8.7.1-17-x86_64.pkg.tar.zst"
EOF
chmod 0755 "$bin_dir"/*

good_fixture="$tmp_root/good-fixture"
mkdir -p "$good_fixture/kdrive-arch"
printf 'pkgname=kdrive-arch\n' >"$good_fixture/kdrive-arch/PKGBUILD"
tar -C "$good_fixture" -czf "$release/kdrive-arch-source.tar.gz" kdrive-arch
(cd "$release" && sha256sum kdrive-arch-source.tar.gz >SHA256SUMS)

run_install() {
  local suffix="${1:-normal}"
  PATH="$bin_dir:/usr/bin:/bin" \
    HOME="$home_dir" XDG_CONFIG_HOME="$config_dir" XDG_STATE_HOME="$state_dir" \
    KDRIVE_INSTALL_ROOT="$tmp_root/install-state-$suffix" KDRIVE_REDTEAM_ROOT="$tmp_root" \
    KDRIVE_RELEASE_BASE_URL="file://$release" TMPDIR="$tmp_root" \
    bash "$installer" --no-start --yes >/dev/null
}

run_install normal
[[ -e "$tmp_root/pacman-installed" ]] || { printf 'sandbox package install was not invoked\n' >&2; exit 1; }
[[ ! -e "$config_dir/systemd/user/kdrive.service" ]] || { printf 'legacy unit was not removed\n' >&2; exit 1; }
[[ ! -e "$config_dir/autostart/kDrive.desktop" ]] || { printf 'legacy autostart was not removed\n' >&2; exit 1; }
[[ ! -e "$tmp_root/host-write" ]] || { printf 'sandbox wrote an unexpected host marker\n' >&2; exit 1; }

printf 'old-unit\n' >"$config_dir/systemd/user/kdrive.service"
printf 'old-autostart\n' >"$config_dir/autostart/kDrive.desktop"
printf '%064d  kdrive-arch-source.tar.gz\n' 0 >"$release/SHA256SUMS"
if run_install failure 2>/dev/null; then
  printf 'checksum failure was accepted\n' >&2
  exit 1
fi
grep -qx 'old-unit' "$config_dir/systemd/user/kdrive.service" || {
  printf 'failed install did not restore the old user unit\n' >&2
  exit 1
}
grep -qx 'old-autostart' "$config_dir/autostart/kDrive.desktop" || {
  printf 'failed install did not restore the old autostart file\n' >&2
  exit 1
}
(cd "$release" && sha256sum kdrive-arch-source.tar.gz >SHA256SUMS)

legacy_cache="$tmp_root/legacy-cache"
mkdir -p "$legacy_cache"
: >"$legacy_cache/kdrive-native-arch-3.8.7.1-12-x86_64.pkg.tar.zst"
KDRIVE_LEGACY_MODE=1 KDRIVE_LEGACY_CACHE="$legacy_cache" run_install legacy
grep -q -- '-Rdd.*kdrive-native-arch' "$tmp_root/pacman-log" || {
  printf 'legacy package was not removed before migration\n' >&2
  exit 1
}
grep -q -- '-U.*kdrive-arch-' "$tmp_root/pacman-log" || {
  printf 'new kdrive-arch package was not installed\n' >&2
  exit 1
}
[[ -f "$tmp_root/install-state-legacy/previous-package" ]] || {
  printf 'legacy package rollback cache was not recorded\n' >&2
  exit 1
}

printf 'old-unit\n' >"$config_dir/systemd/user/kdrive.service"
printf 'old-autostart\n' >"$config_dir/autostart/kDrive.desktop"
if KDRIVE_LEGACY_MODE=1 KDRIVE_LEGACY_CACHE="$legacy_cache" KDRIVE_PACMAN_FAIL=1 \
  run_install legacy-failure 2>/dev/null; then
  printf 'package failure was accepted\n' >&2
  exit 1
fi
grep -qx 'old-unit' "$config_dir/systemd/user/kdrive.service" || {
  printf 'failed package migration did not restore the old user unit\n' >&2
  exit 1
}
grep -qx 'old-autostart' "$config_dir/autostart/kDrive.desktop" || {
  printf 'failed package migration did not restore the old autostart file\n' >&2
  exit 1
}
grep -q -- '-U.*kdrive-native-arch-' "$tmp_root/pacman-log" || {
  printf 'failed package migration did not attempt legacy package restore\n' >&2
  exit 1
}

KDRIVE_ROLLBACK_MODE=1 PATH="$bin_dir:/usr/bin:/bin" \
  HOME="$home_dir" XDG_CONFIG_HOME="$config_dir" XDG_STATE_HOME="$state_dir" \
  KDRIVE_INSTALL_ROOT="$tmp_root/install-state-legacy" KDRIVE_REDTEAM_ROOT="$tmp_root" \
  TMPDIR="$tmp_root" bash "$installer" --rollback >/dev/null
grep -q -- '-Rdd.*kdrive-arch' "$tmp_root/pacman-log" || {
  printf 'rollback did not remove the renamed package before restoring legacy\n' >&2
  exit 1
}

printf 'OK installer red-team contract\n'
