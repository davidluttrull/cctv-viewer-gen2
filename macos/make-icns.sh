#!/bin/sh
#
# Build macos/cctv-viewer.icns from macos/appicon.svg.
#
# Run once from the repository root:
#
#     sh macos/make-icns.sh
#
# CMake picks the result up automatically on the next configure. The .icns is a
# binary build artifact and is not committed, so re-run this after changing the
# source SVG.
#
# The source is the macOS-specific icon, not images/cctv-viewer.svg: this one is
# drawn on Apple's icon grid (an 824x824 rounded square in a 1024 canvas) so it
# sits correctly among system icons in the Dock.

set -e

SVG="macos/appicon.svg"
OUT="macos/cctv-viewer.icns"

if [ ! -f "$SVG" ]; then
    echo "$SVG not found. Run this from the repository root." >&2
    exit 1
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
ICONSET="$TMP/cctv-viewer.iconset"
mkdir -p "$ICONSET"

# Rasterize once at the largest size, then downscale with sips. sips cannot read
# SVG itself, hence rsvg-convert.
#
# There is deliberately no qlmanage fallback. It renders SVG onto an opaque white
# background rather than preserving alpha, which bakes a white square around the
# rounded corners - obvious in the Dock, and invisible in the script's output.
if ! command -v rsvg-convert >/dev/null 2>&1; then
    echo "rsvg-convert not found. Install it with: brew install librsvg" >&2
    exit 1
fi

rsvg-convert -w 1024 -h 1024 "$SVG" -o "$TMP/base.png"

# iconutil expects both 1x and 2x at each size.
for SIZE in 16 32 128 256 512; do
    sips -z "$SIZE" "$SIZE" "$TMP/base.png" \
        --out "$ICONSET/icon_${SIZE}x${SIZE}.png" >/dev/null
    sips -z "$((SIZE * 2))" "$((SIZE * 2))" "$TMP/base.png" \
        --out "$ICONSET/icon_${SIZE}x${SIZE}@2x.png" >/dev/null
done

mkdir -p macos
iconutil -c icns "$ICONSET" -o "$OUT"

echo "Wrote $OUT"
