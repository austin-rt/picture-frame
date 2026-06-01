#!/usr/bin/env bash
# Reboot stress test: verifies all services start reliably after power cycle.
# Run from Mac with ADB connected to the frame.
# Usage: bash setup/stress-test.sh [NUM_REBOOTS]
set -uo pipefail

REBOOTS="${1:-10}"
ADB_HOST="<frame-lan-ip>:5555"
# How long to wait after reboot for Android + Termux + boot.sh to finish
BOOT_WAIT=90
# Extra time to wait for Tailscale to connect
TS_EXTRA_WAIT=30

PASS=0
FAIL=0

log() { echo "[$(date '+%H:%M:%S')] $*"; }

adb_reconnect() {
    adb disconnect >/dev/null 2>&1
    sleep 2
    for attempt in 1 2 3 4 5 6 7 8 9 10; do
        if adb connect "$ADB_HOST" 2>&1 | grep -q "connected"; then
            sleep 2
            if adb shell "echo ok" 2>&1 | grep -q "ok"; then
                return 0
            fi
        fi
        sleep 5
    done
    return 1
}

wait_for_boot() {
    local waited=0
    log "  Waiting for device to come back (up to ${BOOT_WAIT}s)..."
    # Wait for ADB to reconnect
    while (( waited < BOOT_WAIT )); do
        adb disconnect >/dev/null 2>&1
        if adb connect "$ADB_HOST" 2>&1 | grep -q "connected"; then
            sleep 2
            if adb shell "echo ok" 2>&1 | grep -q "ok"; then
                log "  ADB back after ${waited}s"
                # Give boot.sh time to run (it starts ~15s after Android boots)
                local remaining=$((BOOT_WAIT - waited))
                if (( remaining > 30 )); then
                    remaining=30
                fi
                log "  Waiting ${remaining}s more for services..."
                sleep "$remaining"
                return 0
            fi
        fi
        sleep 5
        waited=$((waited + 5))
    done
    return 1
}

check_service() {
    local name="$1"
    local cmd="$2"
    local result
    result=$(adb shell "$cmd" 2>&1)
    if echo "$result" | grep -q "1\|ok\|running"; then
        echo -n "${name}=OK "
        return 0
    else
        echo -n "${name}=FAIL "
        return 1
    fi
}

run_checks() {
    local all_ok=true

    # Check httpd (busybox httpd process running)
    if ! adb shell "run-as com.termux sh -c 'pgrep -c -f \"busybox httpd\"'" 2>&1 | grep -q "[1-9]"; then
        echo -n "httpd=FAIL "
        all_ok=false
    else
        echo -n "httpd=OK "
    fi

    # Check sshd
    if ! adb shell "run-as com.termux sh -c 'pgrep -c sshd'" 2>&1 | grep -q "[1-9]"; then
        echo -n "sshd=FAIL "
        all_ok=false
    else
        echo -n "sshd=OK "
    fi

    # Check kiosk app
    if ! adb shell "ps | grep com.frame.kiosk" 2>&1 | grep -q "kiosk"; then
        echo -n "kiosk=FAIL "
        all_ok=false
    else
        echo -n "kiosk=OK "
    fi

    # Check tailscaled
    if ! adb shell "run-as com.termux sh -c 'pgrep -c tailscaled'" 2>&1 | grep -q "[1-9]"; then
        echo -n "tailscaled=FAIL "
        all_ok=false
    else
        echo -n "tailscaled=OK "
    fi

    # Check sync loop (bash running sync.sh)
    if ! adb shell "run-as com.termux sh -c 'pgrep -c -f sync.sh'" 2>&1 | grep -q "[1-9]"; then
        echo -n "sync=FAIL "
        all_ok=false
    else
        echo -n "sync=OK "
    fi

    # Check HTTP response (slideshow page via Termux curl with full PATH)
    local http_check
    http_check=$(adb shell "run-as com.termux sh -c 'export PATH=/data/data/com.termux/files/usr/bin:\$PATH && export LD_LIBRARY_PATH=/data/data/com.termux/files/usr/lib && curl -s -o /dev/null -w \"%{http_code}\" http://localhost:8080/ 2>/dev/null || echo 000'" 2>&1)
    if echo "$http_check" | grep -q "200"; then
        echo -n "http=200 "
    else
        echo -n "http=${http_check} "
        all_ok=false
    fi

    echo ""
    $all_ok
}

echo "========================================="
echo "Reboot Stress Test: $REBOOTS reboots"
echo "========================================="

# Initial connection
log "Connecting to $ADB_HOST..."
if ! adb_reconnect; then
    echo "FATAL: Cannot connect to device"
    exit 1
fi
log "Connected."

for i in $(seq 1 "$REBOOTS"); do
    echo ""
    log "=== REBOOT $i/$REBOOTS ==="

    # Reboot via ADB
    adb shell "su -c reboot" 2>/dev/null || adb reboot 2>/dev/null || true
    sleep 5

    # Wait for device to come back
    if ! wait_for_boot; then
        log "  FAIL: Device did not come back"
        FAIL=$((FAIL + 1))
        echo "  RESULT: FAIL (no ADB)"
        # Try to reconnect for next iteration
        sleep 30
        adb_reconnect || true
        continue
    fi

    # Run service checks
    echo -n "  "
    if run_checks; then
        log "  RESULT: PASS"
        PASS=$((PASS + 1))
    else
        log "  RESULT: FAIL"
        FAIL=$((FAIL + 1))
        # Dump boot log tail for debugging
        echo "  --- Boot log tail ---"
        adb shell "run-as com.termux cat /data/data/com.termux/files/home/frame-data/boot.log" 2>&1 | tail -10 | sed 's/^/  /'
        echo "  ---"
    fi
done

echo ""
echo "========================================="
echo "RESULTS: $PASS pass, $FAIL fail out of $REBOOTS"
echo "========================================="

if (( FAIL == 0 )); then
    echo "ALL PASSED"
    exit 0
else
    echo "FAILURES DETECTED"
    exit 1
fi
