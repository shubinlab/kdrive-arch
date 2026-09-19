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
grep -q 'KDRIVE_BUILD_ROOT:-/var/tmp/kdrive-arch' "$installer" || {
  printf 'installer must default build staging to /var/tmp/kdrive-arch\n' >&2
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
  mkdir -p "$tmp_root/build-root"
  KDRIVE_RELEASE_BASE_URL="file://$release" \
    KDRIVE_INSTALL_ROOT="$tmp_root/state" \
    KDRIVE_BUILD_ROOT="$tmp_root/build-root" \
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
printf '%s\n' "$*" >>"$KDRIVE_REDTEAM_ROOT/systemctl-log"
case "$*" in
  "--user show-environment") exit 0 ;;
  "--user is-enabled kdrive.service")
    if [[ "${KDRIVE_ACTIVE_SERVICE:-0}" == 1 ]]; then printf 'enabled\n'; else printf 'disabled\n'; fi
    exit 0
    ;;
  "--user is-active kdrive.service")
    if [[ "${KDRIVE_ACTIVE_SERVICE:-0}" == 1 && ! -e "$KDRIVE_REDTEAM_ROOT/service-stopped" ]]; then
      printf 'active\n'
    elif [[ -e "$KDRIVE_REDTEAM_ROOT/service-active" ]]; then
      printf 'active\n'
    else
      printf 'inactive\n'
    fi
    exit 0
    ;;
  "--user stop kdrive.service")
    : >"$KDRIVE_REDTEAM_ROOT/service-stopped"
    rm -f -- "$KDRIVE_REDTEAM_ROOT/service-active"
    printf 'systemctl stop\n' >>"$KDRIVE_REDTEAM_ROOT/mutation-log"
    exit 0
    ;;
  "--user restart kdrive.service")
    printf 'systemctl restart\n' >>"$KDRIVE_REDTEAM_ROOT/mutation-log"
    if [[ "${KDRIVE_RESTART_FAIL:-0}" == 1 && ! -e "$KDRIVE_REDTEAM_ROOT/restart-failed" ]]; then
      : >"$KDRIVE_REDTEAM_ROOT/restart-failed"
      exit 1
    fi
    : >"$KDRIVE_REDTEAM_ROOT/service-active"
    printf '4200\n' >"$KDRIVE_REDTEAM_ROOT/service-pid"
    exit 0
    ;;
  "--user start kdrive.service")
    printf 'systemctl start\n' >>"$KDRIVE_REDTEAM_ROOT/mutation-log"
    : >"$KDRIVE_REDTEAM_ROOT/service-active"
    printf '4100\n' >"$KDRIVE_REDTEAM_ROOT/service-pid"
    exit 0
    ;;
  "--user show kdrive.service -p FragmentPath --value")
    printf '/usr/lib/systemd/user/kdrive.service\n'
    exit 0
    ;;
  "--user show kdrive.service -p MainPID --value")
    if [[ -r "$KDRIVE_REDTEAM_ROOT/service-pid" ]]; then
      cat "$KDRIVE_REDTEAM_ROOT/service-pid"
    else
      printf '0\n'
    fi
    exit 0
    ;;
  *) exit 0 ;;
