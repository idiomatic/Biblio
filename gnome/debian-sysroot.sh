#!/bin/sh
# Builds a Debian 13 (trixie) sysroot for cross-compiling the GNOME app, such as for a
# Raspberry Pi running 64-bit Raspberry Pi OS:
#
#   ./debian-sysroot.sh arm64 /tmp/sysroot-arm64
#   zig build -Dtarget=aarch64-linux-gnu -Dsysroot=/tmp/sysroot-arm64/root
#
# It downloads the GTK, libadwaita, and libsecret -dev packages (headers and their dependencies'
# headers) and the libraries the app links directly, and unpacks them into OUT/root. When done,
# it writes OUT/complete, and later runs return at once; delete it to build the sysroot again.
# Needs curl, xz, zstd, ar, and tar; no dpkg.
set -eu
arch="${1:-arm64}"
out="${2:-sysroot-$arch}"
mkdir -p "$out/debs" "$out/root"
out="$(cd "$out" && pwd)"
cd "$out"
[ ! -f complete ] || { echo "$out/root"; exit 0; }

# The package index, fetched again when over a day old or when a package it names is gone (after
# a point release).
index() {
    curl -fsSL "https://deb.debian.org/debian/dists/trixie/main/binary-$arch/Packages.xz" | xz -d > Packages.part
    mv Packages.part Packages
}
[ -n "$(find Packages -mtime -1 2>/dev/null)" ] || index
filename() {
    awk -v n="$1" '$1=="Package:"{p=($2==n)} p&&$1=="Filename:"{print $2; exit}' Packages
}

packages="libgtk-4-dev libadwaita-1-dev libsecret-1-dev libglib2.0-dev libgio-2.0-dev libcairo2-dev libpango1.0-dev
libharfbuzz-dev libgdk-pixbuf-2.0-dev libgraphene-1.0-dev libfreetype-dev libfontconfig-dev libpng-dev libfribidi-dev
libvulkan-dev libx11-dev x11proto-dev libgcrypt20-dev libgpg-error-dev libappstream-dev libxrender-dev libxext-dev
zlib1g-dev libpixman-1-dev libepoxy-dev libwayland-dev libxkbcommon-dev
libgtk-4-1 libadwaita-1-0 libsecret-1-0 libglib2.0-0t64 libcairo2"
for name in $packages; do
    file=$(filename "$name")
    deb="debs/$(basename "$file")"
    if [ -z "$file" ] || { [ ! -f "$deb" ] && ! curl -fsSL -o "$deb.part" "https://deb.debian.org/debian/$file"; }; then
        index
        file=$(filename "$name")
        [ -n "$file" ] || { echo "$name isn't in trixie for $arch" >&2; exit 1; }
        deb="debs/$(basename "$file")"
        [ -f "$deb" ] || curl -fsSL -o "$deb.part" "https://deb.debian.org/debian/$file"
    fi
    [ -f "$deb" ] || mv "$deb.part" "$deb"
    tmp=$(mktemp -d)
    (
        cd "$tmp" && ar x "$out/$deb"
        case $(echo data.tar.*) in
            *.zst) zstd -dcq data.tar.zst ;;
            *.xz) xz -dc data.tar.xz ;;
            *.gz) gzip -dc data.tar.gz ;;
            *) cat data.tar ;;
        esac | tar -xf - -C "$out/root"
    )
    rm -rf "$tmp"
done
touch complete
echo "$out/root"
