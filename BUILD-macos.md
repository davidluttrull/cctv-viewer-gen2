# Building CCTV Viewer on macOS

Everything below has to happen on the Mac itself — there is no cross-compile
path from Windows or Linux.

## 1. Clone with submodules

```sh
git clone --recurse-submodules https://github.com/davidluttrull/cctv-viewer-stretch.git
cd cctv-viewer-stretch
git checkout macos-build
```

The `--recurse-submodules` matters: `src/qmlav` is a submodule pointing at
`iEvgeny/qmlav`, and the build fails without it. If you already cloned without
it, run `git submodule update --init --recursive`.

## 2. Dependencies

```sh
brew install cmake pkg-config ffmpeg qt@5
```

Qt 5 rather than Qt 6 because `CMakeLists.txt` asks for the `QuickCompiler`
component, which only exists in Qt 5. Qt 6 folds that functionality in under a
different name, so a Qt 6 build needs that `find_package` line reworked as well.

## 3. Configure and build

```sh
cmake -S . -B build \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_PREFIX_PATH="$(brew --prefix qt@5)" \
  -DPKG_CONFIG_PATH="$(brew --prefix ffmpeg)/lib/pkgconfig"

cmake --build build -j"$(sysctl -n hw.ncpu)"
```

`Release` is deliberate — the `Debug` configuration turns on `-Werror`, and
while this branch moves the three GCC-only warning flags that Apple clang
rejects outright behind a compiler check, the remaining strict set has not been
tested against clang and will likely surface fresh errors in the FFmpeg-facing
code.

## 4. Bundle it

```sh
"$(brew --prefix qt@5)/bin/macdeployqt" build/cctv-viewer.app \
  -qmldir=. -dmg
```

`-qmldir=.` is required so `macdeployqt` walks the QML files and pulls in the
Qt Quick modules the app imports at runtime. Without it the binary launches to
a blank window and complains about missing modules on stderr. The FFmpeg dylibs
from Homebrew get copied and rewritten by the same command.

Unsigned bundles are fine locally, but Gatekeeper will block the app on any
other Mac unless you sign and notarize it with a Developer ID.

## What is not solved

**Software decoding only.** The hardware path in `src/qmlav/src/qmlavhwoutput.cpp`
is VA-API plus GLX, wrapped in `#if defined(__linux__)`, so it compiles out
entirely on macOS. Every stream is decoded on the CPU. One or two cameras is
fine on Apple silicon; a full grid of 1080p streams will not be.

The fix is a `QmlAVHWOutput` implementation backed by VideoToolbox — FFmpeg
already supports `AV_HWDEVICE_TYPE_VIDEOTOOLBOX` and hands back
`AV_PIX_FMT_VIDEOTOOLBOX` frames carrying a `CVPixelBuffer`, which maps to a
Metal or OpenGL texture without a round trip through system memory. That is a
new source file and a change to how `qmlavdecoder.cpp` picks its device type,
not a build-system tweak.

**Window behaviour.** `src/eventfilter.cpp` and the fullscreen handling in
`RootWindow.qml` were written against X11 window management. They should work,
but expect to test fullscreen toggling and multi-monitor placement by hand.
