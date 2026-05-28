#!/usr/bin/env bash
# ADB triage script. Run from your laptop with the frame connected via USB.
# Reports everything needed to decide the setup path.

set -uo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

pass() { printf "${GREEN}[PASS]${NC} %s: %s\n" "$1" "$2"; }
warn() { printf "${YELLOW}[WARN]${NC} %s: %s\n" "$1" "$2"; }
fail() { printf "${RED}[FAIL]${NC} %s: %s\n" "$1" "$2"; }
info() { printf "       %s: %s\n" "$1" "$2"; }

echo "=== Picture Frame Triage ==="
echo "    YENOCK 10.1\" ZN-DP1101 (expected: Android 13, WebView 101, no root)"
echo ""

# Check ADB connectivity
if ! adb devices 2>/dev/null | grep -q "device$"; then
    fail "ADB" "No device found."
    echo ""
    echo "  To enable ADB on the Frameo frame:"
    echo "    1. Complete the Frameo setup wizard (skip account, just get past it)"
    echo "    2. Go to Settings > About > Enable Beta Program"
    echo "    3. Toggle 'ADB Access' On -> Off -> On"
    echo "    4. Connect USB cable to laptop"
    echo "    5. Accept the USB debugging prompt on the frame"
    echo ""
    exit 1
fi
pass "ADB" "Device connected"

# Android version
ANDROID_VER=$(adb shell getprop ro.build.version.release 2>/dev/null | tr -d '\r')
SDK_VER=$(adb shell getprop ro.build.version.sdk 2>/dev/null | tr -d '\r')
if (( SDK_VER >= 26 )); then
    pass "Android" "Version $ANDROID_VER (SDK $SDK_VER) — pm disable-user works, no root needed"
else
    fail "Android" "Version $ANDROID_VER (SDK $SDK_VER) — too old, needs root to disable Frameo. Consider returning."
fi

# Device model
MODEL=$(adb shell getprop ro.product.model 2>/dev/null | tr -d '\r')
info "Model" "$MODEL"

# CPU architecture
ARCH=$(adb shell getprop ro.product.cpu.abi 2>/dev/null | tr -d '\r')
info "CPU" "$ARCH"

# WebView version
WEBVIEW_INFO=$(adb shell dumpsys webviewupdate 2>/dev/null)
WEBVIEW_PKG=$(echo "$WEBVIEW_INFO" | grep "Current WebView package" | head -1 | tr -d '\r')
WEBVIEW_VER=$(echo "$WEBVIEW_INFO" | grep "versionName" | head -1 | sed 's/.*versionName = //' | tr -d '\r')
WEBVIEW_MAJOR=$(echo "$WEBVIEW_VER" | cut -d. -f1)
if [[ -n "$WEBVIEW_MAJOR" ]] && (( WEBVIEW_MAJOR >= 80 )); then
    pass "WebView" "v$WEBVIEW_VER — modern CSS supported"
else
    warn "WebView" "v${WEBVIEW_VER:-unknown} — may need sideloading"
fi
info "WebView pkg" "$WEBVIEW_PKG"

# Frameo package
FRAMEO_PKG=$(adb shell pm list packages 2>/dev/null | grep -i frameo | tr -d '\r')
if [[ -n "$FRAMEO_PKG" ]]; then
    info "Frameo" "$FRAMEO_PKG (found — will disable during provisioning)"
else
    warn "Frameo" "Package not found"
fi

# Wi-Fi
WIFI_STATE=$(adb shell dumpsys wifi 2>/dev/null | grep "mNetworkInfo" | head -1 | tr -d '\r')
if echo "$WIFI_STATE" | grep -q "CONNECTED"; then
    pass "Wi-Fi" "Connected"
else
    warn "Wi-Fi" "Not connected — connect via Android system settings BEFORE disabling Frameo"
fi
WIFI_SSID=$(adb shell dumpsys wifi 2>/dev/null | grep "mWifiInfo" | head -1 | sed 's/.*SSID: //' | cut -d, -f1 | tr -d '\r')
info "SSID" "${WIFI_SSID:-unknown}"

# Storage
STORAGE_FREE=$(adb shell df /sdcard 2>/dev/null | tail -1 | tr -d '\r')
info "Storage" "$STORAGE_FREE"
INTERNAL_PATH=$(adb shell echo '$HOME' 2>/dev/null | tr -d '\r')
info "Home path" "${INTERNAL_PATH:-/sdcard}"

# ADB over TCP
ADB_PORT=$(adb shell getprop service.adb.tcp.port 2>/dev/null | tr -d '\r')
if [[ -n "$ADB_PORT" && "$ADB_PORT" != "-1" && "$ADB_PORT" != "0" ]]; then
    pass "ADB TCP" "Port $ADB_PORT (network ADB enabled)"
else
    info "ADB TCP" "Not enabled (USB only)"
fi

echo ""
echo "=== Summary ==="
echo "Android $ANDROID_VER | SDK $SDK_VER | $ARCH | WebView ${WEBVIEW_VER:-unknown}"
echo "Ready for provisioning: $(if (( SDK_VER >= 26 )); then echo 'YES'; else echo 'NO — return frame'; fi)"

# Expected vs actual
echo ""
if [[ "$ANDROID_VER" == "13" ]] && [[ -n "$WEBVIEW_MAJOR" ]] && (( WEBVIEW_MAJOR >= 101 )); then
    pass "Match" "Specs match expected YENOCK ZN-DP1101 (Android 13, WebView 101+)"
else
    warn "Match" "Specs differ from expected — review before provisioning"
fi
