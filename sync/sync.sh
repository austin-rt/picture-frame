#!/usr/bin/env bash
# Main sync loop. Pulls photos from rclone remotes, processes them, updates manifest.
# Designed to run forever inside Termux, started by boot.sh.
# Testable on macOS — set FRAME_CONF to the config file path.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Prevent duplicate sync processes
PIDFILE="${TMPDIR:-/tmp}/frame-sync.pid"
if [[ -f "$PIDFILE" ]] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
    echo "Sync already running (PID $(cat "$PIDFILE")), exiting."
    exit 0
fi
echo $$ > "$PIDFILE"
trap 'rm -f "$PIDFILE"' EXIT

# Fix SSL certs for Go binaries (rclone) on Android 6
if [[ -f "$PREFIX/etc/tls/cert.pem" ]]; then
    export SSL_CERT_FILE="$PREFIX/etc/tls/cert.pem"
fi

# Source frame config
FRAME_CONF="${FRAME_CONF:-$HOME/frame.conf}"
if [[ -f "$FRAME_CONF" ]]; then
    source "$FRAME_CONF"
fi

# --- Config (from frame.conf, with defaults) ---
FRAME_DATA_DIR="${FRAME_DATA_DIR:-$HOME/frame-data}"
RCLONE_CONF="${RCLONE_CONF:-$HOME/.config/rclone/rclone.conf}"
SYNC_INTERVAL="${SYNC_INTERVAL:-1800}"
MAX_BACKOFF="${MAX_BACKOFF:-7200}"
RCLONE_REMOTES="${RCLONE_REMOTES:-drive:PhotoFrame}"
SLIDESHOW_INTERVAL="${SLIDESHOW_INTERVAL:-30}"
FADE_DURATION="${FADE_DURATION:-1500}"
FRAME_NAME="${FRAME_NAME:-frame}"
MAX_PHOTOS="${MAX_PHOTOS:-500}"
MAX_VIDEO_DURATION="${MAX_VIDEO_DURATION:-120}"
DELETE_AFTER_SYNC="${DELETE_AFTER_SYNC:-false}"

export FRAME_WIDTH="${FRAME_WIDTH:-1280}"
export FRAME_HEIGHT="${FRAME_HEIGHT:-800}"
export IMAGE_QUALITY="${IMAGE_QUALITY:-4}"
export MAX_VIDEO_DURATION

RAW_DIR="$FRAME_DATA_DIR/raw"
PHOTOS_DIR="$FRAME_DATA_DIR/photos"
LOCKED_FILE="$FRAME_DATA_DIR/locked.txt"
SLIDESHOW_DIR="$FRAME_DATA_DIR/slideshow"
MANIFEST="$SLIDESHOW_DIR/manifest.json"
CONFIG_JSON="$SLIDESHOW_DIR/config.json"

LOG_FILE="${LOG_FILE:-$FRAME_DATA_DIR/sync.log}"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$FRAME_NAME] $*" | tee -a "$LOG_FILE"
}

# --- Setup directories ---
mkdir -p "$RAW_DIR" "$PHOTOS_DIR" "$SLIDESHOW_DIR"

# Symlink photos dir into slideshow dir so the HTML can reference photos/filename.jpg
ln -sfn "$PHOTOS_DIR" "$SLIDESHOW_DIR/photos"

# If slideshow HTML isn't deployed yet, copy it from the script's sibling directory
if [[ ! -f "$SLIDESHOW_DIR/index.html" && -d "$SCRIPT_DIR/../slideshow" ]]; then
    cp "$SCRIPT_DIR/../slideshow/"* "$SLIDESHOW_DIR/" 2>/dev/null || true
    log "Copied slideshow files to $SLIDESHOW_DIR"
fi

# Write config.json for the slideshow front-end
cat > "$CONFIG_JSON" <<EJSON
{
  "interval": ${SLIDESHOW_INTERVAL},
  "fadeDuration": ${FADE_DURATION},
  "frameName": "${FRAME_NAME}"
}
EJSON

current_backoff="$SYNC_INTERVAL"

# Check if a filename is locked (favorited by user, exempt from FIFO deletion)
is_locked() {
    local filename="$1"
    [[ -f "$LOCKED_FILE" ]] || return 1
    grep -qxF "$filename" "$LOCKED_FILE" 2>/dev/null
}

