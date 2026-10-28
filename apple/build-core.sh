#!/bin/sh
# Builds libbiblio for every Apple platform and packages it as BiblioCore.xcframework,
# which the Biblio Xcode project links. Run from anywhere; Xcode runs it before compiling.
set -eu
here="$(cd "$(dirname "$0")" && pwd)"
core="$here/../core"
out="$here/build"
zig="${ZIG:-$(command -v zig || echo /opt/homebrew/bin/zig)}"

optimize=safe
[ "${CONFIGURATION:-Release}" = "Debug" ] || optimize=fast

(cd "$core" && "$zig" build apple -Doptimize="$optimize" --prefix "$out/zig")

lib="$out/zig/apple"
mkdir -p "$out/fat/macos" "$out/fat/ios-sim" "$out/headers"
lipo -create "$lib/macos-arm64/libbiblio.a" "$lib/macos-x86_64/libbiblio.a" -output "$out/fat/macos/libbiblio.a"
lipo -create "$lib/ios-sim-arm64/libbiblio.a" "$lib/ios-sim-x86_64/libbiblio.a" -output "$out/fat/ios-sim/libbiblio.a"
cp "$core/include/biblio.h" "$out/headers/"
cat > "$out/headers/module.modulemap" <<'MAP'
module BiblioCore {
    header "biblio.h"
    export *
}
MAP

rm -rf "$out/BiblioCore.xcframework"
xcodebuild -create-xcframework \
    -library "$out/fat/macos/libbiblio.a" -headers "$out/headers" \
    -library "$lib/ios-arm64/libbiblio.a" -headers "$out/headers" \
    -library "$out/fat/ios-sim/libbiblio.a" -headers "$out/headers" \
    -output "$out/BiblioCore.xcframework" >/dev/null
echo "$out/BiblioCore.xcframework"
