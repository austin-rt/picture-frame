#!/usr/bin/env bash
# SUPERSEDED — see GETTING_STARTED.md in the repo root. Kept for reference.
# This predates the current architecture: step 7 installs the Tailscale Android
# app (we now run the tailscaled binary in Termux) and step 8 configures Fully
# Kiosk Browser (replaced by the custom APK in kiosk/). It also assumes an
# unrooted device throughout, which no longer holds.
#
# Automated provisioning for YENOCK 10.1" ZN-DP1101 Frameo frame.
# Run from your laptop with the frame connected via USB.
#
# Prereqs:
#   - Run triage.sh first to confirm specs
#   - Connect Wi-Fi via Android system settings BEFORE running this
#   - Download APKs into ../apks/ (termux.apk, termux-boot.apk, tailscale.apk, fullykiosk.apk)
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

if ! adb shell dumpsys wifi 2>/dev/null | grep "mNetworkInfo" | head -1 | grep -q "CONNECTED"; then
    fail "Wi-Fi not connected. Connect via Android Settings > Wi-Fi FIRST (not through Frameo app)."
fi
echo "  Wi-Fi: connected"
echo ""

# --- Step 1: Disable Frameo ---
step "1/8" "Disabling Frameo app"
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
step "2/8" "Sideloading APKs"
missing_apks=false
for apk in termux.apk termux-boot.apk tailscale.apk fullykiosk.apk; do
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
    echo "    Tailscale: https://play.google.com/store/apps/details?id=com.tailscale.ipn"
    echo "    Fully Kiosk: https://www.fully-kiosk.com/en/#download"
fi

# --- Step 3: Push files ---
step "3/8" "Pushing project files to device"
adb shell mkdir -p /sdcard/frame-setup/sync 2>/dev/null
adb shell mkdir -p /sdcard/frame-setup/slideshow 2>/dev/null

printf "  Pushing sync scripts ... "
adb push "$PROJECT_DIR/sync/" /sdcard/frame-setup/sync/ 2>/dev/null && ok || warn "Push failed"

printf "  Pushing slideshow ... "
adb push "$PROJECT_DIR/slideshow/" /sdcard/frame-setup/slideshow/ 2>/dev/null && ok || warn "Push failed"

if [[ -f "$PROJECT_DIR/sync/rclone.conf" ]]; then
    printf "  Pushing rclone.conf ... "
    adb push "$PROJECT_DIR/sync/rclone.conf" /sdcard/frame-setup/rclone.conf 2>/dev/null && ok
else
    warn "No rclone.conf found — run 'rclone config' on your laptop first"
fi

# --- Step 4: Battery optimization whitelist ---
step "4/8" "Whitelisting apps from battery optimization"
for pkg in com.termux com.termux.boot com.tailscale.ipn; do
    printf "  Whitelisting %s ... " "$pkg"
    adb shell dumpsys deviceidle whitelist +"$pkg" 2>/dev/null && ok || warn "Failed"
done

# --- Step 5: Keep screen on + stay awake settings ---
step "5/8" "Configuring display settings"
# Keep Wi-Fi on during sleep
adb shell settings put global wifi_sleep_policy 2 2>/dev/null && printf "  Wi-Fi sleep policy: never\n"
# Disable screen timeout (Fully Kiosk handles this, but belt+suspenders)
adb shell settings put system screen_off_timeout 2147483647 2>/dev/null && printf "  Screen timeout: disabled\n"

# --- Step 6: Termux setup (requires touching the frame) ---
step "6/8" "Termux initial setup"
manual "Open Termux on the frame and run these commands:"
echo ""
echo "    termux-setup-storage"
echo ""
echo "    pkg update -y && pkg install -y rclone ffmpeg openssh busybox"
echo ""
echo "    cp -r /sdcard/frame-setup/sync ~/sync"
echo "    cp -r /sdcard/frame-setup/slideshow ~/slideshow"
echo "    mkdir -p ~/frame-data ~/.config/rclone ~/.termux/boot ~/.ssh"
echo "    chmod +x ~/sync/*.sh"
echo "    cp /sdcard/frame-setup/rclone.conf ~/.config/rclone/rclone.conf"
echo "    ln -sf ~/sync/boot.sh ~/.termux/boot/boot.sh"
echo ""
echo "    # SSH setup — paste your laptop's public key:"
echo "    echo 'YOUR_PUBLIC_KEY_HERE' >> ~/.ssh/authorized_keys"
echo "    chmod 600 ~/.ssh/authorized_keys"
echo "    sshd"
echo ""
echo "    # Test sync"
echo "    bash ~/sync/sync.sh"
echo ""
wait_enter

# --- Step 7: Tailscale ---
step "7/8" "Tailscale setup"
printf "  Launching Tailscale ... "
adb shell am start com.tailscale.ipn/.IPNActivity 2>/dev/null && ok || warn "Couldn't launch — open manually"
manual "On the frame:"
echo "    1. Sign in with your Tailscale account"
echo "    2. Go to Android Settings > Network & internet > VPN > Tailscale"
echo "    3. Enable 'Always-on VPN'"
wait_enter

# --- Step 8: Fully Kiosk ---
step "8/8" "Fully Kiosk Browser setup"
printf "  Launching Fully Kiosk ... "
adb shell am start de.ozerov.fully/.FullyActivity 2>/dev/null && ok || warn "Couldn't launch — open manually"
manual "In Fully Kiosk on the frame:"
echo "    1. Set Start URL to: http://localhost:8080"
echo "       (We'll run a tiny server in Termux — more reliable than file://)"
echo "    2. Go to Web Content Settings > Enable JavaScript"
echo "    3. Go to Other Settings > Kiosk Mode > Enable"
echo "    4. Go to Other Settings > Launch on Boot > Enable"
echo "    5. Press Home button > select Fully Kiosk > 'Always'"
echo ""
echo "    Then in Termux, add the HTTP server to boot.sh (already included)."
wait_enter

# --- Final verification ---
echo ""
echo "=== Provisioning complete ==="
echo ""
echo "  Verify:"
echo "    1. Slideshow is running in Fully Kiosk"
echo "    2. ssh user@<tailscale-ip> works from your laptop"
echo "    3. Power cycle the frame — everything auto-starts"
echo ""
echo "  If using localhost HTTP server, add to Termux boot script:"
echo "    cd ~/slideshow && python -m http.server 8080 &"
echo "  (This is already handled in boot.sh)"
