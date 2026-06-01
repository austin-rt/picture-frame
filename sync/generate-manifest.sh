#!/usr/bin/env bash
# Scan the photos directory and write manifest.json for the slideshow.
# Usage: generate-manifest.sh <photos_dir> <output_manifest>

set -euo pipefail

PHOTOS_DIR="$1"
MANIFEST="$2"

echo '[' > "$MANIFEST.tmp"

first=true
for f in "$PHOTOS_DIR"/*; do
    [[ -f "$f" ]] || continue
    filename=$(basename "$f")
    ext="${filename##*.}"
    ext_lower=$(echo "$ext" | tr 'A-Z' 'a-z')

    case "$ext_lower" in
        jpg) type="photo" ;;
        mp4) type="video" ;;
        *) continue ;;
    esac

    if $first; then
        first=false
    else
        echo ',' >> "$MANIFEST.tmp"
    fi
    printf '  {"filename": "%s", "type": "%s"}' "$filename" "$type" >> "$MANIFEST.tmp"
done

echo '' >> "$MANIFEST.tmp"
echo ']' >> "$MANIFEST.tmp"

mv "$MANIFEST.tmp" "$MANIFEST"
