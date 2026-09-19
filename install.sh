#!/usr/bin/env bash
set -Eeuo pipefail

REPOSITORY="${KDRIVE_INSTALL_REPO:-shubinlab/kdrive-arch}"
RELEASE_BASE_URL="${KDRIVE_RELEASE_BASE_URL:-https://github.com/${REPOSITORY}/releases/latest/download}"
PACKAGE_NAME=kdrive-arch
LEGACY_PACKAGE_NAME=kdrive-native-arch
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
INSTALL_BACKUP_ACTIVE=0
INSTALL_PACKAGE_ROLLBACK_PENDING=0

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
  for command_name in sha256sum realpath systemctl; do
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
  local expected top package_name
  curl -fL "$RELEASE_BASE_URL/kdrive-arch-source.tar.gz" -o "$archive"
  curl -fL "$RELEASE_BASE_URL/SHA256SUMS" -o "$sums"
  expected="$(awk '$2 == "kdrive-arch-source.tar.gz" || $2 == "*kdrive-arch-source.tar.gz" {print $1; exit}' "$sums")"
  [[ "$expected" =~ ^[[:xdigit:]]{64}$ ]] || die 'release checksum does not contain kdrive-arch-source.tar.gz'
  printf '%s  %s\n' "$expected" "$archive" | sha256sum -c - ||
    die 'release checksum mismatch'
  validate_release_archive "$archive"
  top=kdrive-arch
  tar --extract --gzip --file "$archive" --directory "$TEMP_ROOT" \
    --no-same-owner --no-same-permissions
  SOURCE_ROOT="$TEMP_ROOT/$top"
  local temp_real source_real
  temp_real="$(realpath -e "$TEMP_ROOT")"
  source_real="$(realpath -e "$SOURCE_ROOT")"
  [[ "$source_real/" == "$temp_real/"* ]] || die 'release source escaped temporary directory'
  [[ -r "$SOURCE_ROOT/PKGBUILD" ]] || die 'release archive has no root PKGBUILD'
  package_name="$(awk -F= '$1 == "pkgname" {gsub(/[[:space:]]/, "", $2); print $2; exit}' "$SOURCE_ROOT/PKGBUILD")"
  [[ "$package_name" == "$PACKAGE_NAME" ]] ||
    die "release PKGBUILD package identity is not $PACKAGE_NAME"
}

