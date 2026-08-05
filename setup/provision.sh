#!/usr/bin/env bash
# Automated provisioning for a Frameo-style Android frame (developed on a YENOCK
# 10.1" ZN-DP1101). Run from your laptop with the frame connected via USB.
#
# This is the automation half of GETTING_STARTED.md — read that first for the
# parts a script cannot do, above all rooting the device.
#
# Prereqs:
#   - The frame is ALREADY ROOTED (checked below; everything depends on it)
#   - Run triage.sh first to confirm specs
#   - Connect Wi-Fi via Android system settings BEFORE running this
#   - Download APKs into ../apks/ (termux.apk, termux-boot.apk)
#   - Generate rclone.conf on your laptop (rclone config) and place in ../sync/rclone.conf
#
# This script automates everything possible via ADB. Steps requiring
# touchscreen interaction are clearly marked [MANUAL].

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
APKS_DIR="$PROJECT_DIR/apks"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

step()   { printf "\n${GREEN}[STEP %s]${NC} %s\n" "$1" "$2"; }
manual() { printf "\n${CYAN}[MANUAL]${NC} %s\n" "$1"; }
warn()   { printf "${YELLOW}  WARN:${NC} %s\n" "$1"; }
fail()   { printf "${RED}  FAIL:${NC} %s\n" "$1"; exit 1; }
ok()     { printf "${GREEN}  OK${NC}\n"; }
wait_enter() { printf "\n  Press Enter when done..."; read -r; }

# --- Preflight ---
echo "=== YENOCK Picture Frame Provisioning ==="
echo ""

if ! adb devices 2>/dev/null | grep -q "device$"; then
    fail "No ADB device found. Enable ADB: Settings > About > Beta Program > toggle ADB On-Off-On"
fi

ANDROID_VER=$(adb shell getprop ro.build.version.release 2>/dev/null | tr -d '\r')
echo "  Device: Android $ANDROID_VER"

# Root is load-bearing: sshd runs as root, the kiosk bridge persists settings via
# su, and boot.sh is launched as root. Fail here rather than half-provisioning.
if ! adb shell "su -c id" 2>/dev/null | grep -q "uid=0"; then
    fail "Device is not rooted (su -c id did not return uid=0). See GETTING_STARTED.md."
fi
echo "  Root: yes"

if ! adb shell dumpsys wifi 2>/dev/null | grep "mNetworkInfo" | head -1 | grep -q "CONNECTED"; then
    fail "Wi-Fi not connected. Connect via Android Settings > Wi-Fi FIRST (not through Frameo app)."
fi
echo "  Wi-Fi: connected"
echo ""

# --- Step 1: Disable Frameo ---
step "1/7" "Disabling Frameo app"
FRAMEO_PKGS=$(adb shell pm list packages 2>/dev/null | grep -i frameo | tr -d '\r' | sed 's/package://')
if [[ -n "$FRAMEO_PKGS" ]]; then
    for pkg in $FRAMEO_PKGS; do
        printf "  Disabling %s ... " "$pkg"
        adb shell pm disable-user --user 0 "$pkg" 2>/dev/null && ok || warn "Failed — try: adb shell pm disable-user --user 0 $pkg"
    done
else
    warn "No Frameo packages found — may already be disabled"
fi

# --- Step 2: Install APKs ---
step "2/7" "Sideloading APKs"
missing_apks=false
for apk in termux.apk termux-boot.apk; do
    if [[ -f "$APKS_DIR/$apk" ]]; then
        printf "  Installing %s ... " "$apk"
        result=$(adb install -r "$APKS_DIR/$apk" 2>&1)
        if echo "$result" | grep -q "Success"; then
            ok
        else
            warn "Failed: $result"
        fi
    else
        warn "$apk not found in apks/ — download it first"
        missing_apks=true
    fi
done
if $missing_apks; then
    echo ""
    echo "  Download APKs from:"
    echo "    Termux + Termux:Boot: https://f-droid.org/en/packages/com.termux/"
    echo "    Take both from the SAME source — mismatched builds refuse to talk,"
    echo "    and current Play Store builds do not support Android 6."
fi

# --- Step 3: Push files ---
step "3/7" "Pushing project files to device"
adb shell mkdir -p /sdcard/frame-setup/sync 2>/dev/null
adb shell mkdir -p /sdcard/frame-setup/slideshow 2>/dev/null

printf "  Pushing sync scripts ... "
adb push "$PROJECT_DIR/sync/" /sdcard/frame-setup/sync/ 2>/dev/null && ok || warn "Push failed"

# The slideshow seeds frame-data/slideshow AND slideshow-dist, the copy sync.sh
# restores from if a file ever goes missing. After this initial seed, the deploy
# workflow owns these files — do not hand-copy them again.
printf "  Pushing slideshow ... "
adb push "$PROJECT_DIR/slideshow/" /sdcard/frame-setup/slideshow/ 2>/dev/null && ok || warn "Push failed"

