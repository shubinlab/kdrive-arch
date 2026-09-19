#!/usr/bin/env bash
set -Eeuo pipefail

REPOSITORY="${KDRIVE_INSTALL_REPO:-shubinlab/kdrive-arch}"
RELEASE_BASE_URL="${KDRIVE_RELEASE_BASE_URL:-https://github.com/${REPOSITORY}/releases/latest/download}"
PACKAGE_NAME=kdrive-arch
LEGACY_PACKAGE_NAME=kdrive-native-arch
STATE_HOME="${XDG_STATE_HOME:-${HOME}/.local/state}"
CONFIG_HOME="${XDG_CONFIG_HOME:-${HOME}/.config}"
STATE_ROOT="${KDRIVE_INSTALL_ROOT:-${STATE_HOME}/kdrive-arch}"
BUILD_ROOT="${KDRIVE_BUILD_ROOT:-/var/tmp/kdrive-arch}"
MIN_BUILD_FREE_KIB=8388608
PACKAGE_CACHE="${STATE_ROOT}/packages"
BACKUP_ROOT="${STATE_ROOT}/backups"
ACTION=install
START_SERVICE=1
ASSUME_YES=0
TEMP_ROOT=""
SOURCE_ROOT=""
PACKAGE_FILE=""
BACKUP_DIR=""
INSTALL_BACKUP_ACTIVE=0
INSTALL_PACKAGE_ROLLBACK_PENDING=0
PREVIOUS_SERVICE_ACTIVE=inactive
PREVIOUS_SERVICE_ENABLED=disabled
PREVIOUS_PACKAGE_NAME=""

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
      for command_name in curl df findmnt makepkg pacman tar; do need_command "$command_name"; done
      ;;
    dry-run)
      for command_name in curl df findmnt tar; do need_command "$command_name"; done
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

prepare_temp_root() {
  local filesystem available_kib required_free_kib=$MIN_BUILD_FREE_KIB
  [[ "$ACTION" == install ]] || required_free_kib=524288
  if [[ ! -e "$BUILD_ROOT" ]]; then
    mkdir -m 0700 -- "$BUILD_ROOT" 2>/dev/null ||
      die "build root cannot be created: $BUILD_ROOT"
  fi
  [[ -d "$BUILD_ROOT" && ! -L "$BUILD_ROOT" ]] ||
    die "build root must be a directory, not a symlink: $BUILD_ROOT"
  BUILD_ROOT="$(realpath -e "$BUILD_ROOT")"
  filesystem="$(findmnt --noheadings --output FSTYPE --target "$BUILD_ROOT" 2>/dev/null | awk 'NR == 1 {print $1}')"
  [[ -n "$filesystem" ]] || die "cannot identify build filesystem: $BUILD_ROOT"
  case "$filesystem" in
    nfs*|cifs|smb*|sshfs|fuse.sshfs|9p|ceph|glusterfs|davfs*|fuse.davfs)
      die "build root must use a local filesystem, found $filesystem"
      ;;
  esac
  available_kib="$(df -Pk "$BUILD_ROOT" 2>/dev/null | awk 'NR == 2 {print $4}')"
  [[ "$available_kib" =~ ^[0-9]+$ ]] ||
    die "cannot determine free space for build root: $BUILD_ROOT"
  ((available_kib >= required_free_kib)) ||
    die "build root needs at least $((required_free_kib / 1024)) MiB free: $BUILD_ROOT"
  TEMP_ROOT="$(mktemp -d "$BUILD_ROOT/build.XXXXXXXX")" ||
    die "build root is not writable: $BUILD_ROOT"
  chmod 0700 "$TEMP_ROOT"
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
  PREVIOUS_SERVICE_ENABLED="$(systemctl --user is-enabled kdrive.service 2>/dev/null || true)"
  PREVIOUS_SERVICE_ACTIVE="$(systemctl --user is-active kdrive.service 2>/dev/null || true)"
  printf '%s\n' "$PREVIOUS_SERVICE_ENABLED" >"$BACKUP_DIR/enabled"
  printf '%s\n' "$PREVIOUS_SERVICE_ACTIVE" >"$BACKUP_DIR/active"
  INSTALL_BACKUP_ACTIVE=1
  if [[ "$PREVIOUS_SERVICE_ACTIVE" == active ]]; then
    systemctl --user stop kdrive.service
  fi
  if [[ -e "$CONFIG_HOME/systemd/user/kdrive.service" ]]; then
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
  package="$(find "$PACKAGE_CACHE" -maxdepth 1 -type f -name "$pattern" -print -quit 2>/dev/null || true)"
  if [[ -n "$package" ]]; then
    printf '%s\n' "$package"
    return 0
  fi
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
  local package_name version package destination package_real destination_real
  package_name="$(installed_package_name || true)"
  [[ -n "$package_name" ]] || return 0
  PREVIOUS_PACKAGE_NAME="$package_name"
  version="$(pacman -Q "$package_name" 2>/dev/null | awk '{print $2}' || true)"
  [[ -n "$version" ]] || return 0
  package="$(find_cached_package "${package_name}-${version}-*.pkg.tar.*" || true)"
  if [[ -n "$package" ]]; then
    destination="$PACKAGE_CACHE/$(basename -- "$package")"
    package_real="$(realpath -e -- "$package")"
    destination_real="$(realpath -m -- "$destination")"
    if [[ "$package_real" != "$destination_real" ]]; then
      install -m 0644 "$package" "$destination"
    fi
    printf '%s\n' "$destination" >"$STATE_ROOT/previous-package"
    printf '%s\n' "$package_name" >"$STATE_ROOT/previous-package-name"
  else
    die "installed $package_name package archive is unavailable; refusing an update without rollback"
  fi
}

