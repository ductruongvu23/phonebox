# Installing PhoneBox on iPhone (and the computer side)

Everything is on the release page: <https://github.com/ductruongvu23/phonebox/releases/latest>
(pick the newest one named `ios-v…`).

PhoneBox for iOS has **three pieces**. You need the first two; the third is optional.

| Piece | What it is | Where it runs | Needed? |
|---|---|---|---|
| **Agent** | The desktop program that reads your computer's stats and takes the commands. | Windows, macOS or Linux | yes |
| **iPhone app** (`PhoneBox.ipa`) | The panel. | iPhone / iPad, iOS 15 or later | yes |
| **PhoneBox Extras** (`.deb`) | Plug-in the cable and the iPhone wakes and opens the panel; volume keys turn pages; light sensor; tunnel stays up with the app closed. | Jailbroken iPhone, rootless (Dopamine and similar) | optional |

Tested with an iPhone 6s on iOS 15.8.4 (Dopamine + TrollStore) and a Mac. **What is not tested** is marked "untested" below.

---

## 1. Install the agent on your computer

Download the zip for your system from the release page. The name is `PhoneBoxAgent-ios-<version>-<system>.zip`.

| Your computer | Download |
|---|---|
| Windows (64-bit) | `…-win-x64.zip` |
| Mac with an Intel chip | `…-osx-x64.zip` |
| Mac with Apple silicon (M1 or newer) | `…-osx-arm64.zip` |
| Linux, Intel/AMD | `…-linux-x64.zip` |
| Linux, ARM (Raspberry Pi 4/5, …) | `…-linux-arm64.zip` |

These builds are **not signed** (the upstream release is signed; this fork has no signing keys). Expect a warning on first start.

### macOS (tested)

```bash
mkdir -p ~/PhoneBox && cd ~/PhoneBox
gh release download ios-v0.9.22-1 --repo ductruongvu23/phonebox --pattern 'PhoneBoxAgent-ios-0.9.22-osx-x64.zip'
#   no `gh`? download the zip in a browser and move it to ~/PhoneBox
unzip -o PhoneBoxAgent-ios-0.9.22-osx-x64.zip
xattr -dr com.apple.quarantine ~/PhoneBox     # lets macOS open an unsigned program
chmod +x ~/PhoneBox/PhoneBoxAgent
~/PhoneBox/PhoneBoxAgent
```

