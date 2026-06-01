#!/usr/bin/env bash
# Process a single video: transcode to H.264 MP4, downscale to frame resolution.
# Usage: process-video.sh <input> <output>

set -euo pipefail

INPUT="$1"
OUTPUT="$2"
MAX_W="${FRAME_WIDTH:-1280}"
MAX_H="${FRAME_HEIGHT:-800}"

if [[ -f "$OUTPUT" && "$OUTPUT" -nt "$INPUT" ]]; then
    exit 0
fi

# Check if input is already H.264 MP4 at acceptable resolution
PROBE=$(ffprobe -v quiet -select_streams v:0 \
    -show_entries stream=codec_name,width,height \
    -of csv=p=0 "$INPUT" 2>/dev/null) || true
CODEC=$(echo "$PROBE" | cut -d',' -f1)
VW=$(echo "$PROBE" | cut -d',' -f2)
VH=$(echo "$PROBE" | cut -d',' -f3)

if [[ "$CODEC" == "h264" && -n "$VW" && -n "$VH" ]] \
   && (( VW <= MAX_W && VH <= MAX_H )); then
    # Already H.264 at frame resolution — remux without re-encoding
    ffmpeg -y -i "$INPUT" \
        -c:v copy -c:a aac -b:a 128k -ac 2 \
        -movflags +faststart \
        -map_metadata -1 \
        "$OUTPUT" 2>/dev/null
else
    # Transcode — veryfast preset for weak ARM CPU
    ffmpeg -y -i "$INPUT" \
        -vf "scale='min(${MAX_W},iw)':'min(${MAX_H},ih)':force_original_aspect_ratio=decrease" \
        -c:v libx264 -profile:v baseline -level 3.1 \
        -preset veryfast -crf 28 \
        -c:a aac -b:a 128k -ac 2 \
        -movflags +faststart \
        -map_metadata -1 \
        "$OUTPUT" 2>/dev/null
fi
