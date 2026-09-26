#!/bin/bash
# Resources/icon.svg -> Resources/SpotVibe.icns
#
# Needs rsvg-convert (brew install librsvg). The .icns is COMMITTED, so this only runs
# when the artwork changes — `make app` just copies the result and builds on a machine
# without librsvg.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
svg="$root/Resources/icon.svg"
icns="$root/Resources/SpotVibe.icns"
set="$(mktemp -d)/SpotVibe.iconset"
mkdir -p "$set"

command -v rsvg-convert >/dev/null || { echo "need rsvg-convert: brew install librsvg" >&2; exit 1; }

python3 "$root/Tools/icon.py"

# The sizes iconutil expects. Every one is rendered FROM THE VECTOR rather than
# downsampled from 1024, so the rim stays a clean line at 16pt instead of a grey smear.
for size in 16 32 128 256 512; do
    rsvg-convert -w "$size"           -h "$size"           "$svg" -o "$set/icon_${size}x${size}.png"
    rsvg-convert -w "$((size * 2))"   -h "$((size * 2))"   "$svg" -o "$set/icon_${size}x${size}@2x.png"
done

iconutil -c icns "$set" -o "$icns"
rm -rf "$(dirname "$set")"
echo "wrote $icns"