- The settings page opens at <http://127.0.0.1:8765>.
- USB needs nothing extra: macOS already has the program that talks to iPhones.
- Closing the Terminal window stops the agent. There is no start-at-login yet.
- macOS asks for the **Accessibility** permission for keyboard and mouse widgets, and asks again after every update (unsigned build).
- For the Media widget to see videos in a browser (YouTube), install `nowplaying-cli`
  (`brew install nowplaying-cli`; without Homebrew, build it from <https://github.com/kirtan-shah/nowplaying-cli> with `make install PREFIX=$HOME/.local`).

### Windows (untested)

1. Unzip `PhoneBoxAgent-ios-…-win-x64.zip` to a folder, for example `C:\PhoneBox`.
2. Run `PhoneBoxAgent.exe`. Windows SmartScreen warns about an unknown publisher: **More info → Run anyway**.
3. A tray icon appears; double-click it for the settings (<http://127.0.0.1:8765>).
4. For a **USB cable** install **Apple Devices** (Microsoft Store) or iTunes: they provide the USB driver (Apple Mobile Device Service). Wi-Fi needs nothing.

### Linux (untested)

```bash
unzip PhoneBoxAgent-ios-0.9.22-linux-x64.zip -d ~/PhoneBox
chmod +x ~/PhoneBox/PhoneBoxAgent
sudo apt install usbmuxd          # only for a USB cable (Debian/Ubuntu; other systems: the usbmuxd package)
~/PhoneBox/PhoneBoxAgent
```

Settings: <http://127.0.0.1:8765>. For the Media widget install `playerctl`.

---

## 2. Install the iPhone app

You need a way to install an app that is not in the App Store. Pick **one**.

### A. TrollStore (tested)

TrollStore installs apps permanently, with no weekly re-signing. It only works on some iOS versions; see <https://ios.cfw.guide/installing-trollstore/>.

1. Open **TrollStore** on the iPhone, tap **+**, choose **Install from URL**.
2. Enter the link to the `.ipa`, for example
   `https://github.com/ductruongvu23/phonebox/releases/download/ios-v0.9.22-1/PhoneBox.ipa`
   (or download the file in Safari and choose **Share → TrollStore**).
3. Tap **Install**, confirm. The icon appears on the home screen.
   If the icon is missing or will not open: TrollStore → **Settings** → **Refresh App Registrations** (or **Rebuild Icon Cache**).

### B. AltStore / Sideloadly (untested)

Sign `PhoneBox.ipa` with your own Apple ID. This works without a jailbreak but the app **expires after 7 days** (free Apple ID) and has to be signed again. The app has not been tried this way.

### C. Jailbreak with Sileo (tested)

On a jailbroken iPhone you can also install the `.ipa` through TrollStore (A). The jailbreak itself is only needed for PhoneBox Extras (below).

---

## 3. PhoneBox Extras, jailbreak only (optional)

Needs a **rootless** jailbreak (Dopamine, palera1n rootless …) with **ElleKit**. It installs `phoneboxd` (a background service) and a SpringBoard tweak.

**With Sileo or Zebra (tested with Sileo):**

1. **Sources → +**, add `https://ductruongvu23.github.io/repo/`
2. Search **PhoneBox Extras**, tap **Get**, then **Queue → Confirm**.
3. Tap **Restart SpringBoard** (respring). The phone asks for the passcode afterwards.

**By hand:** download `com.ductruongvu23.phonebox-jb_…_iphoneos-arm64.deb` from the release page and install it with Filza or `dpkg -i`.

It does **not** contain the app. Install the app with section 2. (Building the package with `WITH_APP=1` includes it.)

What it adds: plug the cable in and the phone wakes and opens PhoneBox; the volume keys turn pages; the light sensor works (auto brightness); the USB link stays up when the app is closed.

**Passcode:** when the screen is locked with a passcode, the tweak can wake the screen but cannot type your passcode. After a respring or a reboot, unlock the phone once yourself.
Settings → Display & Brightness → Auto-Lock → **Never** keeps it from locking again while it stands on the desk.
After a reboot a semi-untethered jailbreak (Dopamine) is gone until you run the jailbreak app again; the app then still works over Wi-Fi.

---

## 4. Connect the iPhone to the computer

### USB (cable)

1. Start the agent (section 1), plug the iPhone in with a **data cable**, unlock it, and tap **Trust** if it asks.
2. Open PhoneBox on the iPhone (with PhoneBox Extras it opens by itself).
3. The panel shows your computer's name and **USB**. Check on the computer: <http://127.0.0.1:8765/api/ios> lists the iPhone and its tunnels.

Without PhoneBox Extras the USB link only works **while the app is open on screen** (the app itself listens for the cable then).
This app-only USB path was tested in the iOS Simulator but **not on a real iPhone** without the jailbreak package; Wi-Fi was.

### Wi-Fi (no cable)

The iPhone and the computer must be on the same network, or both on Tailscale; the computer's firewall must allow PhoneBox. Pair **once**:

1. On the computer open <http://127.0.0.1:8765> → **General → Wi-Fi & Tailscale** → turn on **Let the phone connect without the USB cable** → **Save** → **Restart to apply** (top of the page).
2. Click **Pair a phone over Wi-Fi**. A box shows a QR code and a check code such as `A9B7 C145`.
3. On the iPhone, scan the QR code with the Camera and open the link, then tap **Open in PhoneBox**.
   If that does not work, click **Copy the pairing link** in the box, send the `phonebox://pair?…` link to the iPhone (Notes, a message) and tap it. (Scanning with the Camera is untested; the link route was tested.)
4. The iPhone shows the computer's name and the same check code. If the codes match, tap **Pair** (the code works once, for 5 minutes).
5. The panel shows the computer's name and **Wi-Fi**. From now on it reconnects by itself. With the cable plugged in, USB wins.

---

## 5. With and without a jailbreak

| | App only (no jailbreak) | App + PhoneBox Extras (jailbreak) |
|---|---|---|
| Panel, all widgets, Wi-Fi pairing, trackpad, brightness, rotation, dictation | yes | yes |
| Plug in the cable and the iPhone wakes and opens PhoneBox | no | yes |
| Volume keys turn pages | no | yes |
| Light sensor and auto brightness | no | yes |
| USB link with the app closed | no | yes |
| Home button returns to the first page (kiosk), reopen when closed | no | yes (hooks written, not verified on the phone) |
| Screen follows the computer's lock | no | yes, only on a phone without a passcode |
| Updates | install again (TrollStore) | install again; the Extras update through Sileo |

Not available on iOS at all: the Android Quick Settings tile, screen pinning and "use as home screen" without a jailbreak, and the agent's automatic phone-app update (it updates an APK).

---

## 6. If something does not work

| Symptom | What to try |
|---|---|
| The panel says the computer is not connected | The agent is not running, or the iPhone is not paired and no cable is plugged in. Check <http://127.0.0.1:8765/api/phones>. If it just plugged in, give it a few seconds; close and open the app. |
| `/api/ios` shows no iPhone | Use a data cable, unlock the iPhone, tap **Trust**. Try another USB port. On Windows install Apple Devices; on Linux install `usbmuxd`. The settings page says which. |
| USB used to work and now hangs | The computer's USB service is stuck: plug into **another port**, or restart the computer. |
| The app does not open from the home screen | TrollStore → Settings → Refresh App Registrations; open it from TrollStore's list. |
| The app opens and shows "Script error" | Update the app; this was an old bug on iOS 15 and is fixed in the releases. |
| The Media widget is empty on a Mac | Install `nowplaying-cli` (section 1, macOS). |
| After a respring the phone asks for the passcode | Expected. Unlock it once; set Auto-Lock to Never for a desk panel. |
| Wi-Fi pairing says the code was refused | The code works once and for 5 minutes; start pairing again on the computer. |
| Settings page says an iPhone has no USB link | It prints the reason (missing driver, no data cable, app not open). |

---

## 7. Building it yourself

See [README.md](README.md): `ios/scripts/build-linux.sh` (the `.ipa`), `ios/scripts/build-deb.sh` (the `.deb`), `ios/scripts/make-apt-repo.py` (a Sileo repo). The agent is `dotnet publish agent/PhoneBox.Agent -f net10.0 -r <rid> --self-contained true -p:PublishSingleFile=true`.
