#!/usr/bin/env bash
# Scan the photos directory and write manifest.json for the slideshow.
# Usage: generate-manifest.sh <photos_dir> <output_manifest>

set -euo pipefail

PHOTOS_DIR="$1"
MANIFEST="$2"

echo '[' > "$MANIFEST.tmp"

first=true
for f in "$PHOTOS_DIR"/*.jpg; do
    [[ -f "$f" ]] || continue
    filename=$(basename "$f")
    if $first; then
        first=false
    else
        echo ',' >> "$MANIFEST.tmp"
    fi
    printf '  {"filename": "%s"}' "$filename" >> "$MANIFEST.tmp"
done

echo '' >> "$MANIFEST.tmp"
echo ']' >> "$MANIFEST.tmp"

mv "$MANIFEST.tmp" "$MANIFEST"
