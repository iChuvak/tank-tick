#!/bin/bash
# Builds TankTick.app in one go. Requires Xcode Command Line Tools:
#   xcode-select --install
set -euo pipefail
cd "$(dirname "$0")"

APP="TankTick"
OUT="build/$APP.app"
rm -rf build
mkdir -p "$OUT/Contents/MacOS" "$OUT/Contents/Resources"

echo "→ Compiling…"
swiftc -O \
  -target "$(uname -m)-apple-macos12.0" \
  -framework AppKit -framework ServiceManagement -framework UserNotifications \
  -o "$OUT/Contents/MacOS/$APP" \
  Sources/*.swift

cp Info.plist "$OUT/Contents/Info.plist"
if [ -d icon/AppIcon.iconset ]; then
  echo "→ App icon…"
  iconutil -c icns icon/AppIcon.iconset -o "$OUT/Contents/Resources/AppIcon.icns"
fi
echo -n "APPL????" > "$OUT/Contents/PkgInfo"

echo "→ Signing (ad-hoc)…"
codesign --force --deep --sign - "$OUT"

echo
echo "Done: $PWD/$OUT"
echo "Run:      open \"$OUT\""
echo "Install:  cp -R \"$OUT\" /Applications/"
