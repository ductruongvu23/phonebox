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
cp "$ROOT/ios/app/cq-polyfill.js" "$DST/cq-polyfill.js"

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
    '<script src="bridge.js"></script>\n<script src="cq-polyfill.js"></script>\n<script src="compat.js"></script>')

# 2. "Too old" message: no Android System WebView on iOS.
sub("too-old", r"'This Android System WebView is too old.*?open PhoneBox again\.'",
    "'This iOS version is too old to run the panel. Update iOS to 14 or later, then open PhoneBox again.'", re.S)

# 3. Container query units are polyfilled (cq-polyfill.js), so the "outdated WebView" notice about them is not shown on iOS.
sub("cq-notice", r"    if \(window\.CSS && typeof CSS\.supports === 'function' && CSS\.supports\('font-size', '1cqw'\)\) return;",
    "    if (/iPhone|iPad|iPod/.test(navigator.userAgent)) return;\n"
    "    if (window.CSS && typeof CSS.supports === 'function' && CSS.supports('font-size', '1cqw')) return;")

open(path, "w", encoding="utf-8").write(s)
PY

# Safari before 16.4 has no regex lookbehind, so main.js (EMOJI_RE) does not even parse on iOS 15. The lookbehind only skips an
# emoji glued to a zero-width joiner; the same test is done on the match instead.
python3 - "$DST/main.js" <<'PYMAIN'
import sys
path = sys.argv[1]
s = open(path, encoding="utf-8").read()
old_re = "new RegExp('(?<!\\\\u200D)(' +"
new_re = "new RegExp('(' +"
old_loop = "  while ((m = EMOJI_RE.exec(s))) {\n"
new_loop = old_loop + "    if (m.index > 0 && s[m.index - 1] === '\\u200D') continue; // was a lookbehind (Safari < 16.4)\n"
if s.count(old_re) != 1 or s.count(old_loop) != 1:
    sys.exit("sync-www: the EMOJI_RE patch no longer matches upstream main.js")
open(path, "w", encoding="utf-8").write(s.replace(old_re, new_re).replace(old_loop, new_loop))
PYMAIN

# The container query units themselves: 12cqw -> calc(12 * var(--cq-w, 1vw)) (the variables come from cq-polyfill.js).
python3 - "$DST" <<'PYCSS'
import glob, os, re, sys
dst = sys.argv[1]
unit = {"w": "1vw", "i": "1vw", "h": "1vh", "b": "1vh", "min": "1vmin", "max": "1vmax"}
rx = re.compile(r"(?<![\w.-])(-?(?:\d+\.?\d*|\.\d+))cq(w|h|i|b|min|max)\b")
total = 0
for path in glob.glob(os.path.join(dst, "*.css")):
    css = open(path, encoding="utf-8").read()
    out, n = rx.subn(lambda m: "calc(%s * var(--cq-%s, %s))" % (m.group(1), m.group(2), unit[m.group(2)]), css)
    total += n
    open(path, "w", encoding="utf-8").write(out)
if total < 50:
    sys.exit("sync-www: only %d container query units found; the CSS changed upstream?" % total)
PYCSS

echo "sync-www: ok -> $DST ($(find "$DST" -type f | wc -l | tr -d ' ') files)"
