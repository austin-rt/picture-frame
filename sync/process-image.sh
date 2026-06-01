#!/usr/bin/env bash
# Process a single image: convert to JPEG, downscale, auto-rotate, strip metadata.
# Supports JPEG, PNG, and HEIC (via heic2jpg pre-conversion).
# Usage: process-image.sh <input> <output>

set -euo pipefail

INPUT="$1"
OUTPUT="$2"
MAX_W="${FRAME_WIDTH:-1280}"
MAX_H="${FRAME_HEIGHT:-800}"
QUALITY="${IMAGE_QUALITY:-4}"

if [[ -f "$OUTPUT" && "$OUTPUT" -nt "$INPUT" ]]; then
    exit 0
fi

# HEIC pre-conversion: decode to temp JPEG, then process normally.
HEIC_TMP=""
EXT="${INPUT##*.}"
EXT_LOWER=$(echo "$EXT" | tr 'A-Z' 'a-z')
if [[ "$EXT_LOWER" == "heic" || "$EXT_LOWER" == "heif" ]]; then
    if command -v heic2jpg >/dev/null 2>&1; then
        HEIC_TMP="${INPUT}.tmp.jpg"
        heic2jpg "$INPUT" "$HEIC_TMP"
        INPUT="$HEIC_TMP"
    else
        echo "heic2jpg not found, skipping HEIC file: $INPUT" >&2
        exit 1
    fi
fi
trap '[[ -n "$HEIC_TMP" ]] && rm -f "$HEIC_TMP"' EXIT

# Read EXIF orientation from JPEG by parsing raw bytes.
# busybox od outputs hex, we grep for the orientation tag pattern.
ROTATE_FILTER=""
HEX=$(busybox od -A n -t x1 -N 500 "$INPUT" 2>/dev/null | tr -d ' \n') || true
if [[ -n "$HEX" ]]; then
    # Big-endian EXIF: tag=0112, type=0003, count=00000001, then 2-byte value
    MATCH=$(echo "$HEX" | grep -o "011200030000000100.." 2>/dev/null) || true
    if [[ -n "$MATCH" ]]; then
        ORIENT_HEX="${MATCH: -2}"
        ORIENT=$((16#$ORIENT_HEX)) 2>/dev/null || ORIENT=1
        case "$ORIENT" in
            3) ROTATE_FILTER="transpose=1,transpose=1," ;;
            6) ROTATE_FILTER="transpose=1," ;;
            8) ROTATE_FILTER="transpose=2," ;;
        esac
    fi
fi

ffmpeg -y -noautorotate -i "$INPUT" \
    -vf "${ROTATE_FILTER}scale='min(${MAX_W},iw)':'min(${MAX_H},ih)':force_original_aspect_ratio=decrease" \
    -q:v "$QUALITY" \
    -map_metadata -1 \
    "$OUTPUT" 2>/dev/null
