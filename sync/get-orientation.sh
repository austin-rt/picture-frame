#!/bin/sh
# Read EXIF orientation from JPEG. Prints orientation (1-8).
FILE="$1"
busybox hexdump -v -e '1/1 "%02x"' -n 500 "$FILE" 2>/dev/null | busybox grep -o "011200030000000100.." | busybox tail -c 3 | busybox head -c 2 | xargs printf "%d\n" 2>/dev/null || echo 1
