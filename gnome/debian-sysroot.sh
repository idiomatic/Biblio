#!/bin/sh
# Builds a Debian 13 (trixie) sysroot for cross-compiling the GNOME app, such as for a
# Raspberry Pi running 64-bit Raspberry Pi OS:
#
#   ./debian-sysroot.sh arm64 /tmp/sysroot-arm64
#   zig build -Dtarget=aarch64-linux-gnu -Dsysroot=/tmp/sysroot-arm64/root
#
# It downloads the GTK, libadwaita and libsecret -dev packages (headers and their dependencies'
# headers) and the libraries the app links directly, and unpacks them into OUT/root. Needs
# curl, xz, ar and tar; no dpkg.
set -eu
arch="${1:-arm64}"
out="${2:-sysroot-$arch}"
mkdir -p "$out/debs" "$out/root"
out="$(cd "$out" && pwd)"
cd "$out"
[ -f Packages ] || curl -fsSL "https://deb.debian.org/debian/dists/trixie/main/binary-$arch/Packages.xz" | xz -d > Packages
packages="libgtk-4-dev libadwaita-1-dev libsecret-1-dev libglib2.0-dev libgio-2.0-dev libcairo2-dev libpango1.0-dev
libharfbuzz-dev libgdk-pixbuf-2.0-dev libgraphene-1.0-dev libfreetype-dev libfontconfig-dev libpng-dev libfribidi-dev
libvulkan-dev libx11-dev x11proto-dev libgcrypt20-dev libgpg-error-dev libappstream-dev libxrender-dev libxext-dev
zlib1g-dev libpixman-1-dev libepoxy-dev libwayland-dev libxkbcommon-dev
libgtk-4-1 libadwaita-1-0 libsecret-1-0 libglib2.0-0t64 libcairo2"
for name in $packages; do
    file=$(awk -v n="$name" '$1=="Package:"{p=($2==n)} p&&$1=="Filename:"{print $2; exit}' Packages)
    [ -n "$file" ] || { echo "$name isn't in trixie for $arch" >&2; exit 1; }
    deb="debs/$(basename "$file")"
    [ -f "$deb" ] || curl -fsSL -o "$deb" "https://deb.debian.org/debian/$file"
    tmp=$(mktemp -d)
    (cd "$tmp" && ar x "$out/$deb" && tar -xf data.tar.* -C "$out/root")
    rm -rf "$tmp"
done
echo "$out/root"
