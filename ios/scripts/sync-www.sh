#!/usr/bin/env bash
# Copies the Android panel (the shared web UI) into the iOS app bundle resources and patches it for iOS.
# Never edit android/.../www from the iOS side: every fix goes in here, so upstream merges stay clean.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SRC="$ROOT/android/app/src/main/assets/www"
DST="$ROOT/ios/app/Resources/www"

[ -f "$SRC/index.html" ] || { echo "sync-www: $SRC/index.html not found" >&2; exit 1; }

mkdir -p "$DST"
rsync -a --delete "$SRC/" "$DST/"
cp "$ROOT/ios/app/bridge.js" "$DST/bridge.js"

python3 - "$DST/index.html" <<'PY'
import re, sys
path = sys.argv[1]
s = open(path, encoding="utf-8").read()

def sub(label, pattern, repl, flags=0):
    global s
    s, n = re.subn(pattern, lambda m: repl, s, count=1, flags=flags)
    if n != 1:
        sys.exit("sync-www: patch '%s' no longer matches upstream index.html" % label)

# 1. The native bridge shim must run before compat.js and main.js read window.Android.
sub("bridge", r'<script src="compat\.js"></script>',
    '<script src="bridge.js"></script>\n<script src="compat.js"></script>')

# 2. "Too old" message: no Android System WebView on iOS.
sub("too-old", r"'This Android System WebView is too old.*?open PhoneBox again\.'",
    "'This iOS version is too old to run the panel. Update iOS to 14 or later, then open PhoneBox again.'", re.S)

# 3. Container queries (cqw/cqh) need Safari 16: say so instead of naming Android System WebView.
sub("cq-notice", r"    if \(window\.CSS && typeof CSS\.supports === 'function' && CSS\.supports\('font-size', '1cqw'\)\) return;",
    "    if (/iPhone|iPad|iPod/.test(navigator.userAgent)) {\n"
    "      var t = el.querySelector('span');\n"
    "      if (t) { t.removeAttribute('data-i18n'); t.textContent = 'Widgets scale fully on iOS 16 or later.'; }\n"
    "    }\n"
    "    if (window.CSS && typeof CSS.supports === 'function' && CSS.supports('font-size', '1cqw')) return;")

open(path, "w", encoding="utf-8").write(s)
PY

echo "sync-www: ok -> $DST ($(find "$DST" -type f | wc -l | tr -d ' ') files)"
