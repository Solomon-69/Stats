#!/usr/bin/env bash
# build.sh: compile Stats.app with swiftc, sign, install to ~/Applications.
#   ./build.sh            test build (with the test hook), install and open in the background
#   RELEASE=1 ./build.sh  leaves the test hook out
#   NOINSTALL=1 ./build.sh  build only, in /private/tmp/stats-build
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT=/private/tmp/stats-build
TARGET="${TARGET:-arm64-apple-macos14.0}"
mkdir -p "$OUT"
if [ ! -f "$REPO/assets/Stats.icns" ]; then
  swiftc -O -framework AppKit "$REPO/make-icon.swift" -o "$OUT/mkicon"
  rm -rf "$OUT/Stats.iconset"; "$OUT/mkicon" "$OUT/Stats.iconset"
  iconutil -c icns "$OUT/Stats.iconset" -o "$REPO/assets/Stats.icns"
fi
xcrun clang -mmacosx-version-min=14.0 -fobjc-arc -c "$REPO/Bridge/reader.m" -I "$REPO/Bridge" -o "$OUT/reader.o"
FLAGS=(-O); [ "${RELEASE:-0}" = "1" ] || FLAGS+=(-D STATS_TEST -D UPDATER_TEST)
swiftc "${FLAGS[@]}" -parse-as-library -swift-version 5 -target "$TARGET" \
  -import-objc-header "$REPO/Bridge/Stats-Bridging-Header.h" \
  -framework AppKit -framework SwiftUI -framework ServiceManagement -framework IOKit -framework SystemConfiguration \
  "$REPO"/Sources/*.swift "$OUT/reader.o" -o "$OUT/StatsNew"
APP="$OUT/Stats.app"; rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$REPO/Info.plist" "$APP/Contents/"; cp "$OUT/StatsNew" "$APP/Contents/MacOS/"
cp "$REPO/assets/Stats.icns" "$APP/Contents/Resources/"
cp "$REPO/LICENSE" "$APP/Contents/Resources/LICENSE.txt"
xattr -cr "$APP"
SIGN_ID="$(cat "$REPO/.signing" 2>/dev/null || true)"
if [ -n "$SIGN_ID" ]; then codesign --force --deep --sign "$SIGN_ID" "$APP" 2>/dev/null || codesign --force --deep --sign - "$APP"
else codesign --force --deep --sign - "$APP"; fi
[ "${NOINSTALL:-0}" = "1" ] && { echo "built $APP"; exit 0; }
pkill -x StatsNew 2>/dev/null || true
mkdir -p ~/Applications
rm -rf ~/Applications/Stats.app; ditto "$APP" ~/Applications/Stats.app
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f ~/Applications/Stats.app
open -g ~/Applications/Stats.app
echo "installed ~/Applications/Stats.app"