esac
EOF
cat >"$bin_dir/pacman" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
printf '%s\n' "$*" >>"$KDRIVE_REDTEAM_ROOT/pacman-log"
printf 'pacman %s\n' "$*" >>"$KDRIVE_REDTEAM_ROOT/mutation-log"
case "$1" in
  -Q)
    if [[ "${KDRIVE_ACTIVE_SERVICE:-0}" == 1 && -r "$KDRIVE_REDTEAM_ROOT/current-package-name" && "${2:-}" == "$(cat "$KDRIVE_REDTEAM_ROOT/current-package-name")" ]]; then
      printf '%s 3.8.7.1-18\n' "${2:-}"
      exit 0
    fi
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
    if [[ "${KDRIVE_ACTIVE_SERVICE:-0}" == 1 ]]; then
      if [[ "$*" == *kdrive-native-arch-* ]]; then
        printf 'kdrive-native-arch\n' >"$KDRIVE_REDTEAM_ROOT/current-package-name"
      else
        printf 'kdrive-arch\n' >"$KDRIVE_REDTEAM_ROOT/current-package-name"
      fi
    fi
    : >"$KDRIVE_REDTEAM_ROOT/pacman-installed"
    exit 0
    ;;
  -R*)
    if [[ "${KDRIVE_ACTIVE_SERVICE:-0}" == 1 ]]; then
      rm -f -- "$KDRIVE_REDTEAM_ROOT/current-package-name"
    fi
    : >"$KDRIVE_REDTEAM_ROOT/pacman-removed"
    exit 0
    ;;
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
[[ "${KDRIVE_MAKEPKG_FAIL:-0}" != 1 ]] || exit 1
: >"$PWD/kdrive-arch-3.8.7.1-18-x86_64.pkg.tar.zst"
EOF
cat >"$bin_dir/findmnt" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
if [[ "${KDRIVE_REMOTE_FS:-0}" == 1 ]]; then printf 'nfs\n'; else printf 'ext4\n'; fi
EOF
cat >"$bin_dir/df" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\n'
if [[ "${KDRIVE_LOW_SPACE:-0}" == 1 ]]; then
  printf '/dev/test 100000 99000 1000 99%% /test\n'
else
  printf '/dev/test 50000000 1000 49999000 1%% /test\n'
fi
EOF
cat >"$bin_dir/realpath" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
case "${*: -1}" in
  /proc/4200/exe)
    printf '/opt/kdrive-arch/3.8.7.1/bin/kDrive\n'
    printf '/proc/4200/exe\n' >>"$KDRIVE_REDTEAM_ROOT/realpath-log"
    ;;
  /proc/4100/exe) printf '/opt/kdrive-native-arch/3.8.7.1/bin/kDrive\n' ;;
  *) exec /usr/bin/realpath "$@" ;;
