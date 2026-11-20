#!/usr/bin/env bash
# Builds PhoneBox.app and PhoneBox.ipa with plain clang (no Theos, no Xcode project).
# Linux: clang + ld64.lld + a Theos iPhoneOS SDK. macOS: Xcode's SDK and linker.
#   SDK=/path/to/iPhoneOS.sdk   LDID=/path/to/ldid   DEFS="-DDEBUG" (web inspector on iOS 16.4+)
#   PLATFORM=simulator          macOS only: ios/build/sim/PhoneBox.app for the iOS Simulator
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

"$ROOT/ios/scripts/sync-www.sh"

BUNDLE="$OUT/Payload/PhoneBox.app"
[ "${PLATFORM:-}" = simulator ] && BUNDLE="$OUT/sim/PhoneBox.app"
rm -rf "$BUNDLE"; mkdir -p "$BUNDLE"

cc -framework UIKit -framework WebKit -framework Foundation -framework Speech \
   -framework AVFoundation -framework AudioToolbox \
   "$APP"/Sources/*.m -o "$BUNDLE/PhoneBox"

cp "$APP/Resources/Info.plist" "$BUNDLE/Info.plist"
cp -R "$APP/Resources/www" "$BUNDLE/www"
for png in "$APP"/Resources/AppIcon*@*.png; do cp "$png" "$BUNDLE/"; done # the 1024 px master stays out of the bundle

if [ "${PLATFORM:-}" = simulator ]; then
  codesign -f -s - --entitlements "$APP/entitlements.plist" "$BUNDLE"
  echo "build: $BUNDLE"
  exit 0
fi

sign "$BUNDLE/PhoneBox" "$APP/entitlements.plist"
( cd "$OUT" && rm -f PhoneBox.ipa && zip -qry PhoneBox.ipa Payload )
echo "build: $OUT/PhoneBox.ipa"
