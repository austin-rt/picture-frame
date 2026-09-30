# picture-frame

A self-hosted digital picture frame. A cheap Android photo frame is rooted, stripped of its stock
software, and turned into a kiosk that plays photos and videos synced from cloud storage.

The device is a YENOCK 10.1" ZN-DP1101 (Frameo hardware) — Android 6.0.1, Rockchip rk312x, 1280x800.
It runs Termux for the shell side and a small custom APK for the UI side.

> **Setting one up from scratch? → [GETTING_STARTED.md](GETTING_STARTED.md)**
> Note that the frame must already be rooted; that step is a prerequisite this repo can't do for you.

## How it works

```
Google Drive ──rclone──▶ ~/frame-data/raw/ ──ffmpeg──▶ ~/frame-data/photos/
                                                              │
                                            generate-manifest.sh
                                                              ▼
                        busybox httpd :8080 ◀── ~/frame-data/slideshow/
                                    ▲
                            KioskActivity WebView
```

`sync.sh` runs forever in the background. Each cycle it mirrors the remote into `raw/`, converts
anything new into frame-sized JPEG/H.264 in `photos/`, regenerates `manifest.json`, and serves the
lot over localhost HTTP. The kiosk APK is a full-screen WebView pointed at `http://localhost:8080`,
plus a `@JavascriptInterface` bridge giving the page access to brightness, backlight, reboot, and
persisted settings.

Images are converted before videos on purpose. A 24s 1080p clip costs roughly nine minutes of CPU on
this Rockchip (~22x realtime), so a single interleaved video used to stall every photo behind it.

## Layout

| Path | What it is |
|---|---|
| `kiosk/` | The Android kiosk APK. `build.sh` compiles it with aapt/javac/d8/apksigner — no Gradle. |
| `slideshow/` | The front-end: `index.html`, `app.js`, `style.css`. Deployed by CI only. |
| `sync/` | Everything that runs on-device: `boot.sh`, `sync.sh`, the converters, manifest generator. |
| `setup/` | One-time provisioning (`provision.sh`), plus `triage.sh` and `stress-test.sh`. |
| `tools/` | `heic2jpg` — a small Rust HEIC decoder, since ffmpeg on the device can't read HEIC. |
| `status.sh` | Health check across frames over Tailscale SSH. |

## Access

SSH in as **`root@`**, not as a personal user — Android has no such account, and sshd runs as root
(see Gotchas).

```sh
ssh frame          # over Tailscale
ssh frame-local    # over LAN
```

Those aliases come from `~/.ssh/config` on your laptop; fill in your own frame's addresses:

```
Host frame frame-local
    User root
    IdentityFile ~/.ssh/id_ed25519
Host frame
    HostName <frame-tailscale-ip>
    Port 22                      # tailscale serve forwards 22 -> 8022
Host frame-local
    HostName <frame-lan-ip>
    Port 8022
```

If sshd is ever dead, **ADB over TCP is the escape hatch** and survives reboots
(`persist.adb.tcp.port=5555`):

```sh
adb connect <frame-ip>:5555
```

That is how access was recovered the one time the frame was fully unreachable.

## Deploying

**CI is the only thing that deploys the slideshow.** `.github/workflows/deploy-frame.yml` runs on any
push to `main` touching `slideshow/**` or `sync/**`, plus `workflow_dispatch`. The frame is behind
NAT, so the runner joins the tailnet as an ephemeral `tag:ci` node and copies over Tailscale.

Do not hand-scp the slideshow. Two writers is how the deployed copy silently drifts from the repo.

Files land in `~/.deploy-stage` and are `mv`'d into place rather than scp'd over directly. `scp`
truncates the existing inode, and `sync.sh` is a long-running bash loop — bash reads a script
incrementally as it executes, so overwriting it under a running process can make it read a
half-written file. `mv` swaps the directory entry to a new inode instead.

CI also drops a pristine copy at `~/slideshow-dist`. Every cycle, `sync.sh` restores any of
`app.js` / `index.html` / `style.css` that has gone **missing** — and only if missing. It never
overwrites a file that exists, so a stale copy can't clobber a fresh deploy. Verified by deleting all
three and watching them come back within one cycle.

The APK is not deployed by CI. Build and install it by hand:

```sh
cd kiosk && ./build.sh
adb install -r build/kiosk.apk
```

## Configuration

