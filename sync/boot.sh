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

# Sync system clock. There's no battery-backed RTC on this device, so every
# cold boot comes up believing it's 2021-05-14 until something corrects it.
#
# Both ntpd paths are dead here and always were: there is no standalone ntpd
# installed, and this busybox was built without the ntpd applet
# ("ntpd: applet not found"). The old worldtimeapi.org fallback is dead too —
# it now returns an empty response. That is why every boot logged
# "Clock sync failed".
#
# What does work: read the Date: header over plain HTTP and hand it straight to
# GNU date -s, which parses the RFC-1123 form and does the GMT->local
# conversion itself. Setting the clock needs root, which we have whenever the
# kiosk app launches us via su.
#
# Bare IPs are used as the last resort so a broken resolver can't defeat this.
CLOCK_HOSTS="http://google.com http://cloudflare.com http://1.1.1.1 http://8.8.8.8"

http_date_now() {
    local host http_date
    for host in $CLOCK_HOSTS; do
        http_date=$(curl -sI --max-time 8 "$host" 2>/dev/null \
            | grep -i '^date:' | sed 's/^[Dd]ate: //' | tr -d '\r')
        if [[ -n "$http_date" ]]; then
            echo "$http_date"
            return 0
        fi
    done
    return 1
}

set_clock_from_http() {
    local http_date stamp
    http_date=$(http_date_now) || return 1

    if [[ "$(id -u)" == "0" ]]; then
        date -s "$http_date" >> "$LOG" 2>&1 && return 0
    fi

    # Not root: hand Android's own date the numeric form it accepts, since
    # toybox date won't parse an RFC-1123 string.
    stamp=$(date -d "$http_date" '+%m%d%H%M%Y.%S' 2>/dev/null) || return 1
    su -c "date $stamp" >> "$LOG" 2>&1 && return 0
    return 1
}

sync_clock() {
    if command -v ntpd >/dev/null 2>&1; then
        ntpd -d -n -q -p pool.ntp.org >> "$LOG" 2>&1 && return 0
    fi
    set_clock_from_http
}

# One fast attempt inline. If the network isn't up yet we do NOT block boot on
# it — sshd and Tailscale matter more than the clock, and being unreachable is
# the failure mode that actually strands this device. Retries continue in the
# background instead.
if sync_clock; then
    log "Clock synced: $(date '+%Y-%m-%d %H:%M:%S %Z')"
else
    log "Clock sync failed on first try — retrying in background"
    (
        for _ in 1 2 3 4 5 6 7 8 9 10 11 12; do
            sleep 10
            if sync_clock; then
                log "Clock synced (background): $(date '+%Y-%m-%d %H:%M:%S %Z')"
                exit 0
            fi
        done
        log "Clock sync still failing after 2min — relying on Android auto_time"
    ) &
fi

# Whitelist Termux from battery optimization (no battery on this device)
dumpsys deviceidle whitelist +com.termux >/dev/null 2>&1 || true

# Kill stale services from any previous boot.sh run
pkill -f "busybox httpd" 2>/dev/null || true
pkill -f "sshd" 2>/dev/null || true

# Start sshd (for remote access over Tailscale).
#
# This has to work whether boot.sh runs as the Termux user (Termux:Boot) or as
# root (kiosk app via su), and the two cases need different flags:
#
#   - As the Termux user, plain `sshd` works: the app uid has the inet group
#     (3003) so it can bind, and sshd resolves the login to the Termux user.
#   - As root, `su` grants uid 0 but NO supplementary groups. Binding is fine,
#     but Android has no real passwd file, so sshd can only resolve "root".
#     Logging in as any other name fails with "Permission denied". So we have
#     to permit root login, point AuthorizedKeysFile at the Termux user's keys
#     (root's home is "/" and read-only), and disable StrictModes since those
#     key files are owned by u0_a32, not root.
#
# Note the reverse is NOT an option: running sshd as uid 10032 via `su 10032`
# fails with "socket: Permission denied" because it loses the inet group.
start_sshd() {
    if ! command -v sshd >/dev/null 2>&1; then
        log "sshd not installed — skipping (run: pkg install openssh)"
        return 1
    fi
    if [[ "$(id -u)" == "0" ]]; then
        sshd \
            -o "ListenAddress 0.0.0.0" \
            -o "UseDNS no" \
            -o "PermitRootLogin yes" \
            -o "StrictModes no" \
            -o "AuthorizedKeysFile $HOME/.ssh/authorized_keys" \
            -E "$FRAME_DATA_DIR/sshd.log"
        log "sshd started as root (login as root@)"
    else
        sshd
        log "sshd started as $(id -un) (login as $(id -un)@)"
    fi
}

start_sshd

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

# Watchdog: restart sshd and tailscaled if they die
(
    while true; do
        sleep 300
        if ! pgrep -f sshd >/dev/null 2>&1; then
            start_sshd
            log "Watchdog: restarted sshd"
        fi
        if ! pgrep -f tailscaled >/dev/null 2>&1; then
            if [[ -x "$TAILSCALED" ]]; then
                rm -f "$TSDIR/tailscaled.sock"
                nohup "$TAILSCALED" --tun=userspace-networking --statedir="$TSDIR" --socket="$TSDIR/tailscaled.sock" >> "$FRAME_DATA_DIR/tailscale.log" 2>&1 &
                log "Watchdog: restarted tailscaled (PID $!)"
                sleep 15
                "$TAILSCALE" --socket="$TSDIR/tailscaled.sock" serve --bg --tcp 22 tcp://localhost:8022 >> "$LOG" 2>&1 || true
                log "Watchdog: reconfigured tailscale serve"
            fi
        fi
    done
) &
log "Watchdog started (PID $!)"
