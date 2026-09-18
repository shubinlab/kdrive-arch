#!/usr/bin/env bash
set -Eeuo pipefail

REPOSITORY="${KDRIVE_INSTALL_REPO:-shubinlab/kdrive-arch}"
RELEASE_BASE_URL="${KDRIVE_RELEASE_BASE_URL:-https://github.com/${REPOSITORY}/releases/latest/download}"
STATE_HOME="${XDG_STATE_HOME:-${HOME}/.local/state}"
CONFIG_HOME="${XDG_CONFIG_HOME:-${HOME}/.config}"
STATE_ROOT="${KDRIVE_INSTALL_ROOT:-${STATE_HOME}/kdrive-arch}"
PACKAGE_CACHE="${STATE_ROOT}/packages"
BACKUP_ROOT="${STATE_ROOT}/backups"
ACTION=install
START_SERVICE=1
ASSUME_YES=0
TEMP_ROOT=""
SOURCE_ROOT=""
BACKUP_DIR=""

die() { printf 'kdrive-install: %s\n' "$*" >&2; exit 1; }
say() { printf 'kdrive-install: %s\n' "$*"; }

usage() {
  cat <<'EOF'
Usage:
  install.sh                         install or update the latest Arch package
  install.sh --verify                verify the active package and user unit
  install.sh --rollback              restore the previous package/state
  install.sh --uninstall             remove the package, not kDrive data
  install.sh --dry-run               download and verify only
  install.sh --no-start              install without enabling the user unit
  install.sh --yes                   skip pacman confirmations
EOF
}

while (($#)); do
  case "$1" in
    --verify) ACTION=verify; shift ;;
    --rollback) ACTION=rollback; shift ;;
    --uninstall) ACTION=uninstall; shift ;;
    --dry-run) ACTION=dry-run; shift ;;
    --no-start) START_SERVICE=0; shift ;;
    --yes) ASSUME_YES=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
done

need_command() {
  command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

preflight() {
  ((EUID != 0)) || die 'run as the normal user, not root'
  [[ "$(uname -m)" == x86_64 ]] || die 'only x86_64 is supported by this package'
  [[ -r /etc/os-release ]] || die 'cannot identify the operating system'
  # shellcheck disable=SC1091
  source /etc/os-release
  case " ${ID:-} ${ID_LIKE:-} " in
    *' arch '*|*' cachyos '*|*' omarchy '*) ;;
    *) die 'this installer supports Arch Linux, CachyOS, and Omarchy only' ;;
  esac
  for command_name in sha256sum systemctl; do
    need_command "$command_name"
  done
  case "$ACTION" in
    install)
      for command_name in curl makepkg pacman tar; do need_command "$command_name"; done
      ;;
    dry-run)
      for command_name in curl tar; do need_command "$command_name"; done
      ;;
    rollback|uninstall|verify)
      need_command pacman
      ;;
  esac
  if [[ "$ACTION" == install || "$ACTION" == rollback || "$ACTION" == uninstall || "$ACTION" == verify ]]; then
    systemctl --user show-environment >/dev/null 2>&1 ||
      die 'no user systemd session is available; run this from the graphical session'
  fi
}

run_pacman() {
  if ((EUID == 0)); then
    pacman "$@"
  else
    need_command sudo
    sudo pacman "$@"
  fi
}

capture_path() {
  local path="$1" state="$2"
  if [[ -L "$path" ]]; then
    printf 'symlink\n%s\n' "$(readlink "$path")" >"$state"
  elif [[ -f "$path" ]]; then
    printf 'file\n' >"$state"
    cp -a -- "$path" "${state}.data"
  else
    printf 'absent\n' >"$state"
  fi
}

