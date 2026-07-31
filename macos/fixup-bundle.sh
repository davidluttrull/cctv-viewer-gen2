#!/bin/sh
#
# Repair a macdeployqt'd cctv-viewer.app so that it runs on a Mac without
# Homebrew, and verify that it will.
#
# Run from the repository root, after macdeployqt and *before* codesign:
#
#     cmake --build build -j"$(sysctl -n hw.ncpu)"
#     "$(brew --prefix qt@5)/bin/macdeployqt" build/cctv-viewer.app -qmldir=.
#     sh macos/fixup-bundle.sh
#     codesign --force --deep --sign - build/cctv-viewer.app
#
# The order matters both ways: this script rewrites Mach-O load commands, which
# invalidates any signature already on the bundle, and an invalidated signature
# is a SIGKILL during dynamic linking rather than a warning. So it must come
# after macdeployqt and before codesign, every time.
#
# macdeployqt only takes responsibility for Qt's own libraries. It copies the
# non-Qt dependencies it finds (FFmpeg, OpenSSL, the codecs) into
# Contents/Frameworks and rewrites the *app's* references to them, but it does
# not rewrite the references those libraries make to *each other*. The FFmpeg
# libraries depend on each other heavily, so libavformat, libavcodec,
# libavfilter, libavdevice, libswscale and libswresample all shipped through
# v0.1.11 still naming the build machine's absolute path:
#
#     /opt/homebrew/Cellar/ffmpeg/8.1.2_1/lib/libavutil.60.dylib
#
# On the build machine dyld resolves that by coincidence, because Homebrew's
# FFmpeg really is installed there. On any other Mac it does not exist, and the
# process is killed before it draws a window -- it bounces once in the Dock and
# disappears. That is the whole of the "fresh installs do not launch" bug, and
# it is invisible to every test performed on the machine that built the bundle.
#
# Rather than patch those six libraries by name, this walks every Mach-O in the
# bundle and repoints any dependency that resolves outside it, so the next
# vendored library to arrive is covered without anyone remembering to do this
# again. The verify pass at the end is the part that matters: it fails the
# build instead of shipping a bundle that only works here.
#
# Usage: sh macos/fixup-bundle.sh [--verify-only] [path-to-.app]
#   --verify-only   report problems without modifying the bundle. Used by
#                   make-dmg.sh, which runs after codesign and so must not
#                   touch a byte of the bundle it is about to package.

set -e

VERIFY_ONLY=no
if [ "$1" = "--verify-only" ]; then
    VERIFY_ONLY=yes
    shift
fi

APP="${1:-build/cctv-viewer.app}"
FRAMEWORKS="$APP/Contents/Frameworks"
IMAGEFORMATS="$APP/Contents/PlugIns/imageformats"

if [ ! -d "$APP" ]; then
    echo "$APP not found. Build it first, from the repository root." >&2
    exit 1
fi

if [ ! -d "$FRAMEWORKS/QtCore.framework" ]; then
    echo "$APP has no bundled Qt frameworks." >&2
    echo "Run: \"\$(brew --prefix qt@5)/bin/macdeployqt\" $APP -qmldir=." >&2
    exit 1
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
PROBLEMS="$WORK/problems"
: > "$PROBLEMS"

### Helpers.

# Every Mach-O file in the bundle: the executable, the frameworks, and the
# plugins. Driven by content rather than by a list of directories so that a
# plugin category macdeployqt starts copying tomorrow is covered today.
macho_files() {
    find "$APP/Contents" -type f -print | while read -r f; do
        if file -b "$f" 2>/dev/null | grep -q '^Mach-O'; then
            printf '%s\n' "$f"
        fi
    done
}

# The load-time dependencies of a Mach-O file, one per line.
#
# For a dylib, the first line of "otool -L" is the library's own install-name
# ID, not a dependency. Qt's plugins all keep an ID naming the Homebrew
# original -- macdeployqt does not rewrite them, and nothing needs it to, since
# plugins are loaded by explicit path rather than through their ID. Dropping
# that line here is what stops the verify pass below from failing on around
# fifty entries that are all completely harmless.
deps_of() {
    id=$(otool -D "$1" 2>/dev/null | sed -n '2p')
    otool -L "$1" 2>/dev/null | tail -n +2 |
        sed 's/ (compatibility version.*//; s/^[[:space:]]*//' |
        while read -r dep; do
            if [ -z "$dep" ]; then
                continue
            fi
            if [ "$dep" = "$id" ]; then
                continue
            fi
            printf '%s\n' "$dep"
        done
}

