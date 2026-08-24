#!/bin/sh
#
# Build and run the VideoToolbox session-count probe (ios/probe).
#
# Run from the repository root:
#
#     sh ios/make-probe.sh                      # simulator, 16 sessions
#     sh ios/make-probe.sh --sessions 24        # push past the grid size
#     sh ios/make-probe.sh --nv12               # skip the BGRA request
#     sh ios/make-probe.sh --device             # build, install and run on iPad
#     sh ios/make-probe.sh --build-only         # compile, do not launch
#     sh ios/make-probe.sh --device --team ABCDE12345
#     sh ios/make-probe.sh --device --udid <id> # pick among several iPads
#
# The simulator path needs no Apple Developer account, no provisioning and no
# device: a simulator bundle is ad-hoc signed and installed with simctl. That
# is what makes it useful today -- it proves the static FFmpeg links, that the
# RTSP connections work, and that the decode loop runs, before anyone plugs an
# iPad in.
#
# What the simulator cannot answer is the actual question. It has no
# VideoToolbox hardware decode at all -- every session falls back to software
# in system memory -- and it does not enforce the local-network privacy prompt
# that a real device will show. Treat a clean simulator run as "the plumbing
# works", never as "16 sessions are fine".
#
# The device path signs for real. It configures with the Xcode generator, the
# only one that can ask Apple for a provisioning profile, and builds with
# -allowProvisioningUpdates, which registers this iPad and creates the App ID
# and development profile on first run. That needs a Developer Program account
# already signed in to Xcode. Pass --team if the account has more than one.

set -e

ROOT=$(cd "$(dirname "$0")/.." && pwd)

TARGET=simulator
SESSIONS=16
RAMP=2
EXTRA_ARGS=""
BUILD_ONLY=no
TEAM="${DEVELOPMENT_TEAM:-}"
DEV_UDID=""
HW_UDID=""

# An iPad Pro is the closest simulator device type to the hardware in question.
# The runtime does the decoding either way, so this mostly affects the screen
# geometry the readout is laid out in.
SIM_DEVICE_TYPE="com.apple.CoreSimulator.SimDeviceType.iPad-Pro-13-inch-M4-16GB"
SIM_NAME="cctv-probe-ipad"

while [ $# -gt 0 ]; do
    case "$1" in
        --device)     TARGET=device ;;
        --simulator)  TARGET=simulator ;;
        --sessions)   SESSIONS="$2"; shift ;;
        --ramp)       RAMP="$2"; shift ;;
        --nv12)       EXTRA_ARGS="$EXTRA_ARGS --nv12" ;;
        --build-only) BUILD_ONLY=yes ;;
        --team)       TEAM="$2"; shift ;;
        --udid)       DEV_UDID="$2"; shift ;;
        -h|--help)    awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next }
                           NR > 1 { exit }' "$0"; exit 0 ;;
        *)            echo "unknown option: $1" >&2; exit 2 ;;
    esac
    shift
done

if [ "$TARGET" = device ]; then
    SDK=iphoneos
    FFMPEG_TARGET=ios-arm64
else
    SDK=iphonesimulator
    FFMPEG_TARGET=ios-arm64-simulator
fi

FFMPEG_PREFIX="$ROOT/build-ios/ffmpeg/prefix/$FFMPEG_TARGET"
BUILD="$ROOT/build-ios/probe-$TARGET"

# The device build uses the Xcode generator because it is the only one that can
# ask Apple for a provisioning profile. The simulator stays on Makefiles: a
# faster loop, and it needs no signing beyond ad-hoc. They put the built bundle
# in different places.
if [ "$TARGET" = device ]; then
    GENERATOR="Xcode"
    APP="$BUILD/Release-iphoneos/cctv-probe.app"
else
    GENERATOR="Unix Makefiles"
    APP="$BUILD/cctv-probe.app"
fi

[ -f "$FFMPEG_PREFIX/lib/libavcodec.a" ] || {
    echo "error: no FFmpeg for $FFMPEG_TARGET. Build it first:" >&2
    echo "    sh ios/make-ffmpeg.sh" >&2
    exit 1
}

# Regenerate on every run: it is cheap, and a stale list silently probes
# cameras that have since been renumbered.
sh "$ROOT/ios/probe/make-streams.sh"