restore_path() {
  local path="$1" state="$2" kind target
  [[ -r "$state" ]] || die "missing rollback state: $state"
  kind="$(sed -n '1p' "$state")"
  rm -f -- "$path"
  case "$kind" in
    symlink)
      target="$(sed -n '2p' "$state")"
      mkdir -p -- "$(dirname -- "$path")"
      ln -s -- "$target" "$path"
      ;;
    file)
      mkdir -p -- "$(dirname -- "$path")"
      cp -a -- "${state}.data" "$path"
      ;;
    absent) ;;
    *) die "invalid rollback state: $state" ;;
  esac
}

latest_backup() {
  find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null | sort -r | head -n 1
}

snapshot_user_state() {
  local id
  mkdir -p -- "$BACKUP_ROOT" "$PACKAGE_CACHE"
  id="$(date -u +%Y%m%dT%H%M%SZ)-$BASHPID"
  BACKUP_DIR="$BACKUP_ROOT/$id"
  mkdir -m 0700 -- "$BACKUP_DIR"
  capture_path "$CONFIG_HOME/systemd/user/kdrive.service" "$BACKUP_DIR/kdrive.service.state"
  capture_path "$CONFIG_HOME/autostart/kDrive.desktop" "$BACKUP_DIR/kDrive.autostart.state"
  printf '%s\n' "$(systemctl --user is-enabled kdrive.service 2>/dev/null || true)" >"$BACKUP_DIR/enabled"
  printf '%s\n' "$(systemctl --user is-active kdrive.service 2>/dev/null || true)" >"$BACKUP_DIR/active"
  if [[ -e "$CONFIG_HOME/systemd/user/kdrive.service" ]]; then
    systemctl --user disable --now kdrive.service >/dev/null 2>&1 || true
    rm -f -- "$CONFIG_HOME/systemd/user/kdrive.service"
  fi
  if [[ -e "$CONFIG_HOME/autostart/kDrive.desktop" ]]; then
    rm -f -- "$CONFIG_HOME/autostart/kDrive.desktop"
  fi
}

restore_user_state() {
  local backup="$1"
  restore_path "$CONFIG_HOME/systemd/user/kdrive.service" "$backup/kdrive.service.state"
  restore_path "$CONFIG_HOME/autostart/kDrive.desktop" "$backup/kDrive.autostart.state"
  systemctl --user daemon-reload >/dev/null 2>&1 || true
  if [[ "$(cat "$backup/enabled")" == enabled ]]; then
    systemctl --user enable kdrive.service >/dev/null 2>&1 || true
  else
    systemctl --user disable kdrive.service >/dev/null 2>&1 || true
  fi
  if [[ "$(cat "$backup/active")" == active ]]; then
    systemctl --user start kdrive.service >/dev/null 2>&1 || true
  fi
}

download_source() {
  local archive="$TEMP_ROOT/kdrive-arch-source.tar.gz"
  local sums="$TEMP_ROOT/SHA256SUMS"
  local expected top
  curl -fL "$RELEASE_BASE_URL/kdrive-arch-source.tar.gz" -o "$archive"
  curl -fL "$RELEASE_BASE_URL/SHA256SUMS" -o "$sums"
  expected="$(awk '$2 == "kdrive-arch-source.tar.gz" || $2 == "*kdrive-arch-source.tar.gz" {print $1; exit}' "$sums")"
  [[ "$expected" =~ ^[[:xdigit:]]{64}$ ]] || die 'release checksum does not contain kdrive-arch-source.tar.gz'
  printf '%s  %s\n' "$expected" "$archive" | sha256sum -c -
  top="$(tar -tzf "$archive" | sed -n '1s,/.*,,p')"
  [[ -n "$top" ]] || die 'release archive is empty'
  tar -xzf "$archive" -C "$TEMP_ROOT"
  SOURCE_ROOT="$TEMP_ROOT/$top"
  [[ -r "$SOURCE_ROOT/PKGBUILD" ]] || die 'release archive has no root PKGBUILD'
}

