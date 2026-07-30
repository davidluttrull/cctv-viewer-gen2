# Building CCTV Viewer on macOS

Everything below has to happen on the Mac itself — there is no cross-compile
path from Windows or Linux.

Verified on macOS 26.5.2, Apple silicon (Mac13,2), AppleClang 17, Qt 5.15.18
and FFmpeg 8.x (libavcodec 62) from Homebrew.

## 1. Clone with submodules

```sh
git clone --recurse-submodules https://github.com/davidluttrull/cctv-viewer-stretch.git
cd cctv-viewer-stretch
git checkout macos-build
```

`src/qmlav` is a submodule and the build fails without it. If you already
cloned without `--recurse-submodules`, run
`git submodule update --init --recursive`.

## 2. Put the submodule on the videotoolbox branch

`.gitmodules` points at our fork, but the recorded commit is still upstream's,
so the VideoToolbox output module has to be checked out explicitly:

```sh
git submodule sync
git submodule update --init --recursive

cd src/qmlav
git fetch origin videotoolbox
git checkout videotoolbox
cd ../..

git add src/qmlav
git commit -m "Point qmlav at the videotoolbox branch"
```

Confirm with `git submodule status`.

## 3. Dependencies

```sh
xcode-select --install
brew install cmake pkgconf ffmpeg qt@5
```

Qt 5 rather than Qt 6 because `CMakeLists.txt` requires the `QuickCompiler`
component, which only exists in Qt 5. Note that Homebrew deprecated `qt@5` on
2026-05-19 because Qt 5 is end-of-life — it still installs and works, but
prints a warning, and a Qt 6 port will eventually be necessary.

`googletest` is not needed. qmlav's test suite is skipped when GTest is absent.

## 4. Configure and build

```sh
cmake -S . -B build \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_PREFIX_PATH="$(brew --prefix qt@5)"

cmake --build build -j"$(sysctl -n hw.ncpu)"
```

Use `Release`. `Debug` enables `-Werror` plus a strict warning set that has not
been tried against clang.

`PKG_CONFIG_PATH` is an environment variable, not a CMake cache variable. Only
needed if pkg-config cannot find FFmpeg on its own:

```sh
PKG_CONFIG_PATH="$(brew --prefix ffmpeg)/lib/pkgconfig" cmake -S . -B build ...
```

Two harmless noises during the build: `lupdate` wanders into the vendored
FFmpeg checkout under `src/qmlav/3rd/FFmpeg` and complains about C source it
cannot parse as C++, and make reports a dropped circular dependency between the
translations and the QML cache. Both are pre-existing and cosmetic.

## 5. Smoke test before bundling

```sh
./build/cctv-viewer.app/Contents/MacOS/cctv-viewer
```

This runs against Homebrew's Qt via absolute paths. You should get the window
and the sidebar. Any QML module resolution errors show up on stderr here.

## 6. Bundle, then re-sign — in that order

```sh
"$(brew --prefix qt@5)/bin/macdeployqt" build/cctv-viewer.app -qmldir=.
codesign --force --deep --sign - build/cctv-viewer.app
codesign --verify --deep --strict --verbose=2 build/cctv-viewer.app
./build/cctv-viewer.app/Contents/MacOS/cctv-viewer
```

**The re-sign is mandatory on Apple silicon, not optional.** Every binary must
carry a valid signature; the linker applies an ad-hoc one automatically, which
is why step 5 works. `macdeployqt` then rewrites Mach-O load commands to
repoint library references into the bundle's own `Frameworks` directory, and
rewriting those bytes invalidates the signature. The result is a hard kill
during dynamic linking, before any of the app's own code runs:

```
Termination Reason:  Namespace CODESIGNING, Code 2, Invalid Page
Exception Type:      EXC_BAD_ACCESS (SIGKILL (Code Signature Invalid))
```

The `-` identity means ad-hoc: no Developer ID, valid on this machine only.
`--deep` covers the Qt frameworks and plugins `macdeployqt` copied in, which
were rewritten as well. Re-run `codesign` after every `macdeployqt` run.

`-qmldir=.` lets `macdeployqt` scan the QML files to find which Qt Quick
modules are imported at runtime. Without it the app opens to a blank window.

Distributing to another Mac requires a real Developer ID signature plus
notarization; ad-hoc signatures are rejected by Gatekeeper elsewhere.

## 7. Install

```sh
rm -rf /Applications/cctv-viewer.app
cp -R build/cctv-viewer.app /Applications/
open /Applications/cctv-viewer.app
```

A locally built bundle carries no quarantine attribute, so there is no
Gatekeeper prompt.

If bundling is more trouble than it's worth, the un-deployed bundle from step 5
can be copied to `/Applications` as-is. It keeps working as long as `qt@5` and
`ffmpeg` remain installed through Homebrew — fine for one machine, not portable.

## 8. Hardware decoding

Settings → Viewport → "Default FFmpeg options":

```
-hwaccel videotoolbox
```

No rebuild required. `QmlAVOptions::avHWDeviceType()` passes the value straight
to `av_hwdevice_find_type_by_name()`, and when no output module matches,
`QmlAVVideoBuffer_GPU::map()` falls back to `av_hwframe_transfer_data()` to
bring frames into system memory. VideoToolbox's `sw_format` is NV12, which
qmlav already treats as Qt-native, so no swscale conversion runs — the CPU does
one plane copy per frame instead of decoding H.264/HEVC.

Compare CPU usage in Activity Monitor with a full grid before and after.

Adding `-hwaccel_output cvgl` selects the zero-copy CoreVideo module, but see
below before expecting it to work.

On first connection macOS prompts for Local Network access. Deny it and the
cameras never connect, with viewports sitting at "Loading..." and no obvious
cause. System Settings → Privacy & Security → Local Network.

## Known gaps in the cvgl module

**The decoder still requests NV12.** `CVOpenGLTextureCache` produces one
texture per plane, so the module rejects non-BGRA buffers rather than rendering
them incorrectly. Requesting BGRA means allocating `hw_frames_ctx` explicitly
in `initVideoDecoder()` with `sw_format` set to BGRA, via
`avcodec_get_hw_frames_parameters()`.

**Texture target mismatch.** `CVOpenGLTextureCache` returns
`GL_TEXTURE_RECTANGLE_ARB` on macOS while Qt's video node shaders sample
`GL_TEXTURE_2D`, so the texture will not display until that is reconciled with
an FBO blit. `CVOpenGLTextureGetTarget()` reports the actual target.

The CoreVideo/OpenGL bridge is also deprecated as of macOS 10.14 in favour of
Metal, which produces four compiler warnings. It still functions under Qt 5,
but a Qt 6 port would need this rewritten against Metal and QRhi.

**Window behaviour.** `src/eventfilter.cpp` and the fullscreen handling in
`RootWindow.qml` were written against X11 window management. Test fullscreen
toggling and multi-monitor placement by hand.

## Gotchas

`git pull` fails with "You have unstaged changes" because the build runs
`lupdate`, which rewrites the tracked files in `translations/`. Discard them
first — they are regenerated every build:

```sh
git checkout -- translations/
git pull --rebase
```

`git config pull.rebase true` stops git asking how to reconcile each time.
