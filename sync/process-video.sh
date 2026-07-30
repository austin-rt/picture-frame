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

# Encode quality knobs, overridable from frame.conf so these can be tuned
# without editing this script.
#   CRF 19    — visually near-transparent at this size. Was 30, then 23; both
#               left visible blocking on detailed footage (grass, hair, sand).
#   maxrate   — the old 2000k ceiling was the real limiter: at 1280x800 a
#               detailed 24fps scene wants more than that, so the encoder hit
#               the cap and blocked up regardless of CRF.
#   fps 24    — kept, along with baseline/fastdecode, because the Rockchip
#               rk312x decoder in this frame is weak and stutters if pushed.
VIDEO_CRF="${VIDEO_CRF:-19}"
VIDEO_MAXRATE="${VIDEO_MAXRATE:-6000k}"
VIDEO_BUFSIZE="${VIDEO_BUFSIZE:-12000k}"
VIDEO_FPS="${VIDEO_FPS:-24}"

# Is a file a complete, playable video? A failed encode used to leave a
# truncated .mp4 behind, and because that file was newer than the source it was
# treated as "already done" forever — the frame then served a video that never
# decodes. Anything that doesn't probe clean gets rebuilt.
#
# Checking the container duration alone is NOT enough: -movflags +faststart puts
# the moov atom at the front, so a truncated file still reports its original
# full duration and ffmpeg exits 0 while spewing decode errors. Compare the last
# video packet's timestamp against the declared duration instead — a file cut
# short stops delivering packets long before the end.
is_playable() {
    local f="$1" dur last
    [[ -s "$f" ]] || return 1
    dur=$(ffprobe -v quiet -show_entries format=duration -of csv=p=0 "$f" 2>/dev/null \
          | head -1 | cut -d',' -f1)
    [[ -n "$dur" && "${dur%.*}" -ge 0 ]] 2>/dev/null || return 1
    last=$(ffprobe -v quiet -select_streams v:0 -show_entries packet=pts_time \
           -of csv=p=0 "$f" 2>/dev/null | tail -1 | cut -d',' -f1)
    [[ -n "$last" ]] || return 1
    # Allow 1.5s of slack for the final GOP and container rounding.
    awk -v d="$dur" -v l="$last" 'BEGIN { exit !(l > 0 && l >= d - 1.5) }'
}

if [[ -f "$OUTPUT" && "$OUTPUT" -nt "$INPUT" ]]; then
    if is_playable "$OUTPUT"; then
        exit 0
    fi
    echo "re-encoding: existing output is corrupt ($(basename "$OUTPUT"))" >&2
    rm -f "$OUTPUT"
fi

# Encode to a temp file in the same directory and only publish it on success,
# so a crash or a kill can never leave a half-written video where the manifest
# can find it.
# Deliberately not *.part.mp4 — generate-manifest.sh matches on the .mp4
# extension and would publish a half-written file.
TMP="${OUTPUT}.part"
cleanup() { [[ -n "${TMP:-}" ]] && rm -f "$TMP"; }
trap cleanup EXIT

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
    ffmpeg -y -hide_banner -loglevel error -i "$INPUT" $T_ARGS \
        -c:v copy \
        -c:a aac -b:a 64k -ac 1 -ar 22050 \
        -movflags +faststart \
        -map_metadata -1 \
        -f mp4 "$TMP"
else
    # Transcode, tuned for a 10" 1280x800 panel with a weak ARM decoder.
    #   fastdecode — helps the weak Rockchip ARM decoder
    #   baseline   — widest Android WebView compatibility
    #   mono 64k   — frame has tiny/no speakers
    # Quality is set by the VIDEO_* vars above.
    ffmpeg -y -hide_banner -loglevel error -i "$INPUT" $T_ARGS \
        -vf "scale='min(${MAX_W},iw)':'min(${MAX_H},ih)':force_original_aspect_ratio=decrease" \
        -pix_fmt yuv420p \
        -c:v libx264 -profile:v baseline -level 3.1 \
        -preset veryfast -crf "$VIDEO_CRF" -tune fastdecode \
        -maxrate "$VIDEO_MAXRATE" -bufsize "$VIDEO_BUFSIZE" \
        -r "$VIDEO_FPS" \
        -c:a aac -b:a 64k -ac 1 -ar 22050 \
        -movflags +faststart \
        -map_metadata -1 \
        -f mp4 "$TMP"
fi

# Only a file that probes clean gets published under the real name.
if ! is_playable "$TMP"; then
    echo "encode produced an unplayable file: $(basename "$OUTPUT")" >&2
    exit 1
fi
mv -f "$TMP" "$OUTPUT"
TMP=""
