pkgname=kdrive-arch
pkgver=3.8.7.1
pkgrel=14
pkgdesc='Arch Linux/CachyOS kDrive desktop client'
arch=('x86_64')
options=('!strip' '!debug')
url='https://github.com/shubinlab/kdrive-arch'
license=('GPL-3.0-or-later')
depends=('qt6-base' 'qt6-svg' 'glib2' 'libsecret' 'libzip' 'curl' 'c-ares' 'openssl' 'wayland' 'systemd')
makedepends=('clang' 'cmake' 'git' 'python' 'python-pip')
source=('desktop-kDrive::git+https://github.com/Infomaniak/desktop-kDrive.git#commit=b14222be555cc9f934e9ed2ec7bb36beb9c437a5')
sha256sums=('SKIP')

_tools="$startdir/build"
# The bundled kdrive-install.sh retains explicit --rollback for non-pacman installs.

prepare() {
  git -C "$srcdir/desktop-kDrive" submodule update --init --recursive
}

build() {
  "$_tools/build-package.sh" \
    --source "$srcdir/desktop-kDrive" \
    --output "$srcdir/dist"
}

package() {
  local bundle="$srcdir/dist/kdrive-${pkgver}-arch.tar.gz"
  local root="$pkgdir/opt/kdrive-arch/$pkgver"

  install -d "$root"
  tar -xzf "$bundle" -C "$pkgdir/opt/kdrive-arch"
  mv "$pkgdir/opt/kdrive-arch/kdrive-${pkgver}-arch"/* "$root/"
  rmdir "$pkgdir/opt/kdrive-arch/kdrive-${pkgver}-arch"

  install -d "$pkgdir/usr/bin" "$pkgdir/usr/lib/systemd/user"
  sed "s/@KDRIVE_VERSION@/$pkgver/g" \
    "$startdir/kdrive-arch.in" >"$pkgdir/usr/bin/kdrive-arch"
  chmod 0755 "$pkgdir/usr/bin/kdrive-arch"

  install -d "$pkgdir/usr/share/applications"
  sed 's|^Exec=.*|Exec=/usr/bin/kdrive-arch %u|' \
    "$root/share/applications/kDrive_client.desktop" >"$pkgdir/usr/share/applications/kDrive_client.desktop"
  chmod 0644 "$pkgdir/usr/share/applications/kDrive_client.desktop"

  install -m 0644 "$startdir/kdrive.service" \
    "$pkgdir/usr/lib/systemd/user/kdrive.service"
}
