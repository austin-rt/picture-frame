#!/usr/bin/env bash
# Check status of all frames over Tailscale SSH.
# Usage: ./status.sh
# Add frames to the FRAMES array below.

FRAMES=(
    # "name:tailscale-ip"
    # "grandma:100.x.y.z"
)

if [[ ${#FRAMES[@]} -eq 0 ]]; then
    echo "No frames configured. Edit FRAMES array in status.sh."
    exit 1
fi

for entry in "${FRAMES[@]}"; do
    name="${entry%%:*}"
    host="${entry##*:}"
    echo "=== $name ($host) ==="
    ssh -o ConnectTimeout=5 "$host" '
        echo "  Uptime: $(uptime)"
        echo "  Photos: $(ls ~/frame-data/photos/*.jpg 2>/dev/null | wc -l) synced"
        echo "  Last sync: $(tail -1 ~/frame-data/sync.log 2>/dev/null)"
        echo "  Disk: $(df -h ~/frame-data 2>/dev/null | tail -1)"
    ' 2>/dev/null || echo "  OFFLINE"
    echo ""
done
