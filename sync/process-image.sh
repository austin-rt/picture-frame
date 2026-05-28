#!/usr/bin/env bash
# Process a single image: convert to JPEG, downscale to frame resolution, strip metadata.
# Usage: process-image.sh <input> <output>
# Reads FRAME_WIDTH, FRAME_HEIGHT, IMAGE_QUALITY from environment (set by frame.env).

set -euo pipefail

INPUT="$1"
OUTPUT="$2"
MAX_W="${FRAME_WIDTH:-1280}"
MAX_H="${FRAME_HEIGHT:-800}"
QUALITY="${IMAGE_QUALITY:-4}"

if [[ -f "$OUTPUT" && "$OUTPUT" -nt "$INPUT" ]]; then
    exit 0
fi

ffmpeg -y -i "$INPUT" \
    -vf "scale='min(${MAX_W},iw)':'min(${MAX_H},ih)':force_original_aspect_ratio=decrease" \
    -q:v "$QUALITY" \
    -map_metadata -1 \
    "$OUTPUT" 2>/dev/null
