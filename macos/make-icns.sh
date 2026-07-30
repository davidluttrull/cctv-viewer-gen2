#!/bin/sh
#
# Build macos/cctv-viewer.icns from images/cctv-viewer.svg.
#
# Run once from the repository root:
#
#     sh macos/make-icns.sh
#
# CMake picks the result up automatically on the next configure. The .icns is a
# binary build artifact and is not committed, so re-run this after changing the
# source SVG.

set -e

SVG="images/cctv-viewer.svg"
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
# SVG itself, hence rsvg-convert, with QuickLook as a fallback.
if command -v rsvg-convert >/dev/null 2>&1; then
    rsvg-convert -w 1024 -h 1024 "$SVG" -o "$TMP/base.png"
elif command -v qlmanage >/dev/null 2>&1; then
    echo "rsvg-convert not found, falling back to qlmanage (lower quality)."
    echo "For a sharper icon: brew install librsvg"
    qlmanage -t -s 1024 -o "$TMP" "$SVG" >/dev/null 2>&1
    mv "$TMP"/*.png "$TMP/base.png"
else
    echo "Need rsvg-convert (brew install librsvg) or qlmanage." >&2
    exit 1
fi

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