# FIFO cleanup: remove oldest unlocked photos when over MAX_PHOTOS
fifo_cleanup() {
    local count=0
    for f in "$PHOTOS_DIR"/*; do
        [[ -f "$f" ]] && count=$((count + 1))
    done

    if (( count <= MAX_PHOTOS )); then
        return
    fi

    local to_remove=$((count - MAX_PHOTOS))
    log "FIFO: $count photos exceeds max $MAX_PHOTOS, removing $to_remove oldest"

    # Sort by modification time (oldest first) and remove unlocked ones
    ls -1tr "$PHOTOS_DIR" | while read -r fname && (( to_remove > 0 )); do
        if ! is_locked "$fname"; then
            log "FIFO removing: $fname"
            rm -f "$PHOTOS_DIR/$fname"
            # Also remove from raw/ so it doesn't get re-processed
            local rname="${fname%.*}"
            rm -f "$RAW_DIR"/"$rname".* 2>/dev/null
            to_remove=$((to_remove - 1))
        fi
    done
}

sync_once() {
    local failed=false

    for remote in $RCLONE_REMOTES; do
        log "Syncing from $remote ..."
        if rclone sync --config "$RCLONE_CONF" "$remote" "$RAW_DIR" \
            --transfers 2 --checkers 2 --low-level-retries 3 \
            --timeout 60s --contimeout 15s 2>>"$LOG_FILE"; then
            log "Sync from $remote complete."
        else
            log "Sync from $remote failed (exit $?). Will retry next cycle."
            failed=true
        fi
    done

    # Known file extensions
    local IMG_EXTS="jpg jpeg png heic heif bmp tiff"
    local VID_EXTS="mp4 mov avi mkv webm m4v 3gp"

    is_image() {
        local ext=$(echo "${1##*.}" | tr 'A-Z' 'a-z')
        for e in $IMG_EXTS; do [[ "$ext" == "$e" ]] && return 0; done
        return 1
    }

    is_video() {
        local ext=$(echo "${1##*.}" | tr 'A-Z' 'a-z')
        for e in $VID_EXTS; do [[ "$ext" == "$e" ]] && return 0; done
        return 1
    }

    # Process new/changed files
    local processed=0
    for f in "$RAW_DIR"/*; do
        [[ -f "$f" ]] || continue
        base=$(basename "$f")
        name="${base%.*}"

        if is_image "$base"; then
            out="$PHOTOS_DIR/${name}.jpg"
            if bash "$SCRIPT_DIR/process-image.sh" "$f" "$out"; then
                processed=$((processed + 1))
            else
                log "Failed to process image: $base"
            fi
        elif is_video "$base"; then
            out="$PHOTOS_DIR/${name}.mp4"
            if bash "$SCRIPT_DIR/process-video.sh" "$f" "$out"; then
                processed=$((processed + 1))
            else
                log "Failed to process video: $base"
            fi
        fi
    done

    # Remove processed files whose source no longer exists in raw/
    for f in "$PHOTOS_DIR"/*; do
        [[ -f "$f" ]] || continue
        local pbase=$(basename "$f")
        local pname="${pbase%.*}"
        if ! ls "$RAW_DIR"/"$pname".* >/dev/null 2>&1; then
            if ! is_locked "$pbase"; then
                log "Removing deleted: $pbase"
                rm "$f"
            fi
        fi
    done

    # FIFO: if over MAX_PHOTOS, remove oldest unlocked files
    fifo_cleanup

    # Delete from remote after successful ingest (if enabled)
    if [[ "$DELETE_AFTER_SYNC" == "true" ]] && ! $failed; then
        for remote in $RCLONE_REMOTES; do
            for f in "$RAW_DIR"/*; do
                [[ -f "$f" ]] || continue
                local rbase=$(basename "$f")
                local rname="${rbase%.*}"
                # Only delete if successfully processed
                if ls "$PHOTOS_DIR"/"$rname".* >/dev/null 2>&1; then
                    if rclone deletefile --config "$RCLONE_CONF" "$remote/$rbase" 2>>"$LOG_FILE"; then
                        log "Deleted from remote: $rbase"
                        rm "$f"
                    fi
                fi
            done
        done
    fi

    # Regenerate manifest
    bash "$SCRIPT_DIR/generate-manifest.sh" "$PHOTOS_DIR" "$MANIFEST"
    log "Manifest updated. $processed new images processed."

    if $failed; then
        return 1
    fi
    return 0
}

# --- Service watchdog ---
HTTP_PORT="${HTTP_PORT:-8080}"
check_services() {
    # Restart httpd if not running
    if ! pgrep -f "busybox httpd" >/dev/null 2>&1; then
        if [[ -d "$SLIDESHOW_DIR" ]]; then
            log "WATCHDOG: httpd died — restarting"
            cd "$SLIDESHOW_DIR"
            nohup busybox httpd -f -p "$HTTP_PORT" >> "$FRAME_DATA_DIR/httpd.log" 2>&1 &
            cd - >/dev/null
        fi
    fi
}

# --- Main loop ---
log "=== Sync loop starting ==="
log "Data dir: $FRAME_DATA_DIR"
log "Remotes: $RCLONE_REMOTES"
log "Interval: ${SYNC_INTERVAL}s"

while true; do
    check_services
    if sync_once; then
        current_backoff="$SYNC_INTERVAL"
    else
        current_backoff=$((current_backoff * 2))
        if (( current_backoff > MAX_BACKOFF )); then
            current_backoff="$MAX_BACKOFF"
        fi
        log "Backing off: next sync in ${current_backoff}s"
    fi

    sleep "$current_backoff"
done
