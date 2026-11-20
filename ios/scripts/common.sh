# Shared by build-linux.sh and build-deb.sh: where things are and how to call clang for iOS.
# Env: SDK, PLATFORM=simulator (macOS only), DEFS (extra clang flags), LDID.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
APP="$ROOT/ios/app"
OUT="$ROOT/ios/build"
MIN=15.0

TARGET=arm64-apple-ios$MIN
if [ "${PLATFORM:-}" = simulator ]; then
  SDK="$(xcrun --sdk iphonesimulator --show-sdk-path)"
  TARGET=$(uname -m)-apple-ios$MIN-simulator
fi
if [ -z "${SDK:-}" ]; then
  if [ "$(uname)" = Darwin ] && command -v xcrun >/dev/null; then
    SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
  else
    SDK="${THEOS:-$HOME/theos}/sdks/iPhoneOS15.6.sdk"
  fi
fi
[ -d "$SDK" ] || { echo "build: SDK not found: $SDK (set SDK=...)" >&2; exit 1; }

LINK=()
[ "$(uname)" = Darwin ] || LINK=(-fuse-ld=lld)

# cc <extra clang args...>: clang for the iOS target
cc() { clang -target "$TARGET" ${DEFS:-} -isysroot "$SDK" -fobjc-arc -fmodules -O2 -Wall ${LINK[@]+"${LINK[@]}"} "$@"; }

# sign <file> <entitlements.plist>: ldid when present (jailbreak and TrollStore need it); ad-hoc codesign on macOS otherwise
sign() {
  local LD="${LDID:-$(command -v ldid || true)}"
  if [ -n "$LD" ]; then "$LD" -S"$2" "$1"
  elif [ "$(uname)" = Darwin ]; then codesign -f -s - --entitlements "$2" "$1" 2>/dev/null
  else echo "build: ldid not found; $1 is unsigned" >&2; fi
}