# Whether a dependency resolves outside the bundle. Absolute paths into the OS
# are fine -- every Mac has those. Anything already expressed relative to the
# executable or the loader has been dealt with.
is_external() {
    case "$1" in
        /usr/lib/*|/System/*|@executable_path/*|@loader_path/*|@rpath/*)
            return 1 ;;
    esac
    return 0
}

# Where a dependency should point instead, if the bundle already carries a copy
# of it. Empty output means it does not, which is a genuine missing library
# rather than a path that needs rewriting.
bundled_replacement() {
    dep="$1"

    name="${dep##*/}"
    if [ -f "$FRAMEWORKS/$name" ]; then
        printf '@executable_path/../Frameworks/%s\n' "$name"
        return
    fi

    # Frameworks need the whole QtFoo.framework/Versions/5/QtFoo tail kept, not
    # just the leaf, or the rewritten path names a file that is not there.
    case "$dep" in
        */*.framework/*)
            suffix=$(printf '%s\n' "$dep" |
                sed 's|.*/\([^/][^/]*\.framework/\)|\1|')
            if [ -f "$FRAMEWORKS/$suffix" ]; then
                printf '@executable_path/../Frameworks/%s\n' "$suffix"
            fi
            ;;
    esac
}

### The SVG image plugin.
#
# QML's Image{} decodes an SVG through the QImageReader plugin in
# imageformats/, which is a different plugin from the QIcon icon engine in
# iconengines/libqsvgicon.dylib. Every icon in the sidebar and the preset bar
# is an .svg out of the .qrc, so without it they all silently fail to decode:
#
#     QML Image: Error decoding: qrc:/images/play.svg: Unsupported image format
#
# macdeployqt does deploy it here, and did for the v0.1.9 image, so this is
# normally a no-op. It is checked anyway because macdeployqt only deploys it
# when it has already decided QtSvg is in use, which it infers from the QML
# scan -- a decision that can quietly go the other way on a different machine
# or a different Qt, and the failure mode is cosmetic enough to ship unnoticed.

if [ ! -f "$IMAGEFORMATS/libqsvg.dylib" ]; then
    if [ "$VERIFY_ONLY" = yes ]; then
        echo "missing: PlugIns/imageformats/libqsvg.dylib" >> "$PROBLEMS"
    else
        QT_PREFIX="$(brew --prefix qt@5 2>/dev/null || true)"
        if [ -n "$QT_PREFIX" ] && [ -x "$QT_PREFIX/bin/qmake" ]; then
            QMAKE="$QT_PREFIX/bin/qmake"
        else
            QMAKE=qmake
        fi
        SRC="$("$QMAKE" -query QT_INSTALL_PLUGINS)/imageformats/libqsvg.dylib"
        if [ ! -f "$SRC" ]; then
            echo "$SRC not found. Is QtSvg installed?" >&2
            exit 1
        fi
        echo "Bundling missing libqsvg.dylib"
        mkdir -p "$IMAGEFORMATS"
        cp "$SRC" "$IMAGEFORMATS/libqsvg.dylib"
        # Its QtSvg/QtWidgets/QtGui/QtCore references are repointed by the loop
        # below along with everything else.
    fi
fi

### Repoint every dependency that resolves outside the bundle.

if [ "$VERIFY_ONLY" = no ]; then
    CHANGED=0
    macho_files | while read -r target; do
        deps_of "$target" | while read -r dep; do
            if ! is_external "$dep"; then
                continue
            fi
            replacement=$(bundled_replacement "$dep")
            if [ -n "$replacement" ]; then
                # Every one of these warns that it invalidates the signature,
                # which is expected and is why codesign runs after this script.
                install_name_tool -change "$dep" "$replacement" "$target" 2>&1 |
                    grep -v 'will invalidate the code signature' >&2 || true
                echo "  ${target#$APP/Contents/}: ${dep##*/}" >> "$WORK/changed"
            fi
        done
    done
    if [ -f "$WORK/changed" ]; then
        CHANGED=$(wc -l < "$WORK/changed" | tr -d ' ')
        echo "Repointed $CHANGED reference(s) into the bundle:"
        sort -u "$WORK/changed"
    else
        echo "No references needed repointing."
    fi
fi

### Verify.
#
# Anything still resolving outside the bundle is a library this Mac happens to
# have and the user's may not, so it is a launch failure waiting to happen.

macho_files | while read -r target; do
    deps_of "$target" | while read -r dep; do
        if is_external "$dep"; then
            echo "external: ${target#$APP/Contents/} -> $dep" >> "$PROBLEMS"
        fi
    done
done

if [ ! -f "$IMAGEFORMATS/libqsvg.dylib" ] && [ "$VERIFY_ONLY" = no ]; then
    echo "missing: PlugIns/imageformats/libqsvg.dylib" >> "$PROBLEMS"
fi

if [ -s "$PROBLEMS" ]; then
    echo >&2
    echo "$APP is not self-contained:" >&2
    sort -u "$PROBLEMS" >&2
    echo >&2
    echo "It would launch on this Mac and fail on one without Homebrew." >&2
    if [ "$VERIFY_ONLY" = yes ]; then
        echo "Run: sh macos/fixup-bundle.sh $APP" >&2
        echo "then re-sign: codesign --force --deep --sign - $APP" >&2
    fi
    exit 1
fi

echo "$APP is self-contained."
if [ "$VERIFY_ONLY" = no ]; then
    echo "Now re-sign it: codesign --force --deep --sign - $APP"
fi