# Which iPad has to be settled before the build, not after it. Automatic
# provisioning only adds a device to the team when xcodebuild is told to build
# for that device, and a profile generated without it simply omits it -- the
# build then succeeds and the install fails much later with "provisioning
# profile cannot be installed on this device".
#
# Two identifiers are in play and they are not interchangeable. The Identifier
# column from devicectl is a CoreDevice UUID; provisioning and -destination
# want the hardware UDID, which is a different string entirely.
if [ "$TARGET" = device ]; then
    if [ -z "$DEV_UDID" ]; then
        # The Identifier column is a UUID, so match on shape rather than field
        # position: the table's column widths follow the device name.
        DEV_UDID=$(xcrun devicectl list devices | awk '
            /connected/ { match($0, /[0-9A-F-]{36}/)
                          if (RSTART) { print substr($0, RSTART, RLENGTH); exit } }')
    fi
    if [ -n "$DEV_UDID" ]; then
        HW_UDID=$(xcrun devicectl device info details --device "$DEV_UDID" 2>/dev/null |
            awk '/. udid:/ { print $NF; exit }')
    fi
fi

# A build directory remembers which generator made it, and reconfiguring with
# a different one is a hard CMake error rather than a regeneration. The device
# path moved from Makefiles to Xcode, so a tree from before that has to go.
if [ -f "$BUILD/CMakeCache.txt" ] &&
   ! grep -qxF "CMAKE_GENERATOR:INTERNAL=$GENERATOR" "$BUILD/CMakeCache.txt"; then
    echo "==> generator changed, clearing $BUILD"
    rm -rf "$BUILD"
fi

SIGN_ARGS=""
if [ "$TARGET" = device ]; then
    # CMAKE_XCODE_GENERATE_SCHEME because xcodebuild ignores -destination
    # unless a scheme is passed, and without a destination
    # -allowProvisioningUpdates never learns which iPad to register.
    SIGN_ARGS="-DCMAKE_XCODE_GENERATE_SCHEME=ON"
    SIGN_ARGS="$SIGN_ARGS -DCMAKE_XCODE_ATTRIBUTE_CODE_SIGN_STYLE=Automatic"
    if [ -n "$TEAM" ]; then
        SIGN_ARGS="$SIGN_ARGS -DCMAKE_XCODE_ATTRIBUTE_DEVELOPMENT_TEAM=$TEAM"
    fi
fi

echo "==> configuring ($TARGET, $GENERATOR)"
# SIGN_ARGS is unquoted on purpose: it is a list of flags, and a Team ID is
# alphanumeric, so there is nothing here for the shell to split wrongly.
cmake -S "$ROOT/ios/probe" -B "$BUILD" -G "$GENERATOR" \
    -DCMAKE_SYSTEM_NAME=iOS \
    -DCMAKE_OSX_SYSROOT="$SDK" \
    -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=16.0 \
    -DCMAKE_BUILD_TYPE=Release \
    -DFFMPEG_PREFIX="$FFMPEG_PREFIX" \
    $SIGN_ARGS

echo "==> building"
if [ "$TARGET" = device ]; then
    # xcodebuild directly rather than cmake --build: -allowProvisioningUpdates
    # registers this iPad and reissues the profile to include it, but only when
    # -destination names it, and xcodebuild ignores a destination unless a
    # scheme is passed -- which cmake --build has no way to do. Getting this
    # wrong is quiet: the build succeeds, signs against a profile that
    # provisions some other device, and the install fails much later with
    # "provisioning profile cannot be installed on this device".
    if [ -n "$HW_UDID" ]; then
        DEST="id=$HW_UDID"
    else
        DEST="generic/platform=iOS"
        echo "    (no device connected: building $DEST, so provisioning will"
        echo "     not be updated for any particular iPad)"
    fi
    xcodebuild -project "$BUILD/cctv-probe.xcodeproj" \
        -scheme cctv-probe -configuration Release \
        -destination "$DEST" -allowProvisioningUpdates
else
    cmake --build "$BUILD" -j"$(sysctl -n hw.ncpu)"
fi

# Even a simulator bundle has to carry a signature; simctl rejects an unsigned
# one. Ad-hoc is all it needs, and it involves no account or certificate.
if [ "$TARGET" = simulator ]; then
    codesign --force --sign - --timestamp=none "$APP" >/dev/null 2>&1 || true
fi

echo "==> built $APP"

if [ "$TARGET" = device ]; then
    codesign -dv "$APP" 2>&1 | grep -E "^(Identifier|TeamIdentifier|Authority)" || true
fi

if [ "$BUILD_ONLY" = yes ]; then
    exit 0
fi

### Device run

if [ "$TARGET" = device ]; then
    [ -n "$DEV_UDID" ] || {
        echo "error: no connected device. Plug the iPad in and tap Trust, then:" >&2
        echo "    xcrun devicectl list devices" >&2
        exit 1
    }

    echo "==> installing on $DEV_UDID"
    xcrun devicectl device install app --device "$DEV_UDID" "$APP"

    echo "==> launching with --sessions $SESSIONS --ramp $RAMP$EXTRA_ARGS"
    echo "    (tap Allow on the local network prompt; ^C to stop)"
    xcrun devicectl device process launch --console --terminate-existing \
        --device "$DEV_UDID" org.cctv-viewer.probe \
        --sessions "$SESSIONS" --ramp "$RAMP" $EXTRA_ARGS
    exit 0
fi

### Simulator run

# Reuse one named simulator across runs so repeat runs do not accumulate
# devices, and so the local-network and privacy state stays put.
UDID=$(xcrun simctl list devices | awk -v name="$SIM_NAME" '
    $0 ~ name { match($0, /[0-9A-F-]{36}/); print substr($0, RSTART, RLENGTH); exit }')

if [ -z "$UDID" ]; then
    echo "==> creating simulator $SIM_NAME"
    RUNTIME=$(xcrun simctl list runtimes | awk '/iOS/ { print $NF; exit }')
    UDID=$(xcrun simctl create "$SIM_NAME" "$SIM_DEVICE_TYPE" "$RUNTIME")
fi

echo "==> booting $SIM_NAME ($UDID)"
xcrun simctl bootstatus "$UDID" -b >/dev/null 2>&1 || xcrun simctl boot "$UDID" || true
xcrun simctl bootstatus "$UDID" -b

echo "==> installing"
xcrun simctl install "$UDID" "$APP"

echo "==> launching with --sessions $SESSIONS --ramp $RAMP$EXTRA_ARGS"
echo "    (console output follows; ^C to stop)"
xcrun simctl launch --console-pty "$UDID" org.cctv-viewer.probe \
    --sessions "$SESSIONS" --ramp "$RAMP" $EXTRA_ARGS