if [[ -f "$PROJECT_DIR/sync/rclone.conf" ]]; then
    printf "  Pushing rclone.conf ... "
    adb push "$PROJECT_DIR/sync/rclone.conf" /sdcard/frame-setup/rclone.conf 2>/dev/null && ok
else
    warn "No rclone.conf found — run 'rclone config' on your laptop first"
fi

# --- Step 4: Battery optimization whitelist ---
step "4/7" "Whitelisting apps from battery optimization"
for pkg in com.termux com.termux.boot com.frame.kiosk; do
    printf "  Whitelisting %s ... " "$pkg"
    adb shell dumpsys deviceidle whitelist +"$pkg" 2>/dev/null && ok || warn "Failed"
done

# --- Step 5: Keep screen on + stay awake settings ---
step "5/7" "Configuring display settings"
# Keep Wi-Fi on during sleep
adb shell settings put global wifi_sleep_policy 2 2>/dev/null && printf "  Wi-Fi sleep policy: never\n"
# Disable screen timeout (the kiosk APK also holds a wake lock)
adb shell settings put system screen_off_timeout 2147483647 2>/dev/null && printf "  Screen timeout: disabled\n"

# --- Step 6: Termux setup (requires touching the frame) ---
step "6/7" "Termux initial setup"
manual "Open Termux on the frame and run these commands:"
echo ""
echo "    termux-setup-storage"
echo ""
echo "    pkg update -y && pkg install -y rclone ffmpeg openssh busybox coreutils"
echo ""
echo "    mkdir -p ~/frame-data/slideshow ~/slideshow-dist ~/.config/rclone ~/.termux/boot ~/.ssh"
echo "    cp -r /sdcard/frame-setup/sync ~/sync"
echo "    chmod +x ~/sync/*.sh"
echo "    cp /sdcard/frame-setup/rclone.conf ~/.config/rclone/rclone.conf"
echo "    ln -sf ~/sync/boot.sh ~/.termux/boot/boot.sh"
echo ""
echo "    # seed both the served copy and the restore-from copy"
echo "    cp /sdcard/frame-setup/slideshow/* ~/frame-data/slideshow/"
echo "    cp /sdcard/frame-setup/slideshow/* ~/slideshow-dist/"
echo ""
echo "    # You will log in as root@, not as a username — Android has no passwd"
echo "    # file, so a root-run sshd can only resolve 'root'."
echo "    echo 'YOUR_PUBLIC_KEY_HERE' >> ~/.ssh/authorized_keys"
echo "    chmod 600 ~/.ssh/authorized_keys"
echo ""
echo "    # HEIC needs the decoder from tools/heic2jpg-rs cross-compiled for this"
echo "    # ABI and dropped at \$PREFIX/bin/heic2jpg, or every .HEIC fails."
echo ""
wait_enter

# --- Step 7: Kiosk APK ---
step "7/7" "Building and installing the kiosk APK"
if [[ -x "$PROJECT_DIR/kiosk/build.sh" ]]; then
    printf "  Building ... "
    if (cd "$PROJECT_DIR/kiosk" && ./build.sh >/dev/null 2>&1); then
        ok
        printf "  Installing ... "
        adb install -r "$PROJECT_DIR/kiosk/build/kiosk.apk" 2>&1 | grep -q Success && ok \
            || warn "Install failed — run 'cd kiosk && ./build.sh' to see the error"
    else
        warn "Build failed — needs a JDK and Android SDK platform-34 + build-tools 34.0.0"
    fi
else
    warn "kiosk/build.sh not found"
fi

printf "  Launching kiosk ... "
adb shell am start -n com.frame.kiosk/.KioskActivity >/dev/null 2>&1 && ok || warn "Couldn't launch"

manual "Set the kiosk as the home app so it survives reboots:"
echo "    Press Home on the frame > select 'Frame Kiosk' > 'Always'"
wait_enter

# --- Final verification ---
echo ""
echo "=== Provisioning complete ==="
echo ""
echo "  Verify:"
echo "    adb shell \"curl -s -o /dev/null -w '%{http_code}\\n' http://127.0.0.1:8080/index.html\"   # 200"
echo "    adb shell \"tail -20 /data/data/com.termux/files/home/frame-data/boot.log\""
echo "    ssh root@<frame-ip> -p 8022 'echo ok'"
echo ""
echo "  Then POWER-CYCLE the frame. That is the test that matters — everything"
echo "  should come back with no intervention."
echo ""
echo "  Optional next steps (see GETTING_STARTED.md):"
echo "    - Tailscale for remote access (tailscaled binary in Termux, not the app)"
echo "    - CI deploys via .github/workflows/deploy-frame.yml"
