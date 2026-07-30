#!/usr/bin/env bash
# Process a single video: transcode to H.264 MP4, downscale to frame resolution.
# Optimized for maximum compression while maintaining acceptable quality on a
# 10" 1280x800 screen with small/no speakers.
# Usage: process-video.sh <input> <output>

set -euo pipefail

INPUT="$1"
OUTPUT="$2"
MAX_W="${FRAME_WIDTH:-1280}"
MAX_H="${FRAME_HEIGHT:-800}"
MAX_DURATION="${MAX_VIDEO_DURATION:-120}"

if [[ -f "$OUTPUT" && "$OUTPUT" -nt "$INPUT" ]]; then
    exit 0
fi

# Probe input: codec, resolution, duration
PROBE=$(ffprobe -v quiet -select_streams v:0 \
    -show_entries stream=codec_name,width,height \
    -show_entries format=duration \
    -of csv=p=0 "$INPUT" 2>/dev/null) || true
CODEC=$(echo "$PROBE" | head -1 | cut -d',' -f1)
VW=$(echo "$PROBE" | head -1 | cut -d',' -f2)
VH=$(echo "$PROBE" | head -1 | cut -d',' -f3)
# Duration is on the second line (format entry)
DURATION=$(echo "$PROBE" | tail -1 | cut -d',' -f1)
DURATION_INT=${DURATION%.*}
DURATION_INT=${DURATION_INT:-0}

# Duration limit args (-t only if needed)
T_ARGS=""
if (( DURATION_INT > MAX_DURATION )); then
    T_ARGS="-t $MAX_DURATION"
fi

NEEDS_TRANSCODE=true
if [[ "$CODEC" == "h264" && -n "$VW" && -n "$VH" ]] \
   && (( VW <= MAX_W && VH <= MAX_H )); then
    NEEDS_TRANSCODE=false
fi

if ! $NEEDS_TRANSCODE; then
    # Already H.264 at frame resolution — remux without re-encoding
    # Still apply duration limit and optimize audio for small speakers
    ffmpeg -y -i "$INPUT" $T_ARGS \
        -c:v copy \
        -c:a aac -b:a 64k -ac 1 -ar 22050 \
        -movflags +faststart \
        -map_metadata -1 \
        "$OUTPUT" 2>/dev/null
else
    # Transcode: aggressive compression tuned for 10" frame
    #   CRF 30     — very compressed but fine at 1280x800 viewing distance
    #   maxrate    — cap peak bitrate so weak ARM decoder isn't overwhelmed
    #   24fps      — saves ~20% over 30fps, looks fine for frame content
    #   fastdecode — helps the weak Rockchip ARM decoder
    #   baseline   — widest Android WebView compatibility
    #   mono 64k   — frame has tiny/no speakers
    ffmpeg -y -i "$INPUT" $T_ARGS \
        -vf "scale='min(${MAX_W},iw)':'min(${MAX_H},ih)':force_original_aspect_ratio=decrease" \
        -pix_fmt yuv420p \
        -c:v libx264 -profile:v baseline -level 3.1 \
        -preset veryfast -crf 23 -tune fastdecode \
        -maxrate 2000k -bufsize 4000k \
        -r 24 \
        -c:a aac -b:a 64k -ac 1 -ar 22050 \
        -movflags +faststart \
        -map_metadata -1 \
        "$OUTPUT" 2>/dev/null
fi