build_package() {
  local -a args=(--syncdeps)
  ((ASSUME_YES)) && args+=(--noconfirm)
  if ! (cd "$SOURCE_ROOT" && makepkg "${args[@]}"); then
    return 1
  fi
  PACKAGE_FILE="$(find "$SOURCE_ROOT" -maxdepth 1 -type f -name 'kdrive-arch-*.pkg.tar.*' -print -quit)"
  [[ -n "$PACKAGE_FILE" ]] || die 'makepkg produced no kdrive-arch package'
}

install_built_package() {
  local package_name
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
  if ! run_pacman "${install_args[@]}" "$PACKAGE_FILE"; then
    return 1
  fi
  install -m 0644 "$PACKAGE_FILE" "$PACKAGE_CACHE/$(basename -- "$PACKAGE_FILE")"
  printf '%s\n' "$PACKAGE_CACHE/$(basename -- "$PACKAGE_FILE")" >"$STATE_ROOT/current-package"
}

restore_previous_package() {
  local package previous_name current_name
  current_name="$(installed_package_name || true)"
  if [[ -z "$PREVIOUS_PACKAGE_NAME" ]]; then
    if [[ -n "$current_name" ]]; then
      local -a remove_new_args=(-Rdd)
      ((ASSUME_YES)) && remove_new_args+=(--noconfirm)
      run_pacman "${remove_new_args[@]}" "$current_name" || true
    fi
    return 0
  fi
  package="$(cat "$STATE_ROOT/previous-package" 2>/dev/null || true)"
  [[ -f "$package" ]] || return 0
  previous_name="$(cat "$STATE_ROOT/previous-package-name" 2>/dev/null || true)"
  if [[ -n "$previous_name" && -n "$current_name" && "$previous_name" != "$current_name" ]]; then
    local -a remove_args=(-Rdd)
    ((ASSUME_YES)) && remove_args+=(--noconfirm)
    run_pacman "${remove_args[@]}" "$current_name" || true
  fi
  local -a args=(-U)
  ((ASSUME_YES)) && args+=(--noconfirm)
  if run_pacman "${args[@]}" "$package"; then
    printf '%s\n' "$package" >"$STATE_ROOT/current-package"
  fi
}

install_failure_trap() {
  local status="$?"
  trap - EXIT
  if ((INSTALL_BACKUP_ACTIVE)); then
    systemctl --user stop kdrive.service >/dev/null 2>&1 || true
    if ((INSTALL_PACKAGE_ROLLBACK_PENDING)); then
      restore_previous_package || true
    fi
    restore_user_state "$BACKUP_DIR" || true
  fi
  rm -rf -- "$TEMP_ROOT"
  exit "$status"
}

verify_runtime() {
  local fragment launcher main_pid executable
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
  main_pid="$(systemctl --user show kdrive.service -p MainPID --value 2>/dev/null || true)"
  [[ "$main_pid" =~ ^[1-9][0-9]*$ ]] || die 'kdrive.service has no running main process'
  executable="$(realpath -e "/proc/$main_pid/exe" 2>/dev/null || true)"
  [[ "$executable" == /opt/kdrive-arch/* ]] ||
    die "unexpected kDrive process executable: ${executable:-unavailable}"
  say "verified: pacman package, systemd owner, enabled service, process $main_pid at $executable"
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
      prepare_temp_root
      trap 'rm -rf -- "$TEMP_ROOT"' EXIT
      download_source
      say "verified latest release source at $SOURCE_ROOT"
      ;;
    install)
      prepare_temp_root
      trap 'rm -rf -- "$TEMP_ROOT"' EXIT
      download_source
      build_package
      mkdir -p -- "$PACKAGE_CACHE"
      save_previous_package
      trap 'install_failure_trap' EXIT
      snapshot_user_state
      install_built_package
      systemctl --user daemon-reload
      if ((START_SERVICE)); then
        systemctl --user enable kdrive.service
        if [[ "$PREVIOUS_SERVICE_ACTIVE" == active ]]; then
          systemctl --user restart kdrive.service
        else
          systemctl --user start kdrive.service
        fi
        verify_runtime
      fi
      INSTALL_PACKAGE_ROLLBACK_PENDING=0
      INSTALL_BACKUP_ACTIVE=0
      rm -rf -- "$TEMP_ROOT"
      trap - EXIT
      say 'kDrive installed from the latest verified release'
      ;;
  esac
}

main "$@"
