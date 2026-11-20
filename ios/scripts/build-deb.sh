#!/usr/bin/env bash
# Builds the rootless .deb (Dopamine, /var/jb): the app, phoneboxd and the SpringBoard tweak, without Theos.
# The Theos Makefiles in ios/ build the same thing; this script is for machines (and CI runners) without Theos.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

"$ROOT/ios/scripts/build-linux.sh"

STAGE="$OUT/deb"
rm -rf "$STAGE"
mkdir -p "$STAGE/var/jb/Applications" "$STAGE/var/jb/usr/libexec" "$STAGE/var/jb/Library/LaunchDaemons" \
         "$STAGE/var/jb/Library/MobileSubstrate/DynamicLibraries" "$STAGE/DEBIAN"

cp -R "$OUT/Payload/PhoneBox.app" "$STAGE/var/jb/Applications/PhoneBox.app"

cc -framework Foundation -I"$APP/Sources" "$ROOT/ios/daemon/main.m" "$APP/Sources/PBUsbListener.m" "$APP/Sources/PBFlags.m" \
   -o "$STAGE/var/jb/usr/libexec/phoneboxd"
sign "$STAGE/var/jb/usr/libexec/phoneboxd" "$ROOT/ios/daemon/entitlements.plist"

DYLIB="$STAGE/var/jb/Library/MobileSubstrate/DynamicLibraries/PhoneBoxSB.dylib"
cc -dynamiclib -install_name /var/jb/Library/MobileSubstrate/DynamicLibraries/PhoneBoxSB.dylib \
   -framework Foundation -framework UIKit -I"$APP/Sources" "$ROOT/ios/tweak/Tweak.m" "$APP/Sources/PBFlags.m" -o "$DYLIB"
sign "$DYLIB" "$ROOT/ios/daemon/entitlements.plist"
cp "$ROOT/ios/tweak/PhoneBoxSB.plist" "$STAGE/var/jb/Library/MobileSubstrate/DynamicLibraries/"

cp "$ROOT"/ios/layout/Library/LaunchDaemons/*.plist "$STAGE/var/jb/Library/LaunchDaemons/"
cp "$ROOT/ios/control" "$ROOT/ios/layout/DEBIAN/postinst" "$ROOT/ios/layout/DEBIAN/prerm" "$STAGE/DEBIAN/"
chmod 755 "$STAGE/DEBIAN/postinst" "$STAGE/DEBIAN/prerm"
SIZE=$(du -sk "$STAGE/var" | cut -f1)
echo "Installed-Size: $SIZE" >> "$STAGE/DEBIAN/control"

VERSION=$(sed -n 's/^Version: //p' "$ROOT/ios/control")
DEB="$OUT/com.ductruongvu23.phonebox-jb_${VERSION}_iphoneos-arm64.deb"
python3 "$ROOT/ios/scripts/mkdeb.py" "$STAGE" "$DEB"
echo "build: $DEB"
