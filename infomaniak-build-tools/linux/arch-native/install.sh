#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
ACTION=check
BUNDLE=""
PREFIX_ROOT="${KDRIVE_PREFIX_ROOT:-${HOME}/.local/opt}"
LAUNCHER_DIR="${HOME}/.local/bin"
CONFIG_HOME="${XDG_CONFIG_HOME:-${HOME}/.config}"
DATA_HOME="${XDG_DATA_HOME:-${HOME}/.local/share}"
STATE_HOME="${XDG_STATE_HOME:-${HOME}/.local/state}"
UNIT_DIR="${CONFIG_HOME}/systemd/user"
SERVICE_TARGET="${UNIT_DIR}/kdrive.service"
AUTOSTART_TARGET="${CONFIG_HOME}/autostart/kDrive.desktop"
DESKTOP_TARGET="${DATA_HOME}/applications/kDrive_client.desktop"
BACKUP_ROOT="${KDRIVE_BACKUP_ROOT:-${STATE_HOME}/kdrive/backups}"

die() { printf 'kdrive-install: %s\n' "$*" >&2; exit 1; }
usage() {
  cat <<'EOF'
Usage:
  kdrive-install.sh --apply <runtime-bundle>
  kdrive-install.sh --check
  kdrive-install.sh --rollback

The installer is user-scoped. It never modifies kDrive account databases or
synchronized folders. A successful apply keeps the previous versioned prefix.
EOF
}

while (($#)); do
  case "$1" in
    --apply) ACTION=apply; BUNDLE="${2:-}"; shift 2 ;;
    --check) ACTION=check; shift ;;
    --rollback) ACTION=rollback; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

[[ "${EUID}" -ne 0 ]] || die 'run as the normal user, not root'
command -v systemctl >/dev/null 2>&1 || die 'systemctl is required'
command -v install >/dev/null 2>&1 || die 'install is required'

validate_bundle() {
  local root="$1"
  [[ -d "$root" ]] || die "bundle is not a directory: $root"
  [[ -x "$root/bin/kDrive" ]] || die 'bundle is missing executable bin/kDrive'
  [[ -x "$root/bin/kDrive_client" ]] || die 'bundle is missing executable bin/kDrive_client'
  [[ -r "$root/bin/sync-exclude.lst" ]] || die 'bundle is missing bin/sync-exclude.lst'
  [[ -r "$root/share/applications/kDrive_client.desktop" ]] || die 'bundle is missing desktop entry'
  [[ -r "$root/systemd/kdrive.service" ]] || die 'bundle is missing systemd/kdrive.service'
  [[ -r "$root/MANIFEST" ]] || die 'bundle is missing MANIFEST'
  grep -q '^lifecycle=systemd-user-only' "$root/MANIFEST" || die 'bundle lifecycle policy is not systemd-user-only'
  grep -q '^sentry_policy=' "$root/MANIFEST" || die 'bundle Sentry policy is undocumented'
}

capture_path() {
  local path="$1" out="$2"
  if [[ -L "$path" ]]; then
    printf 'symlink\n%s\n' "$(readlink "$path")" >"$out"
  elif [[ -f "$path" ]]; then
    printf 'file\n' >"$out"
    cp -a -- "$path" "${out}.data"
  else
    printf 'absent\n' >"$out"
  fi
}

