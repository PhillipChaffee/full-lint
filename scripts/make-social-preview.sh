#!/usr/bin/env bash
# Regenerates assets/social-preview.png from assets/social-preview.svg.
# Renders with headless Chrome at the SVG's exact 1280x640 — qlmanage
# force-fits SVGs into a square canvas, which shifted and truncated the
# card. Verifies the raster before it replaces the previous PNG: a render
# that misses 1280x640 or 1 MiB leaves the old file untouched.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

if [[ $# -gt 0 ]]; then
	echo "usage: scripts/make-social-preview.sh (takes no arguments)" >&2
	exit 1
fi

chrome="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
svg="assets/social-preview.svg"
png="assets/social-preview.png"
new="assets/.social-preview.tmp.png"

if [[ ! -f "$svg" ]]; then
	echo "FAIL: $svg not found" >&2
	exit 1
fi
if [[ ! -x "$chrome" ]]; then
	echo "FAIL: $chrome not found — install Google Chrome to render" >&2
	exit 1
fi

if ! out="$("$chrome" --headless --disable-gpu --hide-scrollbars --force-device-scale-factor=1 --window-size=1280,640 --screenshot="$PWD/$new" "file://$PWD/$svg" 2>&1)"; then
	rm -f "$new"
	echo "FAIL: Chrome could not render $svg" >&2
	echo "$out" >&2
	exit 1
fi
if [[ ! -f "$new" ]]; then
	echo "FAIL: Chrome wrote no screenshot for $svg" >&2
	echo "$out" >&2
	exit 1
fi

# Chrome sizes the raster to --window-size, but the check stays: sips reads
# the real pixel size of what landed on disk.
if ! dims="$(sips -g pixelWidth -g pixelHeight "$new" 2>/dev/null | awk '/pixelWidth/ { w = $2 } /pixelHeight/ { h = $2 } END { print w + 0, h + 0 }')"; then
	rm -f "$new"
	echo "FAIL: sips could not read $new" >&2
	exit 1
fi
read -r width height <<<"$dims"
if [[ "$width" != "1280" || "$height" != "640" ]]; then
	rm -f "$new"
	echo "FAIL: render is ${width}x${height}, want 1280x640" >&2
	exit 1
fi

if ! size="$(stat -f %z "$new")"; then
	rm -f "$new"
	echo "FAIL: could not stat $new" >&2
	exit 1
fi
if ((size >= 1048576)); then
	rm -f "$new"
	echo "FAIL: render is $size bytes, must stay under 1048576" >&2
	exit 1
fi

mv -f "$new" "$png"
echo "OK $png ${width}x${height} $size bytes"
