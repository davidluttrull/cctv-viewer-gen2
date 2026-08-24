#!/bin/sh
#
# Cross-compile the FFmpeg libraries qmlav needs as static archives for iOS.
#
# Run from the repository root:
#
#     sh ios/make-ffmpeg.sh                # device + simulator
#     sh ios/make-ffmpeg.sh --device       # arm64 iPhone/iPad only
#     sh ios/make-ffmpeg.sh --simulator    # arm64 simulator only
#     sh ios/make-ffmpeg.sh --force        # rebuild even if up to date
#
# Output, both gitignored:
#
#     build-ios/ffmpeg/prefix/ios-arm64/{lib,include}            device
#     build-ios/ffmpeg/prefix/ios-arm64-simulator/{lib,include}  simulator
#
# Why this exists at all: the macOS build gets FFmpeg from Homebrew as dylibs,
# and CMakeLists finds them with pkg-config. Neither half of that works here.
# Homebrew has no iOS bottles, and iOS forbids shipping your own dynamic
# libraries in an app bundle, so every dependency has to be a static archive
# linked into the executable. That means cross-compiling, which means this.
#
# The Android side of qmlav has the same problem and solves it with
# src/qmlav/3rd/prebuild_ffmpeg.sh against the FFmpeg submodule. This script
# deliberately does *not* reuse that submodule: it is pinned at n5.1.3, while
# the macOS build compiles against Homebrew's 8.1.2, and the VideoToolbox
# output module on the `videotoolbox` branch is written against the 8.x API
# (av_map_videotoolbox_format_from_pixfmt2 and the hwcontext_videotoolbox
# header in qmlavdecoder.cpp). Building iOS against 5.1 would mean maintaining
# two dialects of qmlav at once. So this clones its own copy at the tag below,
# and leaves the submodule pin alone for Android.
#
# Consequence to be aware of: FFMPEG_TAG must track whatever the Mac builds
# against. If Homebrew moves to 8.2 and qmlav starts using something new, bump
# it here too, or iOS silently compiles against an older API than macOS does.

set -e

# Matches Homebrew's ffmpeg 8.1.2 that the macOS build links today.
FFMPEG_TAG="${FFMPEG_TAG:-n8.1.2}"

# FFmpeg's own canonical repository rather than the GitHub mirror. This project
# is kept in house, and there is no reason for a build to depend on GitHub being
# up or on an account having access to it. Verified equivalent, not assumed:
# git.ffmpeg.org and GitHub both serve n8.1.2 as 1c2c67c0b9f7f66ab32c19dcf7f227bcd290aa4c.
FFMPEG_REMOTE="${FFMPEG_REMOTE:-https://git.ffmpeg.org/ffmpeg.git}"

# Any iPad that can run iPadOS 16 is a 2017 device or newer, and Qt 6.8 LTS
# requires 16 regardless. Static archives built for 16.0 link fine into an app
# with a higher deployment target, so this is a floor, not a commitment. Recent
# Xcode SDKs refuse deployment targets much below this.
IOS_MIN="${IOS_MIN:-16.0}"

ROOT=$(cd "$(dirname "$0")/.." && pwd)
WORK="$ROOT/build-ios/ffmpeg"
SRC="$WORK/src"

BUILD_DEVICE=yes
BUILD_SIMULATOR=yes
FORCE=no

for arg in "$@"; do
    case "$arg" in
        --device)    BUILD_SIMULATOR=no ;;
        --simulator) BUILD_DEVICE=no ;;
        --force)     FORCE=yes ;;
        -h|--help)   sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *)           echo "unknown option: $arg" >&2; exit 2 ;;
    esac
done

### Preflight
#
# Every check here is a failure that otherwise surfaces thousands of lines
# later as something unrecognisable.

# The three most likely reasons this fails on a fresh machine, in the order
# they bite. Each one otherwise surfaces much later as something that looks
# unrelated -- an unaccepted licence, for instance, makes the git clone below
# fail with a message about Xcode, which is baffling in a script that has not
# mentioned Xcode yet.
DEVDIR=$(xcode-select -p 2>/dev/null || true)
case "$DEVDIR" in
    *Xcode*) ;;
    *)
        echo "error: full Xcode is required to build for iOS." >&2
        echo "  xcode-select -p reports: ${DEVDIR:-nothing}" >&2
        echo "  Command Line Tools alone has no iOS SDK." >&2
        echo "  Install Xcode from the App Store, then:" >&2
        echo "    sudo xcode-select -s /Applications/Xcode.app/Contents/Developer" >&2
        echo "    sudo xcodebuild -license accept" >&2
        exit 1
        ;;