restore_path() {
  local path="$1" state="$2" kind target
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

check_runtime() {
  [[ -L "${LAUNCHER_DIR}/kDrive" && -x "$(readlink -f "${LAUNCHER_DIR}/kDrive")" ]] || die 'launcher symlink is not active'
  [[ -L "${LAUNCHER_DIR}/sync-exclude.lst" && -r "$(readlink -f "${LAUNCHER_DIR}/sync-exclude.lst")" ]] || die 'sync-exclude symlink is not active'
  [[ -r "$SERVICE_TARGET" ]] || die 'kdrive.service is not installed'
  systemd-analyze --user verify "$SERVICE_TARGET"
  [[ "$(systemctl --user is-enabled kdrive.service 2>/dev/null || true)" == enabled ]] || die 'kdrive.service is not enabled'
  [[ "$(systemctl --user is-active kdrive.service 2>/dev/null || true)" == active ]] || die 'kdrive.service is not active'
  printf 'OK kDrive: systemd owner, launcher/resource links, unit verification, and active service\n'
}

latest_backup() {
  find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null | sort -r | head -n 1
}

if [[ "$ACTION" == check ]]; then
  check_runtime
  exit 0
fi

if [[ "$ACTION" == rollback ]]; then
  backup_id="$(latest_backup)"
  [[ -n "$backup_id" ]] || die 'no kDrive rollback backup found'
  backup="$BACKUP_ROOT/$backup_id"
  systemctl --user stop kdrive.service >/dev/null 2>&1 || true
  restore_path "${LAUNCHER_DIR}/kDrive" "$backup/kDrive.state"
  restore_path "${LAUNCHER_DIR}/sync-exclude.lst" "$backup/sync-exclude.lst.state"
  restore_path "$SERVICE_TARGET" "$backup/kdrive.service.state"
  restore_path "$DESKTOP_TARGET" "$backup/kDrive_client.desktop.state"
  restore_path "$AUTOSTART_TARGET" "$backup/kDrive.autostart.state"
  systemctl --user daemon-reload
  if [[ "$(cat "$backup/enabled")" == enabled ]]; then systemctl --user enable kdrive.service >/dev/null; else systemctl --user disable kdrive.service >/dev/null 2>&1 || true; fi
  if [[ "$(cat "$backup/active")" == active ]]; then systemctl --user start kdrive.service; fi
  printf 'kDrive rollback restored backup %s\n' "$backup_id"
  exit 0
fi

[[ -n "$BUNDLE" ]] || die '--apply requires a runtime bundle directory'
validate_bundle "$BUNDLE"
BUNDLE="$(cd -- "$BUNDLE" && pwd -P)"
bundle_name="$(basename -- "$BUNDLE")"
target="${PREFIX_ROOT}/${bundle_name}"
[[ ! -e "$target" ]] || die "target already exists; choose a new versioned bundle: $target"

mkdir -p -- "$BACKUP_ROOT" "$PREFIX_ROOT" "$LAUNCHER_DIR" "$UNIT_DIR" "$(dirname -- "$DESKTOP_TARGET")" "$(dirname -- "$AUTOSTART_TARGET")"
backup_id="$(date -u +%Y%m%dT%H%M%SZ)-$BASHPID"
backup="$BACKUP_ROOT/$backup_id"
mkdir -m 0700 -- "$backup"
capture_path "${LAUNCHER_DIR}/kDrive" "$backup/kDrive.state"
capture_path "${LAUNCHER_DIR}/sync-exclude.lst" "$backup/sync-exclude.lst.state"
capture_path "$SERVICE_TARGET" "$backup/kdrive.service.state"
capture_path "$DESKTOP_TARGET" "$backup/kDrive_client.desktop.state"
capture_path "$AUTOSTART_TARGET" "$backup/kDrive.autostart.state"
printf '%s\n' "$(systemctl --user is-enabled kdrive.service 2>/dev/null || true)" >"$backup/enabled"
printf '%s\n' "$(systemctl --user is-active kdrive.service 2>/dev/null || true)" >"$backup/active"

rollback_on_error() {
  local status="$?"
  if ((status != 0)); then
    systemctl --user stop kdrive.service >/dev/null 2>&1 || true
    restore_path "${LAUNCHER_DIR}/kDrive" "$backup/kDrive.state" || true
    restore_path "${LAUNCHER_DIR}/sync-exclude.lst" "$backup/sync-exclude.lst.state" || true
    restore_path "$SERVICE_TARGET" "$backup/kdrive.service.state" || true
    restore_path "$DESKTOP_TARGET" "$backup/kDrive_client.desktop.state" || true
    restore_path "$AUTOSTART_TARGET" "$backup/kDrive.autostart.state" || true
    systemctl --user daemon-reload >/dev/null 2>&1 || true
    if [[ "$(cat "$backup/active")" == active ]]; then systemctl --user start kdrive.service >/dev/null 2>&1 || true; fi
    printf 'kDrive apply failed; previous state restored from %s\n' "$backup_id" >&2
  fi
  exit "$status"
}
trap rollback_on_error EXIT

staging="$(mktemp -d "${PREFIX_ROOT}/.kdrive-install.XXXXXX")"
cp -a -- "$BUNDLE"/. "$staging"/
mv -- "$staging" "$target"

systemctl --user stop kdrive.service >/dev/null 2>&1 || true
ln -sfn -- "$target/bin/kDrive" "${LAUNCHER_DIR}/kDrive"
ln -sfn -- "$target/bin/sync-exclude.lst" "${LAUNCHER_DIR}/sync-exclude.lst"
install -D -m 0644 "$target/systemd/kdrive.service" "$SERVICE_TARGET"
awk -v exec="${HOME}/.local/bin/kDrive" -v icon="$target/share/icons/hicolor/512x512/apps/kdrive-win.png" \
  'BEGIN { found_exec=0; found_icon=0 }
   /^Exec=/ { print "Exec=" exec; found_exec=1; next }
   /^Icon=/ { print "Icon=" icon; found_icon=1; next }
   { print }
   END { if (!found_exec) print "Exec=" exec; if (!found_icon) print "Icon=" icon }' \
  "$target/share/applications/kDrive_client.desktop" >"${DESKTOP_TARGET}.tmp"
install -m 0644 "${DESKTOP_TARGET}.tmp" "$DESKTOP_TARGET"
rm -f -- "${DESKTOP_TARGET}.tmp"
if [[ -f "$AUTOSTART_TARGET" ]] && grep -q '^Name=kDrive$' "$AUTOSTART_TARGET"; then
  rm -f -- "$AUTOSTART_TARGET"
fi
systemctl --user daemon-reload
systemctl --user enable --now kdrive.service
check_runtime
trap - EXIT
printf 'kDrive applied: %s (rollback backup: %s)\n' "$target" "$backup"
