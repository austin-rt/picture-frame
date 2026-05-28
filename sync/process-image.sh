#!/usr/bin/env bash
# Process a single image: convert to JPEG, downscale to fit 1280x800, strip metadata.
# Usage: process-image.sh <input> <output>
# Skips if output already exists and is newer than input.

set -euo pipefail

INPUT="$1"
OUTPUT="$2"

if [[ -f "$OUTPUT" && "$OUTPUT" -nt "$INPUT" ]]; then
    exit 0
fi

# Downscale to fit within 1280x800, convert to JPEG, strip EXIF, quality 85.
# -vf scale: uses -2 to maintain aspect ratio and ensure even dimensions.
# Input can be HEIC, PNG, JPEG, WEBP — ffmpeg handles all of them.
ffmpeg -y -i "$INPUT" \
    -vf "scale='min(1280,iw)':'min(800,ih)':force_original_aspect_ratio=decrease" \
    -q:v 4 \
    -map_metadata -1 \
    "$OUTPUT" 2>/dev/null
