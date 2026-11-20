# PhoneBox for iOS (jailbreak, rootless)

Native shell for the PhoneBox panel on iPhone (target: iPhone 6s, iOS 15, Dopamine rootless).
It reuses the Android panel (`android/app/src/main/assets/www`) unchanged: `scripts/sync-www.sh` copies it
into the app bundle and patches it for iOS. Follows upstream release **0.9.22**.

This is the iOS app. The agent side (`IosUsb.cs`, `UsbMux.cs`) is in `agent/PhoneBox.Agent/`.

Status: the app, the USB tunnel (iPhone and agent sides), the jailbreak extras and the build/CI scripts are written.
What was run for real is listed under "What is verified" below.

## Layout

| Path | What |
|---|---|
| `app/` | The iOS app (Objective-C, Theos application). `Resources/www` is generated, not committed |
| `app/bridge.js` | The `window.Android` shim the panel expects |
| `../agent/PhoneBox.Agent/IosUsb.cs`, `UsbMux.cs` | PC side of the USB tunnel (usbmuxd client) |
| `daemon/` | `phoneboxd`: keeps the USB tunnel up with the app closed; wake/sleep/open commands from the PC |
| `tweak/` | `PhoneBoxSB`: SpringBoard tweak (volume keys, Home button, wake/lock/launch) |
| `layout/DEBIAN/` | Package control files for the rootless `.deb` |
| `scripts/sync-www.sh` | Copy and patch the panel; safe to re-run |
| `scripts/build-linux.sh` | Build `ios/build/PhoneBox.ipa` with plain clang (Linux or macOS) |
| `scripts/build-deb.sh` | Build the rootless `.deb` (app + daemon + tweak) without Theos |
| `scripts/make-apt-repo.py` | Turn `.deb` files into a Sileo/Zebra repo |
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

## How the USB tunnel works

iOS has no `adb reverse`, and usbmuxd only lets the PC connect *into* the phone. So the agent (`IosUsb.cs`) keeps four
idle usbmuxd connections open to port 8767 on the phone. When the app connects to `127.0.0.1:8765` on the phone,
`PBUsbListener` splices that connection onto an idle one, and the agent pipes its first byte on to its own port.
HTTP and SSE run through unchanged, so `PBAgentLink` needs no special case.

- Both ports are bound to loopback only. 8765 is open only while the PC has an idle connection ready, so with no cable it
  is refused instantly and the app falls back to Wi-Fi. A POST is never retried on another route after it may have been sent.
- The app hosts the listener while it is open. With the jailbreak package, `phoneboxd` hosts it all the time (the app's
  listener then finds the ports taken and does nothing).
- Needs usbmuxd on the PC: built into macOS, "Apple Devices"/iTunes on Windows, the `usbmuxd` package on Linux.
- Quick manual check without the agent: `iproxy 2222 22` then
  `ssh -p 2222 -N -R 8765:127.0.0.1:8765 mobile@127.0.0.1` (needs SSH on the phone).

## Jailbreak package (rootless, Dopamine)

`ios/scripts/build-deb.sh` (or `make package` with Theos) builds `com.ductruongvu23.phonebox-jb`:
the app in `/var/jb/Applications`, `phoneboxd` (LaunchDaemon), and `PhoneBoxSB.dylib` for SpringBoard.
After installing, respring. Plugging the phone in wakes it and opens the panel; with "volume keys flip pages" on in the
panel settings the volume buttons turn pages; kiosk mode makes Home return to the first page.
`wake` turns the screen on and dismisses the lock screen only on a phone WITHOUT a passcode; with a passcode the phone
stays on the lock screen until you unlock it (PhoneBox never handles the passcode). For a desk panel, turn the passcode
off or keep the phone unlocked while it is plugged in.
The tweak uses private SpringBoard methods and logs which hooks it found ("PhoneBoxSB:" in the device log); a hook that
does not exist on your iOS is skipped and the rest keeps working.

## Android parity

| Android feature | iOS |
|---|---|
| Panel, 66 widget types, stream, USB, Wi-Fi + QR pairing, certificate pinning | yes |
| Native dialogs in en / vi / el | yes (`scripts/gen-strings.py` turns the Android string files into `Localizable.strings`) |
| Brightness, orientation, haptic/buzz, battery, 24-hour setting, dictation, trackpad | yes. Trackpad uses a WebSocket on Wi-Fi like Android, HTTP on USB |
| Proximity wake of the night screen | yes, while the panel is dimmed (iOS blanks the display when the sensor is covered, so it is off in the daytime) |
| Ambient light | with the jailbreak package (IOKit HID light sensor). Checked on an iPhone 6s: `phoneboxd status` showed `lux=` 126 to 154 in a lit room, tracking changes (the level is in event field 1; the package reads the first three fields and takes the largest). The panel's auto-brightness from this value was not exercised |
| Volume keys flip pages, Home = back (kiosk), reopen when closed, wake/sleep with the PC lock | with the jailbreak package |
| Quick Settings tile | no iOS equivalent (Control Center cannot host third-party tiles without a widget extension) |
| Screen pinning (`setPinned` without a jailbreak) | no: Guided Access is the iOS equivalent and only the user can start it |
| Use as home screen (`setHomeScreen`) | no without a jailbreak: iOS has no home-app role; with the package, Home reopens PhoneBox |
| Automatic update of the phone app | no: the agent updates an APK; iOS builds are updated through TrollStore / Sileo |

## What is verified

Run in the iOS Simulator (iOS 26.5, against a stand-in agent and a stand-in PC that plays `IosUsb.cs`):
the panel renders, requests carry the identity headers, POST bodies arrive, a request without the panel header gets 403,
widget iframes see neither `window.Android` nor the agent, the SSE stream delivers, and the USB tunnel carries
requests and the stream; port 8765 closes when the PC goes away. `phoneboxd` was built and run on macOS: its commands
become Darwin notifications.

Not yet run: the C# (`IosUsb.cs`, `UsbMux.cs`, `UsbMuxTests.cs`; no .NET SDK was available), the Theos Makefiles,
the SpringBoard hooks, dictation, anything on iOS 15 itself, and the Linux build path.

## Rules

- Do not edit `android/.../www` from the iOS side; patch it in `sync-www.sh`.
- Shell code stays in `ios/`, agent changes are new files plus a line or two in `Program.cs`.
- No telemetry. Any new outgoing connection goes in `PRIVACY.md`.