validate_release_archive() {
  local archive="$1" listing metadata entry root component
  listing="$TEMP_ROOT/.release-archive.list"
  metadata="$TEMP_ROOT/.release-archive.metadata"
  tar --list --gzip --file "$archive" >"$listing" || die 'release archive cannot be listed'
  tar --list --verbose --gzip --file "$archive" >"$metadata" || die 'release archive metadata cannot be read'
  [[ -s "$listing" ]] || die 'release archive is empty'
  root=''
  while IFS= read -r entry; do
    [[ -n "$entry" ]] || continue
    [[ "$entry" != /* && "$entry" != -* ]] || die 'release archive contains an absolute or option-like path'
    [[ "$entry" != *' -> '* ]] || die 'release archive symlinks are not allowed'
    if printf '%s' "$entry" | LC_ALL=C grep -q '[[:cntrl:]]'; then
      die 'release archive contains control characters in a path'
    fi
    IFS='/' read -r -a components <<<"$entry"
    root="${components[0]}"
    [[ "$root" == kdrive-arch ]] || die "release archive root must be kdrive-arch/: $root"
    for component in "${components[@]}"; do
      [[ "$component" != .. && "$component" != . ]] || die 'release archive contains parent-relative paths'
    done
  done <"$listing"
  while IFS= read -r entry; do
    case "${entry:0:1}" in
      d|-) ;;
      *) die 'release archive contains a symlink, hardlink, or special file' ;;
    esac
  done <"$metadata"
}

installed_package_name() {
  if pacman -Q "$PACKAGE_NAME" >/dev/null 2>&1; then
    printf '%s\n' "$PACKAGE_NAME"
  elif pacman -Q "$LEGACY_PACKAGE_NAME" >/dev/null 2>&1; then
    printf '%s\n' "$LEGACY_PACKAGE_NAME"
  fi
}

find_cached_package() {
  local pattern="$1" cache_dir package
  while IFS= read -r cache_dir; do
    cache_dir="${cache_dir%/}"
    [[ -d "$cache_dir" ]] || continue
    package="$(find "$cache_dir" -maxdepth 1 -type f -name "$pattern" -print -quit 2>/dev/null || true)"
    if [[ -n "$package" ]]; then
      printf '%s\n' "$package"
      return 0
    fi
  done < <(
    if command -v pacman-conf >/dev/null 2>&1; then
      pacman-conf CacheDir 2>/dev/null || true
    fi
    printf '/var/cache/pacman/pkg\n'
  )
}

save_previous_package() {
  local package_name version package
  package_name="$(installed_package_name || true)"
  [[ -n "$package_name" ]] || return 0
  version="$(pacman -Q "$package_name" 2>/dev/null | awk '{print $2}' || true)"
  [[ -n "$version" ]] || return 0
  package="$(find_cached_package "${package_name}-${version}-*.pkg.tar.*" || true)"
  if [[ -n "$package" ]]; then
    install -m 0644 "$package" "$PACKAGE_CACHE/$(basename -- "$package")"
    printf '%s\n' "$PACKAGE_CACHE/$(basename -- "$package")" >"$STATE_ROOT/previous-package"
    printf '%s\n' "$package_name" >"$STATE_ROOT/previous-package-name"
  elif [[ "$package_name" == "$LEGACY_PACKAGE_NAME" ]]; then
    die 'legacy kDrive package is installed but its cached archive is unavailable; refusing unsafe migration'
  fi
}

build_and_install() {
  local package_file package_name
  local -a args=(--syncdeps)
  ((ASSUME_YES)) && args+=(--noconfirm)
  if ! (cd "$SOURCE_ROOT" && makepkg "${args[@]}"); then
    return 1
  fi
  package_file="$(find "$SOURCE_ROOT" -maxdepth 1 -type f -name 'kdrive-arch-*.pkg.tar.*' -print -quit)"
  [[ -n "$package_file" ]] || die 'makepkg produced no kdrive-arch package'
  package_name="$(installed_package_name || true)"
  if [[ "$package_name" == "$LEGACY_PACKAGE_NAME" ]]; then
    INSTALL_PACKAGE_ROLLBACK_PENDING=1
    local -a remove_args=(-Rdd)
    ((ASSUME_YES)) && remove_args+=(--noconfirm)
    if ! run_pacman "${remove_args[@]}" "$LEGACY_PACKAGE_NAME"; then
      return 1
    fi
  fi
  INSTALL_PACKAGE_ROLLBACK_PENDING=1
  local -a install_args=(-U)
  ((ASSUME_YES)) && install_args+=(--noconfirm)
  if ! run_pacman "${install_args[@]}" "$package_file"; then
    return 1
  fi
  install -m 0644 "$package_file" "$PACKAGE_CACHE/$(basename -- "$package_file")"
  printf '%s\n' "$PACKAGE_CACHE/$(basename -- "$package_file")" >"$STATE_ROOT/current-package"
  INSTALL_PACKAGE_ROLLBACK_PENDING=0
}

restore_previous_package() {
  local package
  package="$(cat "$STATE_ROOT/previous-package" 2>/dev/null || true)"
  [[ -f "$package" ]] || return 0
  local -a args=(-U)
  ((ASSUME_YES)) && args+=(--noconfirm)
  run_pacman "${args[@]}" "$package" || true
}

install_failure_trap() {
  local status="$?"
  trap - EXIT
  if ((INSTALL_BACKUP_ACTIVE)); then
    if ((INSTALL_PACKAGE_ROLLBACK_PENDING)); then
      restore_previous_package || true
    fi
    restore_user_state "$BACKUP_DIR" || true
  fi
  rm -rf -- "$TEMP_ROOT"
  exit "$status"
}

verify_runtime() {
  local fragment launcher
  fragment="$(systemctl --user show kdrive.service -p FragmentPath --value 2>/dev/null || true)"
  [[ "$fragment" == /usr/lib/systemd/user/kdrive.service ]] ||
    die "unexpected kdrive.service owner: ${fragment:-none}"
  launcher=/usr/bin/kdrive-arch
  [[ -x "$launcher" ]] || die 'package launcher is missing'
  pacman -Q "$PACKAGE_NAME" >/dev/null || die 'pacman does not own kdrive-arch'
  [[ "$(systemctl --user is-enabled kdrive.service 2>/dev/null || true)" == enabled ]] ||
    die 'kdrive.service is not enabled'
  [[ "$(systemctl --user is-active kdrive.service 2>/dev/null || true)" == active ]] ||
    die 'kdrive.service is not active'
  say 'verified: pacman package, systemd owner, enabled and active service'
}

rollback() {
  local backup package previous_name current_name
  backup="$(latest_backup)"
  [[ -n "$backup" ]] || die 'no rollback state exists'
  backup="$BACKUP_ROOT/$backup"
  package="$(cat "$STATE_ROOT/previous-package" 2>/dev/null || true)"
  if [[ -n "$package" && -f "$package" ]]; then
    systemctl --user stop kdrive.service >/dev/null 2>&1 || true
    previous_name="$(cat "$STATE_ROOT/previous-package-name" 2>/dev/null || true)"
    current_name="$(installed_package_name || true)"
    if [[ -n "$previous_name" && -n "$current_name" && "$previous_name" != "$current_name" ]]; then
      run_pacman -Rdd "$current_name"
    fi
    run_pacman -U "$package"
  fi
  restore_user_state "$backup"
  say "rollback restored $backup"
}

uninstall() {
  local package_name
  systemctl --user disable --now kdrive.service >/dev/null 2>&1 || true
  package_name="$(installed_package_name || true)"
  [[ -n "$package_name" ]] || die 'kDrive package is not installed'
  run_pacman -Rns "$package_name"
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
      INSTALL_BACKUP_ACTIVE=1
      trap 'install_failure_trap' EXIT
      save_previous_package
      download_source
      build_and_install
      if ((START_SERVICE)); then
        systemctl --user daemon-reload
        systemctl --user enable --now kdrive.service
        verify_runtime
      fi
      INSTALL_BACKUP_ACTIVE=0
      rm -rf -- "$TEMP_ROOT"
      trap - EXIT
      say 'kDrive installed from the latest verified release'
      ;;
  esac
}

main "$@"
