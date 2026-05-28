#!/usr/bin/env bash
# Termux:Boot entry point. Place this (or symlink it) at ~/.termux/boot/boot.sh
# Starts: sshd, sync loop. All auto-restart on device reboot.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
FRAME_DATA_DIR="${FRAME_DATA_DIR:-$HOME/frame-data}"
LOG="$FRAME_DATA_DIR/boot.log"

mkdir -p "$FRAME_DATA_DIR"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG"
}

log "=== Boot script starting ==="

# Acquire wake lock to prevent Android from sleeping Termux
termux-wake-lock 2>/dev/null || true

# Start sshd (for remote access over Tailscale)
if command -v sshd >/dev/null 2>&1; then
    sshd
    log "sshd started"
else
    log "sshd not installed — skipping (run: pkg install openssh)"
fi

# Start local HTTP server for Fully Kiosk to load the slideshow
SLIDESHOW_DIR="$FRAME_DATA_DIR/slideshow"
if [[ -d "$SLIDESHOW_DIR" ]]; then
    cd "$SLIDESHOW_DIR"
    nohup busybox httpd -f -p 8080 >> "$FRAME_DATA_DIR/httpd.log" 2>&1 &
    log "HTTP server started on :8080 (PID $!)"
    cd - >/dev/null
else
    log "Slideshow dir not found at $SLIDESHOW_DIR — sync will create it"
fi

# Start sync loop in background
nohup bash "$SCRIPT_DIR/sync.sh" >> "$FRAME_DATA_DIR/sync.log" 2>&1 &
log "Sync loop started (PID $!)"

log "Boot script done."
