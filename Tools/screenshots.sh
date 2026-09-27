#!/bin/bash
# Rebuilds the README screenshots: docs/screenshots/*.png
#
#     make screenshots
#
# Each shot is the real app, launched with SPOTVIBE_DEMO and captured by screencapture at
# the display's native (Retina) resolution. Tools/backdrop.swift covers the desktop first,
# so the glass has something neutral to refract and nothing private ends up in the frame.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
out="$root/docs/screenshots"
mkdir -p "$out"

# Logical screen size, to centre the capture on the panel.
read -r width height <<<"$(osascript -e 'tell application "Finder" to get bounds of window of desktop' \
    | awk -F', ' '{print $3, $4}')"
panel=866          # RootView.panelSize.width
margin=44          # a little backdrop around the glass
x=$(( (width - panel) / 2 - margin ))
w=$(( panel + margin * 2 ))

swift build >/dev/null
binary="$root/.build/debug/spotvibe"

# Armed BEFORE the backdrop starts: a Ctrl-C in the window between launching it and
# arming the trap would leave a borderless full-screen window on every display, owned by
# an agent app with no Dock icon and no way to close it but a terminal.
backdrop=""
cleanup() {
    # `|| true` on both: under `set -e` a pkill that finds nothing left to kill would
    # abort the trap and fail the whole run after every shot was already written.
    if [ -n "$backdrop" ]; then kill "$backdrop" 2>/dev/null || true; fi
    pkill -f '\.build/debug/spotvibe' 2>/dev/null || true
}
trap cleanup EXIT INT TERM

swift "$root/Tools/backdrop.swift" &
backdrop=$!
# The backdrop must be up before the panel, or the first shot catches the desktop.
sleep 2.5

# name | SPOTVIBE_DEMO | top | height — the panel's glass starts 188pt down the screen.
shots=(
    "browse|1|150|600"
    "search|cal|150|640"
    "settings|settings|150|420"
)

for shot in "${shots[@]}"; do
    IFS='|' read -r name demo top tall <<<"$shot"
    SPOTVIBE_DEMO="$demo" "$binary" >/dev/null 2>&1 &
    sleep 2
    screencapture -x -R"$x,$top,$w,$tall" "$out/$name.png"
    pkill -f '\.build/debug/spotvibe' || true
    sleep 0.6
    echo "wrote $out/$name.png"
done