esac

# One probe answers the two remaining questions, because an unaccepted licence
# and a missing iOS platform both make xcrun fail, just with different
# messages. This has to come before the clone: until the licence is accepted,
# /usr/bin/git is a shim that refuses to run at all.
SDK_PROBE=$(xcrun --sdk iphoneos --show-sdk-path 2>&1 || true)

case "$SDK_PROBE" in
    *license*|*licence*)
        echo "error: the Xcode license has not been accepted." >&2
        echo "  Until it is, even git refuses to run. In a terminal:" >&2
        echo "    sudo xcodebuild -license accept" >&2
        exit 1
        ;;
esac

# Xcode 15 and later do not bundle the platform SDKs inside Xcode.app; the iOS
# one is a separate download of several GB. A 3-4GB Xcode.app is the tell.
if [ ! -d "$SDK_PROBE" ]; then
    echo "error: no iOS SDK found." >&2
    echo "  xcrun --sdk iphoneos --show-sdk-path said:" >&2
    echo "    $SDK_PROBE" >&2
    echo "  Install the iOS platform (several GB):" >&2
    echo "    xcodebuild -downloadPlatform iOS" >&2
    exit 1
fi

for tool in git make clang lipo vtool ar; do
    command -v "$tool" >/dev/null 2>&1 || {
        echo "error: $tool not found in PATH" >&2
        exit 1
    }
done

### Source
#
# A shallow clone at one tag: ~60MB against ~500MB for FFmpeg's full history,
# and nothing here ever needs to bisect it. Re-clone if FFMPEG_TAG changed,
# because a shallow clone cannot simply check out a tag it never fetched.
if [ -d "$SRC/.git" ]; then
    HAVE=$(git -C "$SRC" describe --tags --exact-match 2>/dev/null || echo unknown)
    if [ "$HAVE" != "$FFMPEG_TAG" ]; then
        echo "==> source is at $HAVE, want $FFMPEG_TAG -- re-cloning"
        rm -rf "$SRC"
    fi
fi

if [ ! -d "$SRC/.git" ]; then
    echo "==> cloning FFmpeg $FFMPEG_TAG"
    mkdir -p "$(dirname "$SRC")"
    git clone --depth 1 --branch "$FFMPEG_TAG" \
        "$FFMPEG_REMOTE" "$SRC"
fi

### Build
#
# build_target <name> <sdk> <version-min-flag>
build_target() {
    NAME="$1"
    SDK="$2"
    MINFLAG="$3"

    PREFIX="$WORK/prefix/$NAME"
    BUILDDIR="$WORK/build/$NAME"
    STAMP="$PREFIX/.build-stamp"
    SDKPATH=$(xcrun --sdk "$SDK" --show-sdk-path)
    SDKVER=$(xcrun --sdk "$SDK" --show-sdk-version)

    # What the output depends on. If any of it moves -- a new FFmpeg tag, a new
    # deployment target, an Xcode upgrade that changed the SDK -- the cached
    # archives are stale and get rebuilt. Xcode upgrades are the sneaky one:
    # the libraries still link, then fail at runtime or refuse to notarise.
    WANT="$FFMPEG_TAG $IOS_MIN $SDK $SDKVER"

    if [ "$FORCE" = no ] && [ -f "$STAMP" ] && [ "$(cat "$STAMP")" = "$WANT" ]; then
        echo "==> $NAME is up to date ($WANT)"
        return 0
    fi

    echo "==> building $NAME (SDK $SDK $SDKVER, min iOS $IOS_MIN)"

    FLAGS="-arch arm64 -isysroot $SDKPATH $MINFLAG$IOS_MIN"

    rm -rf "$BUILDDIR"
    mkdir -p "$BUILDDIR" "$PREFIX"
    cd "$BUILDDIR"

    # Out-of-tree build, so device and simulator never share object files --
    # they are both arm64 and the collision is invisible until link time.
    #
    # --disable-autodetect is the important one. We are cross-compiling on a
    # Mac that has Homebrew's x264, openssl, lame and a dozen others installed;
    # without this, configure probes the host, finds them, and produces
    # archives that reference libraries no iPad will ever have. It also means
    # anything we do want must be named explicitly, hence --enable-videotoolbox
    # and --enable-zlib (zlib ships inside the iOS SDK).
    #
    # Not pruned, deliberately: codecs, muxers, demuxers and protocols are left
    # at their defaults. A viewer needs no encoders and one muxer, but the
    # dependency graph is not obvious -- the RTSP demuxer selects the RTP
    # *muxer*, so a plain --disable-muxers breaks the entire point of the app,
    # and the failure looks like a network problem. The cost is roughly 25MB of
    # archive that the linker mostly discards. Prune later, with a device to
    # test on, not now.
    #
    # avdevice stays enabled because qmlavdemuxer.cpp calls
    # avdevice_register_all() unconditionally; disabling it here means patching
    # qmlav. Its iOS input is AVFoundation capture, which we never open.
    "$SRC/configure" \
        --prefix="$PREFIX" \
        --enable-cross-compile \
        --target-os=darwin \
        --arch=arm64 \
        --sysroot="$SDKPATH" \
        --cc="$(xcrun --sdk "$SDK" --find clang)" \
        --extra-cflags="$FLAGS" \
        --extra-cxxflags="$FLAGS" \
        --extra-ldflags="$FLAGS" \
        --enable-static \
        --disable-shared \
        --enable-pic \
        --disable-autodetect \
        --enable-videotoolbox \
        --enable-zlib \
        --enable-network \
        --disable-programs \
        --disable-doc \
        --disable-debug

    make -j"$(sysctl -n hw.ncpu)"
    make install

    echo "$WANT" > "$STAMP"
    cd "$ROOT"
}

