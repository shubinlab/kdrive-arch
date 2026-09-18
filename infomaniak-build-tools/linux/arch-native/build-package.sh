#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SOURCE_DIR=""
OUTPUT_DIR=""
CONAN_OUTPUT=""

die() { printf 'kdrive-build: %s\n' "$*" >&2; exit 1; }
usage() {
  cat <<'EOF'
Usage: build-package.sh --source <official-3.8.7-checkout> --output <directory>

The source checkout must include git submodules. Conan 2, CMake, Clang, and
objcopy are required. The output directory receives the runtime bundle and a
separate debug-symbol bundle; no system files are changed.
EOF
}

while (($#)); do
  case "$1" in
    --source) SOURCE_DIR="${2:-}"; shift 2 ;;
    --output) OUTPUT_DIR="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

[[ -n "$SOURCE_DIR" && -n "$OUTPUT_DIR" ]] || { usage >&2; exit 2; }
[[ -e "$SOURCE_DIR/.git" ]] || die 'source must be a git checkout with submodules'
[[ -f "$SOURCE_DIR/src/3rdparty/keychain/src/keychain_linux.cpp" ]] || die 'submodules are not initialized'
for command_name in cmake conan objcopy clang clang++ patch; do
  command -v "$command_name" >/dev/null 2>&1 || die "required command not found: $command_name"
done

SOURCE_DIR="$(cd -- "$SOURCE_DIR" && pwd -P)"
OUTPUT_DIR="$(mkdir -p -- "$OUTPUT_DIR" && cd -- "$OUTPUT_DIR" && pwd -P)"
CONAN_OUTPUT="$OUTPUT_DIR/conan"
BUILD_DIR="$OUTPUT_DIR/build"

git -C "$SOURCE_DIR" diff --quiet || die 'source checkout has local changes; use a clean tag checkout'
git -C "$SOURCE_DIR" diff --cached --quiet || die 'source checkout has staged changes; use a clean tag checkout'
source_commit="$(git -C "$SOURCE_DIR" rev-parse HEAD)"
[[ "$source_commit" == b14222be555cc9f934e9ed2ec7bb36beb9c437a5 ]] ||
  die "source must be official 3.8.7 (b14222be555cc9f934e9ed2ec7bb36beb9c437a5), got $source_commit"

# Apply the Arch delta to a disposable copy. The caller's clean upstream
# checkout remains reusable for another build and for upstream comparisons.
WORKTREE_DIR="$(mktemp -d "$OUTPUT_DIR/.kdrive-source.XXXXXX")"
cleanup() { rm -rf -- "$WORKTREE_DIR"; }
trap cleanup EXIT
cp -a -- "$SOURCE_DIR"/. "$WORKTREE_DIR"/
rm -rf -- "$WORKTREE_DIR/.git"
patch --directory="$WORKTREE_DIR" --batch --forward --strip=1 \
  <"$SCRIPT_DIR/arch-native-3.8.7.1.patch" >/dev/null ||
  die 'native Arch patch does not apply to official 3.8.7'

export KDRIVE_USE_SYSTEM_QT=1
export KDRIVE_OUTPUT_DIR="$CONAN_OUTPUT"
conan install "$WORKTREE_DIR" --output-folder "$CONAN_OUTPUT" --build=missing \
  -s:h build_type=RelWithDebInfo -s:b build_type=RelWithDebInfo

rm -rf -- "$BUILD_DIR"
cmake -S "$WORKTREE_DIR" -B "$BUILD_DIR" \
  -DCMAKE_BUILD_TYPE=RelWithDebInfo \
  -DCMAKE_CXX_STANDARD=20 \
  -DCMAKE_CXX_COMPILER=clang++ \
  -DCMAKE_C_COMPILER=clang \
  -DCMAKE_INSTALL_PREFIX="$BUILD_DIR/install" \
  -DBIN_INSTALL_DIR="$BUILD_DIR/bin" \
  -DBUILD_CLIENT=ON \
  -DBUILD_UNIT_TESTS=OFF \
  -DKDRIVE_DISABLE_SENTRY=ON \
  -DKDRIVE_USE_SYSTEM_QT=ON \
  -DKDRIVE_THEME_DIR="$WORKTREE_DIR/infomaniak" \
  -DCONAN_DEP_DIR="$CONAN_OUTPUT" \
  -DCMAKE_INSTALL_RPATH='$ORIGIN/../lib' \
  -DCMAKE_BUILD_WITH_INSTALL_RPATH=ON \
  -DCMAKE_TOOLCHAIN_FILE="$CONAN_OUTPUT/build/RelWithDebInfo/generators/conan_toolchain.cmake"
