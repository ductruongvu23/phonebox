# PhoneBox for iOS (jailbreak, rootless)

Native shell for the PhoneBox panel on iPhone (target: iPhone 6s, iOS 15, Dopamine rootless).
It reuses the Android panel (`android/app/src/main/assets/www`) unchanged: `scripts/sync-www.sh` copies it
into the app bundle and patches it for iOS. Follows upstream release **0.9.22**.

Status: phase 0 (project skeleton, builds to a black-screen app). See the plan for the rest.

## Layout

| Path | What |
|---|---|
| `app/` | The iOS app (Objective-C, Theos application). `Resources/www` is generated, not committed |
| `app/bridge.js` | Shim for `window.Android` (phase 2) |
| `daemon/`, `tweak/` | `phoneboxd` and the SpringBoard tweak (phase 5) |
| `layout/DEBIAN/` | Package control files for the rootless `.deb` |
| `scripts/sync-www.sh` | Copy and patch the panel; safe to re-run |
| `scripts/build-linux.sh` | Build `ios/build/PhoneBox.ipa` with plain clang (Linux or macOS) |
| `Makefile`, `app/Makefile` | Theos build |

## Build

### Quick `.ipa` (no Theos)

```bash
ios/scripts/build-linux.sh
```

- macOS: uses Xcode's iPhoneOS SDK and linker.
- Linux: needs `clang`, `ld64.lld` and an SDK (`SDK=` or `$THEOS/sdks/iPhoneOS15.6.sdk`).
- Signing: `ldid -S` with `app/entitlements.plist` if `ldid` is installed (needed for TrollStore); on macOS it
  falls back to an ad-hoc `codesign`.

Install `ios/build/PhoneBox.ipa` with TrollStore.

### Theos `.deb`

```bash
export THEOS=~/theos   # https://theos.dev/docs/installation
cd ios && make package
```

Produces a rootless package (`/var/jb`) under `ios/packages/`.

## Try the USB path before the real tunnel exists

```bash
iproxy 2222 22
ssh -p 2222 -N -R 8765:127.0.0.1:8765 mobile@127.0.0.1
```

The agent listens on `127.0.0.1:8765` on the PC; this makes it appear on the iPhone's loopback.

## Rules

- Do not edit `android/.../www` from the iOS side; patch it in `sync-www.sh`.
- Shell code stays in `ios/`, agent changes are new files plus a line or two in `Program.cs`.
- No telemetry. Any new outgoing connection goes in `PRIVACY.md`.