`~/frame.conf` on the device, sourced by `sync.sh`:

| Variable | Default | Notes |
|---|---|---|
| `RCLONE_REMOTES` | `drive:PhotoFrame` | Space-separated; scoped by `root_folder_id` in rclone.conf |
| `SYNC_INTERVAL` | `1800` | Seconds; backs off to `MAX_BACKOFF` on failure |
| `MAX_PHOTOS` | `500` | FIFO trim; favorited (locked) items are exempt |
| `MAX_VIDEO_DURATION` | `120` | Longer videos are truncated |
| `VIDEO_CRF` | `19` | Lower is better quality |
| `VIDEO_MAXRATE` | `6000k` | The old `2000k` ceiling was the real quality limiter |
| `VIDEO_FPS` | `24` | Kept low deliberately — the decoder stutters if pushed |

UI settings (slide interval, transition, shuffle, sleep timer, schedule) are set in the on-screen
panel and written to disk through the bridge, so they survive a power cut.

## Gotchas

Most of these cost real debugging time. They look like details and are not.

**sshd must run as root, and you log in as `root@`.** Android has no passwd file, so a root-run sshd
can only resolve the user `root`; any other name fails with "Permission denied" no matter what is in
`authorized_keys`. It needs `PermitRootLogin yes`, `StrictModes no`, and an explicit
`AuthorizedKeysFile`. You cannot dodge this by running sshd as the Termux uid instead: `su 10032`
grants the uid but no supplementary groups, so it loses `inet` (3003) and dies with
`socket: Permission denied`.

**Anything the APK persists must go through `su`.** The kiosk runs as its own uid, but everything it
writes lives under Termux's home, which is mode 700 owned by a different uid. Plain `java.io` fails
on every call and the failures were swallowed by `catch (IOException ignored)` — which is why the
favorite heart silently did nothing for weeks. Use the `rootRead`/`rootWrite` helpers.

**Anything launched via `su -c` needs the Termux env exported explicitly.** Above all
`LD_LIBRARY_PATH=$PREFIX/lib`, or Termux's bash won't even link:
`CANNOT LINK EXECUTABLE: library "libandroid-support.so" not found`. Use `setsid` so the process
outlives the short-lived su shell.

**Termux:Boot is unreliable.** It frequently stays in Android's "stopped" state after a cold boot and
never receives `BOOT_COMPLETED`, which once left the frame running the slideshow but unreachable for
a week. The kiosk APK now runs `boot.sh` as root itself; the broadcast is only a fallback.

**The clock starts at 2021-05-14 on every boot.** There's no battery-backed RTC. Neither `ntpd` path
works (not installed, and this busybox has no ntpd applet), so `sync_clock` reads an HTTP `Date:`
header instead. It deliberately does not block boot — sshd matters more than the clock, so retries
move to the background.

**Don't "simplify" `is_playable()` in `process-video.sh`.** It compares the last video packet's
`pts_time` against the declared duration rather than trusting the container. Because the encoder uses
`-movflags +faststart` the moov atom sits at the front, so a truncated file still reports its full
duration *and* ffmpeg exits 0. Checking duration alone passes corrupt files.

**The settings drawer auto-hides in about two seconds.** When driving it with `adb shell input tap`,
issue the taps in a single invocation (`input tap 640 400; sleep 1; input tap 1234 71`). Slipping a
`screencap` between them lets the drawer close and the second tap miss, which reads as "the button is
broken."

**Long encodes are not hangs.** A 25s 1080p HEVC transcode takes several minutes on this CPU.

## Troubleshooting

```sh
ssh frame "tail -40 ~/frame-data/boot.log"    # boot sequence
ssh frame "tail -40 ~/frame-data/sync.log"    # sync + conversion failures, with reasons
ssh frame "curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8080/index.html"
```

Conversion failures log the converter's actual stderr, not just the filename.

Restarting the kiosk reloads the WebView after a slideshow change:

```sh
adb shell am force-stop com.frame.kiosk
adb shell am start -n com.frame.kiosk/.KioskActivity
```

## Recovery

If the frame is unreachable, in order: `ssh frame` → `ssh frame-local` → `adb connect <ip>:5555`.
Once in, `bash ~/.termux/boot/boot.sh` restarts every service.

If the slideshow 404s, `sync.sh` restores it from `~/slideshow-dist` within one cycle. If that
directory is also gone, re-run the deploy workflow.
