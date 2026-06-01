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

# Sync system clock via NTP (no battery-backed RTC on this device)
if command -v ntpd >/dev/null 2>&1; then
    ntpd -d -n -q -p pool.ntp.org >> "$LOG" 2>&1 || true
    log "NTP time sync attempted"
elif command -v busybox >/dev/null 2>&1 && busybox ntpd --help >/dev/null 2>&1; then
    busybox ntpd -d -n -q -p pool.ntp.org >> "$LOG" 2>&1 || true
    log "NTP time sync attempted (busybox)"
else
    log "No NTP client available — clock may drift after power loss"
fi

# Acquire wake lock to prevent Android from sleeping Termux
termux-wake-lock 2>/dev/null || true

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
    log "HTTP server started on :$HTTP_PORT (PID $!)"
    cd - >/dev/null
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
    nohup "$TAILSCALED" --tun=userspace-networking --statedir="$TSDIR" --socket="$TSDIR/tailscaled.sock" >> "$FRAME_DATA_DIR/tailscale.log" 2>&1 &
    log "tailscaled started (PID $!)"
    sleep 3
    "$TAILSCALE" --socket="$TSDIR/tailscaled.sock" serve --bg --tcp 22 tcp://localhost:8022 >> "$LOG" 2>&1 || true
    log "Tailscale SSH proxy configured"
else
    log "tailscaled not found — skipping"
fi

# Start sync loop in background
nohup bash "$SYNC_DIR/sync.sh" >> "$FRAME_DATA_DIR/sync.log" 2>&1 &
log "Sync loop started (PID $!)"

log "Boot script done."