save_previous_package() {
  local version package
  version="$(pacman -Q kdrive-native-arch 2>/dev/null | awk '{print $2}' || true)"
  [[ -n "$version" ]] || return 0
  package="$(find /var/cache/pacman/pkg -maxdepth 1 -type f -name "kdrive-native-arch-${version}-*.pkg.tar.*" -print -quit 2>/dev/null || true)"
  if [[ -n "$package" ]]; then
    install -m 0644 "$package" "$PACKAGE_CACHE/$(basename -- "$package")"
    printf '%s\n' "$PACKAGE_CACHE/$(basename -- "$package")" >"$STATE_ROOT/previous-package"
  fi
}

build_and_install() {
  local package_file
  local -a args=(--syncdeps --install)
  ((ASSUME_YES)) && args+=(--noconfirm)
  (cd "$SOURCE_ROOT" && makepkg "${args[@]}")
  package_file="$(find "$SOURCE_ROOT" -maxdepth 1 -type f -name 'kdrive-native-arch-*.pkg.tar.*' -print -quit)"
  [[ -n "$package_file" ]] || die 'makepkg produced no kdrive-native-arch package'
  install -m 0644 "$package_file" "$PACKAGE_CACHE/$(basename -- "$package_file")"
  printf '%s\n' "$PACKAGE_CACHE/$(basename -- "$package_file")" >"$STATE_ROOT/current-package"
}

verify_runtime() {
  local fragment launcher
  fragment="$(systemctl --user show kdrive.service -p FragmentPath --value 2>/dev/null || true)"
  [[ "$fragment" == /usr/lib/systemd/user/kdrive.service ]] ||
    die "unexpected kdrive.service owner: ${fragment:-none}"
  launcher=/usr/bin/kdrive-native-arch
  [[ -x "$launcher" ]] || die 'package launcher is missing'
  pacman -Q kdrive-native-arch >/dev/null || die 'pacman does not own kdrive-native-arch'
  [[ "$(systemctl --user is-enabled kdrive.service 2>/dev/null || true)" == enabled ]] ||
    die 'kdrive.service is not enabled'
  [[ "$(systemctl --user is-active kdrive.service 2>/dev/null || true)" == active ]] ||
    die 'kdrive.service is not active'
  say 'verified: pacman package, systemd owner, enabled and active service'
}

rollback() {
  local backup package
  backup="$(latest_backup)"
  [[ -n "$backup" ]] || die 'no rollback state exists'
  backup="$BACKUP_ROOT/$backup"
  package="$(cat "$STATE_ROOT/previous-package" 2>/dev/null || true)"
  if [[ -n "$package" && -f "$package" ]]; then
    systemctl --user stop kdrive.service >/dev/null 2>&1 || true
    run_pacman -U "$package"
  fi
  restore_user_state "$backup"
  say "rollback restored $backup"
}

uninstall() {
  systemctl --user disable --now kdrive.service >/dev/null 2>&1 || true
  run_pacman -Rns kdrive-native-arch
  say 'package removed; kDrive account and synchronized data were preserved'
}

main() {
  preflight
  case "$ACTION" in
    verify)
      verify_runtime
      ;;
    rollback)
      rollback
      ;;
    uninstall)
      uninstall
      ;;
    dry-run)
      TEMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/kdrive-arch.XXXXXX")"
      trap 'rm -rf -- "$TEMP_ROOT"' EXIT
      download_source
      say "verified latest release source at $SOURCE_ROOT"
      ;;
    install)
      TEMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/kdrive-arch.XXXXXX")"
      trap 'rm -rf -- "$TEMP_ROOT"' EXIT
      snapshot_user_state
      save_previous_package
      if ! download_source; then
        restore_user_state "$BACKUP_DIR"
        die 'release download failed; previous state restored'
      fi
      if ! build_and_install; then
        restore_user_state "$BACKUP_DIR"
        die 'package install failed; previous state restored'
      fi
      if ((START_SERVICE)); then
        systemctl --user daemon-reload
        systemctl --user enable --now kdrive.service
        verify_runtime
      fi
      say 'kDrive installed from the latest verified release'
      ;;
  esac
}

main "$@"