if [ "$BUILD_DEVICE" = yes ]; then
    build_target ios-arm64 iphoneos -mios-version-min=
fi

if [ "$BUILD_SIMULATOR" = yes ]; then
    build_target ios-arm64-simulator iphonesimulator -mios-simulator-version-min=
fi

### Verify
#
# Device and simulator archives are both arm64, so `lipo -archs` reports the
# same thing for both and cannot tell them apart. The platform is recorded in
# each object's LC_BUILD_VERSION instead, and mixing them up is the classic
# iOS static-library failure: the link succeeds, then Xcode refuses to install,
# or the app dies on launch. Read the real platform out and insist on it.
verify_target() {
    NAME="$1"
    WANT_PLATFORM="$2"
    PREFIX="$WORK/prefix/$NAME"
    LIB="$PREFIX/lib/libavcodec.a"

    [ -f "$LIB" ] || { echo "  $NAME: MISSING $LIB" >&2; return 1; }

    ARCHS=$(lipo -archs "$LIB" 2>/dev/null || echo "?")

    TMP=$(mktemp -d)
    (cd "$TMP" && ar x "$LIB" && OBJ=$(ls ./*.o 2>/dev/null | head -1) &&
        vtool -show-build-version "$OBJ" 2>/dev/null > platform.txt) || true
    GOT=$(sed -n 's/.*platform *\([A-Z]*\).*/\1/p' "$TMP/platform.txt" 2>/dev/null | head -1)
    rm -rf "$TMP"

    SIZE=$(du -sh "$PREFIX/lib" | cut -f1)
    echo "  $NAME: archs=$ARCHS platform=${GOT:-unknown} libs=$SIZE"

    if [ -n "$GOT" ] && [ "$GOT" != "$WANT_PLATFORM" ]; then
        echo "  $NAME: ERROR expected platform $WANT_PLATFORM, got $GOT" >&2
        return 1
    fi
}

echo
echo "==> verifying"
RC=0
[ "$BUILD_DEVICE" = yes ]    && { verify_target ios-arm64 IOS || RC=1; }
[ "$BUILD_SIMULATOR" = yes ] && { verify_target ios-arm64-simulator IOSSIMULATOR || RC=1; }
[ "$RC" = 0 ] || { echo "verification failed" >&2; exit 1; }

cat <<EOF

FFmpeg $FFMPEG_TAG is built. Point a build at it with, for the device:

    -DFFMPEG_PREFIX=$WORK/prefix/ios-arm64

The iOS branch of CMakeLists takes include/ and lib/ from there directly, the
way the Android branch does, rather than through pkg-config -- pkg-config on a
cross build reports the host's FFmpeg, which is exactly what we just went to
some trouble to avoid.
EOF
