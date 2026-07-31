#!/bin/sh
#
# Package build/cctv-viewer.app into a drag-to-Applications disk image.
#
# Run from the repository root, after a build that has already been deployed and
# signed:
#
#     cmake --build build -j"$(sysctl -n hw.ncpu)"
#     "$(brew --prefix qt@5)/bin/macdeployqt" build/cctv-viewer.app -qmldir=.
#     codesign --force --deep --sign - build/cctv-viewer.app
#     sh macos/make-dmg.sh
#
# The bundle is copied as-is. This deliberately does not go through CMake's
# install() or CPack: both rewrite Mach-O load commands on the way out, which
# invalidates the signature step 3 above just applied, and an invalidated
# signature is a SIGKILL during dynamic linking rather than a warning. See
# BUILD-macos.md section 6.
#
# Writes two files:
#
#     build/CCTV-Viewer-<version>-<arch>.dmg
#     build/release-notes.md    (for the GitHub release body)
#
# Both describe first launch based on the signature actually found on the
# bundle, so the instructions can never contradict what the user downloads.
#
# Usage: sh macos/make-dmg.sh [version]
#   version defaults to the one in CMakeLists.txt.

set -e

APP="build/cctv-viewer.app"
VOLNAME="CCTV Viewer"

if [ ! -d "$APP" ]; then
    echo "$APP not found. Build it first, from the repository root." >&2
    exit 1
fi

# Refuse to ship a bundle whose signature does not verify: it would install fine
# and then be killed on launch.
if ! codesign --verify --deep --strict "$APP" 2>/dev/null; then
    echo "$APP has no valid signature." >&2
    echo "Run: codesign --force --deep --sign - $APP" >&2
    exit 1
fi

# macdeployqt copies Qt in. Without it the app only runs where Homebrew's Qt sits
# at the same path, which defeats the point of shipping a disk image.
if [ ! -d "$APP/Contents/Frameworks/QtCore.framework" ]; then
    echo "$APP has no bundled Qt frameworks." >&2
    echo "Run: \"\$(brew --prefix qt@5)/bin/macdeployqt\" $APP -qmldir=." >&2
    exit 1
fi

VERSION="$1"
if [ -z "$VERSION" ]; then
    MAJ=$(sed -n 's/^set(VER_MAJ \([0-9]*\))/\1/p' CMakeLists.txt)
    MIN=$(sed -n 's/^set(VER_MIN \([0-9]*\))/\1/p' CMakeLists.txt)
    PAT=$(sed -n 's/^set(VER_PAT \([0-9]*\))/\1/p' CMakeLists.txt)
    VERSION="${MAJ}.${MIN}.${PAT}"
fi

ARCH=$(uname -m)
OUT="build/CCTV-Viewer-${VERSION}-${ARCH}.dmg"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
STAGE="$TMP/stage"
mkdir -p "$STAGE"

# ditto rather than cp -R: it preserves extended attributes and the code
# signature directories intact.
ditto "$APP" "$STAGE/cctv-viewer.app"
ln -s /Applications "$STAGE/Applications"

### Wording shared between the disk image read-me and the release notes.

FIRST_LAUNCH="$TMP/first-launch.txt"
if codesign -dv "$APP" 2>&1 | grep -q "Authority=Developer ID Application"; then
    cat > "$FIRST_LAUNCH" <<'EOF'
This build is signed with an Apple Developer ID, so it opens by double-clicking
with no warning.
EOF
else
    cat > "$FIRST_LAUNCH" <<'EOF'
This build is signed ad-hoc rather than with an Apple Developer ID, so macOS
blocks it the first time and reports that it "cannot be opened because Apple
cannot check it for malicious software". The app is not damaged; macOS simply
cannot identify who built it.

To allow it, once per machine:

1. Double-click the app in Applications. The warning appears.
2. Open System Settings > Privacy & Security.
3. Scroll down to Security. There is a line about cctv-viewer being blocked,
   with an "Open Anyway" button next to it. Click that and confirm.

The app opens normally from then on. Or, equivalently, in Terminal:

    xattr -dr com.apple.quarantine /Applications/cctv-viewer.app
EOF
fi

LOCAL_NETWORK="$TMP/local-network.txt"
cat > "$LOCAL_NETWORK" <<'EOF'
On first connection macOS asks for Local Network access. This is required:
without it the app cannot reach cameras on your network, and every viewport sits
at "Loading..." with nothing to explain why. If the prompt gets dismissed by
accident, grant it under

    System Settings > Privacy & Security > Local Network
EOF

{
    echo "CCTV Viewer"
    echo "==========="
    echo
    echo 'To install: drag "cctv-viewer" onto the Applications folder in this'
    echo "window."
    echo
    echo "FIRST LAUNCH"
    echo "------------"
    echo
    cat "$FIRST_LAUNCH"
    echo
    echo "LOCAL NETWORK ACCESS"
    echo "--------------------"
    echo
    cat "$LOCAL_NETWORK"
} > "$STAGE/READ-ME-FIRST.txt"

{
    echo "## Install"
    echo
    echo "Open the disk image and drag **cctv-viewer** onto Applications."
    echo
    echo "Apple silicon (M1 and later) only."
    echo
    echo "## First launch"
    echo
    cat "$FIRST_LAUNCH"
    echo
    echo "## Local network access"
    echo
    cat "$LOCAL_NETWORK"
} > "build/release-notes.md"

### The image itself.

rm -f "$OUT"
hdiutil create \
    -volname "$VOLNAME" \
    -srcfolder "$STAGE" \
    -fs HFS+ \
    -format UDZO \
    -quiet \
    "$OUT"

hdiutil verify -quiet "$OUT"

echo "Wrote $OUT"
echo "Wrote build/release-notes.md"
