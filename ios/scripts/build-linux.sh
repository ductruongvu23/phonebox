#!/usr/bin/env bash
# Builds PhoneBox.app and an unsigned-ish .ipa with plain clang (no Theos, no Xcode project).
# Works on Linux (clang + ld64.lld + a Theos iPhoneOS SDK) and on macOS (Xcode's SDK and linker).
#   SDK=/path/to/iPhoneOS.sdk   override the SDK
#   LDID=/path/to/ldid          override the signer (fake-signs with entitlements.plist)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
APP="$ROOT/ios/app"
OUT="$ROOT/ios/build"
MIN=15.0

if [ -z "${SDK:-}" ]; then
  if [ "$(uname)" = Darwin ] && command -v xcrun >/dev/null; then
    SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
  else
    SDK="${THEOS:-$HOME/theos}/sdks/iPhoneOS15.6.sdk"
  fi
fi
[ -d "$SDK" ] || { echo "build: SDK not found: $SDK (set SDK=...)" >&2; exit 1; }

"$ROOT/ios/scripts/sync-www.sh"

LINK=()
[ "$(uname)" = Darwin ] || LINK=(-fuse-ld=lld)

rm -rf "$OUT"; mkdir -p "$OUT/Payload/PhoneBox.app"
BUNDLE="$OUT/Payload/PhoneBox.app"

clang -target arm64-apple-ios$MIN -isysroot "$SDK" -fobjc-arc -fmodules -O2 -Wall \
  ${LINK[@]+"${LINK[@]}"} \
  -framework UIKit -framework WebKit -framework Foundation -framework Speech \
  -framework AVFoundation -framework AudioToolbox \
  "$APP"/Sources/*.m -o "$BUNDLE/PhoneBox"

cp "$APP/Resources/Info.plist" "$BUNDLE/Info.plist"
cp -R "$APP/Resources/www" "$BUNDLE/www"

LDID="${LDID:-$(command -v ldid || true)}"
if [ -n "$LDID" ]; then
  "$LDID" -S"$APP/entitlements.plist" "$BUNDLE/PhoneBox"
elif [ "$(uname)" = Darwin ]; then
  codesign -f -s - --entitlements "$APP/entitlements.plist" "$BUNDLE/PhoneBox"
else
  echo "build: ldid not found; the binary is unsigned (TrollStore will not install it)" >&2
fi

( cd "$OUT" && rm -f PhoneBox.ipa && zip -qry PhoneBox.ipa Payload )
echo "build: $OUT/PhoneBox.ipa"
