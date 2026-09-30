# Getting started on your own frame

Clone the repo, plug in the device, then work down this page. Expect an afternoon.

Everything here was done on a YENOCK 10.1" ZN-DP1101 (Frameo hardware) — Android 6.0.1,
Rockchip rk312x, `armeabi-v7a`, 1280x800. Other frames will work, but see
[Things that are device-specific](#things-that-are-device-specific) before you start.

---

## 0. The prerequisite that isn't optional: root

**Your frame must be rooted before any of this works.** Not "works better" — works at all.

- `sshd` has to run as root, or you cannot log in at all (Android has no passwd file)
- the kiosk APK persists every setting through `su`, because it can't write Termux's home
- `boot.sh` is launched as root by the kiosk app, which is what makes boot reliable
- brightness and screen on/off write to `/sys/class/backlight/...`, which is root-only

This repo does **not** root your device and can't tell you how to root yours. This frame runs
SuperSU 2.45 with `su` at `/system/xbin/su`, which came with the hardware rather than from a
documented procedure here. Rooting is model- and firmware-specific, and a wrong method bricks the
device — research your exact model and firmware build.

Check what you have:

```sh
adb shell "su -c id"     # want: uid=0(root)
```

If that doesn't return uid 0, stop. Nothing below will work.

## 1. On your laptop

```sh
brew install --cask android-platform-tools   # adb
brew install rclone
```

For building the APK you also need a JDK and the Android SDK with **platform-34** and
**build-tools 34.0.0** (`build.sh` uses `aapt`, `javac`, `d8`, `zipalign`, `apksigner` directly —
no Gradle, no Android Studio required). Set `ANDROID_HOME` if it isn't `~/Library/Android/sdk`.

Create your rclone remote and drop the config where the provisioning step expects it:

```sh
rclone config                    # set up your cloud remote
cp ~/.config/rclone/rclone.conf sync/rclone.conf     # gitignored
```

## 2. On the frame, before ADB

- Enable ADB: **Settings → About → Beta Program → toggle ADB Off then On**
- Connect Wi-Fi through **Android's** settings, not the Frameo app

Then confirm the device looks like what this repo expects:

```sh
adb devices
bash setup/triage.sh
```

## 3. Sideload Termux

Use the APKs in `apks/` rather than the Play Store versions — Termux and Termux:Boot must come
from the same source or they refuse to talk to each other, and current Play builds don't support
Android 6.

```sh
adb install -r apks/termux.apk
adb install -r apks/termux-boot.apk
adb shell pm disable-user --user 0 net.frameo.frame     # stop the stock software fighting you
```

Open Termux once by hand so it finishes first-run setup.

## 4. Set up the device side

Push the scripts, then run the rest in Termux on the frame:

```sh
adb push sync /sdcard/frame-setup/sync
adb push sync/rclone.conf /sdcard/frame-setup/rclone.conf
```

In Termux on the frame:

```sh
pkg update -y && pkg install -y rclone ffmpeg openssh busybox coreutils

mkdir -p ~/frame-data ~/.config/rclone ~/.termux/boot ~/.ssh ~/slideshow-dist
cp -r /sdcard/frame-setup/sync ~/sync
cp /sdcard/frame-setup/rclone.conf ~/.config/rclone/rclone.conf
chmod +x ~/sync/*.sh
ln -sf ~/sync/boot.sh ~/.termux/boot/boot.sh

# your laptop's public key — you will log in as root@, see step 7
echo 'ssh-ed25519 AAAA...' >> ~/.ssh/authorized_keys
chmod 600 ~/.ssh/authorized_keys
```

HEIC support needs the small Rust decoder in `tools/heic2jpg-rs`, because ffmpeg on this device
can't read HEIC. Cross-compile it for `armeabi-v7a` and drop the binary at
`$PREFIX/bin/heic2jpg`. Without it, every `.HEIC` fails conversion — which on an iPhone library is
most of your photos.

## 5. Configure

Create `~/frame.conf` on the device:

```sh
RCLONE_REMOTES="drive:"        # your remote, optionally scoped by root_folder_id
FRAME_NAME="livingroom"
SYNC_INTERVAL=300
```

Everything else has a working default — see the Configuration table in the README. `frames/`
holds the same settings for keeping on your laptop: `base.conf` is shared, `example.conf` is a
per-frame template, and `frames/*.local.conf` is gitignored for your real ones.

## 6. Build and install the kiosk APK

`build.sh` signs with a local debug keystore it creates on first run (gitignored). Set
`KIOSK_KEYSTORE_PASS` if you want a password other than the default.

```sh
cd kiosk && ./build.sh
adb install -r build/kiosk.apk
```

This APK is the whole UI: a fullscreen WebView plus the `su`-backed bridge for brightness,
backlight, favorites and settings. It also launches `boot.sh` as root on start, which is what makes
the frame come up reliably without Termux:Boot firing.

## 7. First run

```sh
adb shell am start -n com.frame.kiosk/.KioskActivity
```

Give it a few minutes — the first sync downloads and transcodes everything, and video is slow
(a 24s 1080p clip takes ~9 minutes of CPU on this hardware; that is not a hang).

Verify:

```sh
adb shell "curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8080/index.html"   # 200
adb shell "tail -20 /data/data/com.termux/files/home/frame-data/boot.log"
ssh root@<frame-ip> -p 8022 "echo ok"     # root@, not your own username
```

Then **power-cycle it**. That is the only test that matters — it's the case that used to leave this
frame running the slideshow while completely unreachable.

## 8. Optional: remote access and CI

**Tailscale** runs as the `tailscaled` binary inside Termux with `--tun=userspace-networking`, not
as the Android app. `boot.sh` starts it and publishes SSH with `tailscale serve --tcp 22`. Drop the
binaries in `$PREFIX/bin` and run `tailscale up` once to authenticate.

**Automatic deploys** — `.github/workflows/deploy-frame.yml` pushes `slideshow/` and `sync/` changes
to the frame on every push to `main`. To enable it on your fork:

1. Generate a dedicated deploy key (not your personal one) and append the public half to the
   frame's `~/.ssh/authorized_keys`
2. In the Tailscale admin console, create the tag `tag:ci` owned by `autogroup:admin`, then an
   OAuth client scoped to *Auth Keys read+write*, restricted to `tag:ci`
3. Set repo secrets: `FRAME_SSH_KEY`, `FRAME_HOST`, `TS_OAUTH_CLIENT_ID`, `TS_OAUTH_SECRET`

Once that's live, **stop hand-copying the slideshow** — two writers is how the deployed copy
silently drifts from the repo.

---

## Things that are device-specific

Check these before assuming a different frame will work:

| Thing | Here | Where |
|---|---|---|
| Backlight sysfs path | `/sys/class/backlight/rk28_bl/brightness` | `BL_PATH` in `KioskActivity.java` |
| Resolution | 1280x800 | `FRAME_WIDTH` / `FRAME_HEIGHT` in `frame.conf` |
| ABI | `armeabi-v7a` | affects the `heic2jpg` build |
| Stock app package | `net.frameo.frame` | the app you disable in step 3 |

The backlight path is the one most likely to differ. Find yours with
`ls /sys/class/backlight/`.

## setup/provision.sh

`setup/provision.sh` automates the ADB-side of steps 2–6 above, then builds and installs the APK.
It refuses to run on an unrooted device. Use it if you're setting up a second frame:

```sh
bash setup/provision.sh
```

It cannot do step 0 (rooting), and the Termux commands in step 6 still need typing on the device
itself, since Termux won't accept them over ADB.