esac
EOF
cat >"$bin_dir/mktemp" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
[[ "${KDRIVE_UNWRITABLE_ROOT:-0}" != 1 ]] || exit 1
exec /usr/bin/mktemp "$@"
EOF
chmod 0755 "$bin_dir"/*

good_fixture="$tmp_root/good-fixture"
mkdir -p "$good_fixture/kdrive-arch"
printf 'pkgname=kdrive-arch\n' >"$good_fixture/kdrive-arch/PKGBUILD"
tar -C "$good_fixture" -czf "$release/kdrive-arch-source.tar.gz" kdrive-arch
(cd "$release" && sha256sum kdrive-arch-source.tar.gz >SHA256SUMS)

run_install() {
  local suffix="${1:-normal}"
  mkdir -p "$tmp_root/build-root"
  PATH="$bin_dir:/usr/bin:/bin" \
    HOME="$home_dir" XDG_CONFIG_HOME="$config_dir" XDG_STATE_HOME="$state_dir" \
    KDRIVE_INSTALL_ROOT="$tmp_root/install-state-$suffix" KDRIVE_REDTEAM_ROOT="$tmp_root" \
    KDRIVE_RELEASE_BASE_URL="file://$release" KDRIVE_BUILD_ROOT="$tmp_root/build-root" \
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

printf 'old-unit\n' >"$config_dir/systemd/user/kdrive.service"
printf 'old-autostart\n' >"$config_dir/autostart/kDrive.desktop"
rm -f -- "$tmp_root/mutation-log"
if KDRIVE_MAKEPKG_FAIL=1 run_install build-failure 2>/dev/null; then
  printf 'build failure was accepted\n' >&2
  exit 1
fi
grep -qx 'old-unit' "$config_dir/systemd/user/kdrive.service" || {
  printf 'build failure mutated the old user unit\n' >&2
  exit 1
}
[[ ! -s "$tmp_root/mutation-log" ]] || {
  printf 'build failure reached system mutation\n' >&2
  exit 1
}

rm -f -- "$tmp_root/mutation-log"
if KDRIVE_LOW_SPACE=1 run_install low-space 2>/dev/null; then
  printf 'insufficient build space was accepted\n' >&2
  exit 1
fi
[[ ! -s "$tmp_root/mutation-log" ]] || {
  printf 'space preflight reached system mutation\n' >&2
  exit 1
}

rm -f -- "$tmp_root/mutation-log"
if KDRIVE_REMOTE_FS=1 run_install remote-fs 2>/dev/null; then
  printf 'remote build filesystem was accepted\n' >&2
  exit 1
fi
[[ ! -s "$tmp_root/mutation-log" ]] || {
  printf 'filesystem preflight reached system mutation\n' >&2
  exit 1
}

rm -f -- "$tmp_root/mutation-log"
if KDRIVE_UNWRITABLE_ROOT=1 run_install unwritable-root 2>/dev/null; then
  printf 'unwritable build root was accepted\n' >&2
  exit 1
fi
[[ ! -s "$tmp_root/mutation-log" ]] || {
  printf 'writability preflight reached system mutation\n' >&2
  exit 1
}

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

run_active_install() {
  local suffix="$1"
  rm -f -- "$tmp_root/service-stopped" "$tmp_root/service-active" \
    "$tmp_root/service-pid" "$tmp_root/restart-failed" "$tmp_root/current-package-name" \
    "$tmp_root/mutation-log" "$tmp_root/realpath-log" "$tmp_root/pacman-log"
  KDRIVE_ACTIVE_SERVICE=1 KDRIVE_LEGACY_MODE=1 KDRIVE_LEGACY_CACHE="$legacy_cache" \
    PATH="$bin_dir:/usr/bin:/bin" HOME="$home_dir" XDG_CONFIG_HOME="$config_dir" \
    XDG_STATE_HOME="$state_dir" KDRIVE_INSTALL_ROOT="$tmp_root/install-state-$suffix" \
    KDRIVE_REDTEAM_ROOT="$tmp_root" KDRIVE_RELEASE_BASE_URL="file://$release" \
    KDRIVE_BUILD_ROOT="$tmp_root/build-root" bash "$installer" --yes >/dev/null
}

printf 'old-unit\n' >"$config_dir/systemd/user/kdrive.service"
printf 'old-autostart\n' >"$config_dir/autostart/kDrive.desktop"
run_active_install active-success
stop_line="$(grep -n '^systemctl stop$' "$tmp_root/mutation-log" | head -n1 | cut -d: -f1)"
remove_line="$(grep -n '^pacman -Rdd.*kdrive-native-arch' "$tmp_root/mutation-log" | head -n1 | cut -d: -f1)"
restart_line="$(grep -n '^systemctl restart$' "$tmp_root/mutation-log" | head -n1 | cut -d: -f1)"
[[ -n "$stop_line" && -n "$remove_line" && -n "$restart_line" &&
   "$stop_line" -lt "$remove_line" && "$remove_line" -lt "$restart_line" ]] || {
  printf 'active update did not stop, transact, and restart in order\n' >&2
  exit 1
}
grep -qx '/proc/4200/exe' "$tmp_root/realpath-log" || {
  printf 'active update did not verify the replacement process executable\n' >&2
  exit 1
}

printf 'old-unit\n' >"$config_dir/systemd/user/kdrive.service"
printf 'old-autostart\n' >"$config_dir/autostart/kDrive.desktop"
if KDRIVE_RESTART_FAIL=1 run_active_install active-restart-failure 2>/dev/null; then
  printf 'restart failure was accepted\n' >&2
  exit 1
fi
grep -q -- '-Rdd.*kdrive-arch' "$tmp_root/pacman-log" || {
  printf 'restart failure did not remove the replacement package\n' >&2
  exit 1
}
grep -q -- '-U.*kdrive-native-arch-' "$tmp_root/pacman-log" || {
  printf 'restart failure did not restore the legacy package\n' >&2
  exit 1
}
grep -qx 'old-unit' "$config_dir/systemd/user/kdrive.service" || {
  printf 'restart failure did not restore the old user unit\n' >&2
  exit 1
}
grep -q '^systemctl start$' "$tmp_root/mutation-log" || {
  printf 'restart failure did not restore the previously active service\n' >&2
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
