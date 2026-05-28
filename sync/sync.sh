#!/usr/bin/env bash
# Main sync loop. Pulls photos from rclone remotes, processes them, updates manifest.
# Designed to run forever inside Termux, started by boot.sh.
# Testable on macOS — set FRAME_CONF to the config file path.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

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

RAW_DIR="$FRAME_DATA_DIR/raw"
PHOTOS_DIR="$FRAME_DATA_DIR/photos"
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

    # Process new/changed images
    local processed=0
    for f in "$RAW_DIR"/*; do
        [[ -f "$f" ]] || continue
        base=$(basename "$f")
        name="${base%.*}"
        out="$PHOTOS_DIR/${name}.jpg"

        if bash "$SCRIPT_DIR/process-image.sh" "$f" "$out"; then
            processed=$((processed + 1))
        else
            log "Failed to process: $base"
        fi
    done

    # Remove processed photos whose source no longer exists in raw/
    for f in "$PHOTOS_DIR"/*.jpg; do
        [[ -f "$f" ]] || continue
        base=$(basename "$f" .jpg)
        if ! ls "$RAW_DIR"/"$base".* >/dev/null 2>&1; then
            log "Removing deleted photo: $(basename "$f")"
            rm "$f"
        fi
    done

    # Regenerate manifest
    bash "$SCRIPT_DIR/generate-manifest.sh" "$PHOTOS_DIR" "$MANIFEST"
    log "Manifest updated. $processed new images processed."

    if $failed; then
        return 1
    fi
    return 0
}

# --- Main loop ---
log "=== Sync loop starting ==="
log "Data dir: $FRAME_DATA_DIR"
log "Remotes: $RCLONE_REMOTES"
log "Interval: ${SYNC_INTERVAL}s"

while true; do
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
