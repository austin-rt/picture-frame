#!/usr/bin/env bash
# Termux:Boot entry point. Place this (or symlink it) at ~/.termux/boot/boot.sh
# Starts: sshd, HTTP server, sync loop. All auto-restart on device reboot.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# If running from .termux/boot/, resolve sync scripts in ~/sync/
SYNC_DIR="$HOME/sync"
if [[ ! -f "$SYNC_DIR/sync.sh" ]]; then
    SYNC_DIR="$SCRIPT_DIR"
fi

# Fix SSL certs for Go binaries (rclone) on Android 6
if [[ -f "$PREFIX/etc/tls/cert.pem" ]]; then
    export SSL_CERT_FILE="$PREFIX/etc/tls/cert.pem"
fi

# Source frame config
FRAME_CONF="${FRAME_CONF:-$HOME/frame.conf}"
if [[ -f "$FRAME_CONF" ]]; then
    source "$FRAME_CONF"
fi

FRAME_DATA_DIR="${FRAME_DATA_DIR:-$HOME/frame-data}"
HTTP_PORT="${HTTP_PORT:-8080}"
FRAME_NAME="${FRAME_NAME:-frame}"
LOG="$FRAME_DATA_DIR/boot.log"

mkdir -p "$FRAME_DATA_DIR"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$FRAME_NAME] $*" >> "$LOG"
}

log "=== Boot script starting ==="

# Sync system clock (no battery-backed RTC on this device)
sync_clock() {
    if command -v ntpd >/dev/null 2>&1; then
        ntpd -d -n -q -p pool.ntp.org >> "$LOG" 2>&1 && return 0
    fi
    if command -v busybox >/dev/null 2>&1 && busybox ntpd --help >/dev/null 2>&1; then
        busybox ntpd -d -n -q -p pool.ntp.org >> "$LOG" 2>&1 && return 0
    fi
    # Fallback: set clock from HTTP Date header (needs su for system clock)
    if command -v curl >/dev/null 2>&1; then
        local http_date
        http_date=$(curl -sI --max-time 10 http://worldtimeapi.org/api/ip 2>/dev/null \
            | grep -i '^date:' | sed 's/^[Dd]ate: //' | tr -d '\r')
        if [[ -n "$http_date" ]]; then
            su -c "date -s '$http_date'" >> "$LOG" 2>&1 && return 0
            # If su fails, try without it (won't change system clock but logs the attempt)
            log "HTTP date available ($http_date) but cannot set system clock without root"
            return 1
        fi
    fi
    return 1
}

if sync_clock; then
    log "Clock synced"
else
    log "Clock sync failed — time may be wrong after power loss"
fi

# Whitelist Termux from battery optimization (no battery on this device)
dumpsys deviceidle whitelist +com.termux >/dev/null 2>&1 || true

# Kill stale services from any previous boot.sh run
pkill -f "busybox httpd" 2>/dev/null || true
pkill -f "sshd" 2>/dev/null || true

# Start sshd (for remote access over Tailscale)
if command -v sshd >/dev/null 2>&1; then
    sshd
    log "sshd started"
else
    log "sshd not installed — skipping (run: pkg install openssh)"
fi

# Start local HTTP server for kiosk WebView to load the slideshow
SLIDESHOW_DIR="$FRAME_DATA_DIR/slideshow"
if [[ -d "$SLIDESHOW_DIR" ]]; then
    cd "$SLIDESHOW_DIR"
    nohup busybox httpd -f -p "$HTTP_PORT" >> "$FRAME_DATA_DIR/httpd.log" 2>&1 &
    HTTPD_PID=$!
    log "HTTP server started on :$HTTP_PORT (PID $HTTPD_PID)"
    cd - >/dev/null
    # Verify httpd is actually running
    sleep 1
    if kill -0 "$HTTPD_PID" 2>/dev/null; then
        log "HTTP server verified running"
    else
        log "WARNING: HTTP server died immediately — retrying"
        cd "$SLIDESHOW_DIR"
        nohup busybox httpd -f -p "$HTTP_PORT" >> "$FRAME_DATA_DIR/httpd.log" 2>&1 &
        log "HTTP server retry (PID $!)"
        cd - >/dev/null
    fi
else
    log "Slideshow dir not found at $SLIDESHOW_DIR — sync will create it"
fi

# Launch kiosk slideshow app
am start -n com.frame.kiosk/.KioskActivity >> "$LOG" 2>&1 || true
log "Kiosk app launched"

# Start Tailscale (userspace networking, no root/TUN needed)
TSDIR="$HOME/.tailscale"
TAILSCALED="$PREFIX/bin/tailscaled"
TAILSCALE="$PREFIX/bin/tailscale"
if [[ -x "$TAILSCALED" ]]; then
    mkdir -p "$TSDIR"
    # Kill stale tailscaled if running
    pkill -f tailscaled 2>/dev/null || true
    sleep 1
    rm -f "$TSDIR/tailscaled.sock"
    nohup "$TAILSCALED" --tun=userspace-networking --statedir="$TSDIR" --socket="$TSDIR/tailscaled.sock" >> "$FRAME_DATA_DIR/tailscale.log" 2>&1 &
    log "tailscaled started (PID $!)"
    # Wait for socket to appear
    for i in 1 2 3 4 5 6 7 8 9 10; do
        [[ -S "$TSDIR/tailscaled.sock" ]] && break
        sleep 1
    done
    # Wait for tailscale to reach Running state (needs network + auth)
    TS_READY=false
    for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
        if "$TAILSCALE" --socket="$TSDIR/tailscaled.sock" status >/dev/null 2>&1; then
            TS_READY=true
            break
        fi
        sleep 1
    done
    if $TS_READY; then
        "$TAILSCALE" --socket="$TSDIR/tailscaled.sock" serve --bg --tcp 22 tcp://localhost:8022 >> "$LOG" 2>&1 || true
        log "Tailscale SSH proxy configured"
    else
        log "Tailscale not ready after 30s — serve skipped (will retry on next boot)"
    fi
else
    log "tailscaled not found — skipping"
fi

# Start sync loop in background
nohup bash "$SYNC_DIR/sync.sh" >> "$FRAME_DATA_DIR/sync.log" 2>&1 &
log "Sync loop started (PID $!)"

log "Boot script done."