cmake --build "$BUILD_DIR" --parallel "${KDRIVE_BUILD_JOBS:-2}"
cmake --install "$BUILD_DIR" --prefix "$BUILD_DIR/install"

version="$(awk '/KDRIVE_VERSION_FULL/ { gsub(/"/, "", $3); print $3; exit }' "$BUILD_DIR/version.h")"
[[ "$version" =~ ^3\.8\.[0-9]+\.[0-9]+$ ]] || die "unexpected built version: $version"
RUNTIME_DIR="$OUTPUT_DIR/kdrive-${version}-native-arch"
SYMBOL_DIR="$OUTPUT_DIR/kdrive-${version}-native-arch-debug"
rm -rf -- "$RUNTIME_DIR" "$SYMBOL_DIR"
mkdir -p -- "$RUNTIME_DIR/bin" "$RUNTIME_DIR/lib" "$RUNTIME_DIR/share" "$SYMBOL_DIR"
cp -a "$BUILD_DIR/install/bin/kDrive" "$BUILD_DIR/install/bin/kDrive_client" "$BUILD_DIR/install/bin/sync-exclude.lst" "$RUNTIME_DIR/bin/"
cp -a "$BUILD_DIR/install/share/applications" "$BUILD_DIR/install/share/icons" "$RUNTIME_DIR/share/"
desktop_file="$RUNTIME_DIR/share/applications/kDrive_client.desktop"
sed -i \
  -e 's|^Exec=.*|Exec=kDrive %u|' \
  -e 's|^MimeType=.*|MimeType=application/vnd.kDrive;x-scheme-handler/kdrive;|' \
  "$desktop_file"
for library in "$CONAN_OUTPUT"/lib*.so*; do cp -a "$library" "$RUNTIME_DIR/lib/"; done
for binary in kDrive kDrive_client; do
  objcopy --only-keep-debug "$RUNTIME_DIR/bin/$binary" "$SYMBOL_DIR/$binary.dbg"
  objcopy --strip-debug "$RUNTIME_DIR/bin/$binary"
  objcopy --add-gnu-debuglink="$SYMBOL_DIR/$binary.dbg" "$RUNTIME_DIR/bin/$binary"
done
rm -f -- "$RUNTIME_DIR/bin/crashpad_handler" "$RUNTIME_DIR/lib/libkeychain.a"
rm -rf -- "$RUNTIME_DIR/include"
install -D -m 0644 "$SCRIPT_DIR/kdrive.service" "$RUNTIME_DIR/systemd/kdrive.service"
install -D -m 0755 "$SCRIPT_DIR/install.sh" "$RUNTIME_DIR/kdrive-install.sh"
cat >"$RUNTIME_DIR/MANIFEST" <<EOF
package=kDrive-${version}-native-arch
source_commit=$source_commit
build_type=RelWithDebInfo
compiler=$(clang++ --version | head -n 1)
qt=system-Qt6
openssl=system-OpenSSL3
host_requirements=qt6-base qt6-svg glib2 libsecret libzip curl c-ares openssl wayland
sentry_policy=linked SDK, activation forced off at compile time by KDRIVE_DISABLE_SENTRY=ON; crashpad_handler omitted
lifecycle=systemd-user-only; native desktop autostart removed by source patch
runtime_pruned=static archives, public headers, debug sections, crashpad helper
EOF
sha256sum "$RUNTIME_DIR/bin/kDrive" "$RUNTIME_DIR/bin/kDrive_client" "$RUNTIME_DIR/bin/sync-exclude.lst" "$RUNTIME_DIR/kdrive-install.sh" "$RUNTIME_DIR/systemd/kdrive.service" >"$RUNTIME_DIR/SHA256SUMS"
tar -C "$OUTPUT_DIR" --sort=name --mtime='UTC 1970-01-01' --owner=0 --group=0 --numeric-owner \
  -czf "$OUTPUT_DIR/kdrive-${version}-native-arch.tar.gz" "$(basename "$RUNTIME_DIR")"
tar -C "$OUTPUT_DIR" --sort=name --mtime='UTC 1970-01-01' --owner=0 --group=0 --numeric-owner \
  -czf "$OUTPUT_DIR/kdrive-${version}-native-arch-debug.tar.gz" "$(basename "$SYMBOL_DIR")"
printf 'kDrive build complete: %s\n' "$OUTPUT_DIR/kdrive-${version}-native-arch.tar.gz"
