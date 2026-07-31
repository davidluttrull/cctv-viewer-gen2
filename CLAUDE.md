# cctv-viewer-stretch — macOS port

Qt 5.15 / QML app for viewing many RTSP streams at once. Fork of
`iEvgeny/cctv-viewer`. Upstream targets Linux, Windows and Android; the macOS
port is new and lives on the `macos-build` branch. Verified on macOS 26.5.2,
Apple silicon (Mac13,2), AppleClang 17, Qt 5.15.18, FFmpeg 8.x via Homebrew.

## Repository layout that isn't obvious

`src/qmlav` is a git submodule. It points at `davidluttrull/qmlav` (our fork of
`iEvgeny/qmlav`), not upstream. Two branches matter there:

- `videotoolbox` — the CoreVideo zero-copy output module, plus the macOS CMake fixes
- `videotoolbox-bgra` — **the one to use.** The above plus the BGRA frames
  request, the colour-range fix and the rectangle-texture handle type. This is
  the only branch on which `-hwaccel_output cvgl` actually displays video.

`videotoolbox-bgra` may not exist in a fresh clone until you `git fetch` inside
the submodule — it is not reachable from the recorded gitlink.

The submodule gitlink must be advanced by hand after switching branches inside it:

```sh
cd src/qmlav && git checkout <branch> && cd ../..
git add src/qmlav && git commit -m "Update qmlav pointer"
```

## Build

```sh
cmake -S . -B build -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_PREFIX_PATH="$(brew --prefix qt@5)"
cmake --build build -j"$(sysctl -n hw.ncpu)"
```

Always Release. Debug turns on `-Werror` with a strict warning set never tried
against clang.

`PKG_CONFIG_PATH` is an environment variable, not a CMake cache variable.
Passing `-DPKG_CONFIG_PATH=` does nothing but emit an unused-variable warning.

Qt 5 is required, not a preference: `CMakeLists.txt` asks for the
`QuickCompiler` component, which does not exist in Qt 6. Homebrew deprecated
`qt@5` on 2026-05-19; it still installs and works. A Qt 6 port would need that
`find_package` line reworked and the whole GL texture path rewritten for
RHI/Metal.

## Deploy — order matters

```sh
"$(brew --prefix qt@5)/bin/macdeployqt" build/cctv-viewer.app -qmldir=.
codesign --force --deep --sign - build/cctv-viewer.app
```

**The re-sign is mandatory, not optional.** `macdeployqt` rewrites Mach-O load
commands, which invalidates the linker's ad-hoc signature. On Apple silicon the
result is a kill during dynamic linking, before any application code runs:

```
Termination Reason:  Namespace CODESIGNING, Code 2, Invalid Page
```

Re-sign after every `macdeployqt` run. `-qmldir=.` is required or the app opens
to a blank window with missing-module errors on stderr.

**Both steps must be repeated after *every* rebuild, not just the first
deploy.** Relinking produces a binary pointing back at Homebrew Qt while the
bundle still carries the deployed frameworks, so two copies of Qt load into one
process and the platform plugin fails:

```
Class QMacAutoReleasePoolTracker is implemented in both .../Cellar/qt@5/... and
.../cctv-viewer.app/Contents/Frameworks/QtCore.framework/...
qt.qpa.plugin: Could not load the Qt platform plugin "cocoa" ... even though it was found.
```

Treat `cmake --build` → `macdeployqt` → `codesign` as one indivisible sequence.

Icon: `sh macos/make-icns.sh` generates `macos/cctv-viewer.icns`, which CMake
picks up on the next configure. Not committed — it's a binary artifact.

## Pitfalls that will waste time

**`git pull` fails with "unstaged changes".** The build runs `lupdate`, which
rewrites the tracked files in `translations/`. Discard before pulling; they
regenerate every build:

```sh
git checkout -- translations/
git pull --rebase
```

**Logs only reach stderr, so launch from Terminal**, not Finder:

```sh
QT_LOGGING_RULES='qmlav.*=true' \
  /Applications/cctv-viewer.app/Contents/MacOS/cctv-viewer 2>&1 | tee ~/cctv.log
```

The default log level is `Config::LogInfo` and
`Config::reconfigureLoggingFilterRules()` gates `qmlav.info` behind it, so
`logInfo()` output disappears if the level is ever lowered. The env var
overrides all of it.

**The logging macros expand to `QmlAVUtils::log(this, ...)`** and therefore
cannot be used in static functions — notably
`QmlAVVideoDecoder::negotiatePixelFormatCb`, which is why
`requestBGRAHWFrames()` exists as a member function.

**`lupdate` warnings about `vf_mcdeint.c` and `yuv2rgb_template.c`** are the
translation scanner wandering into the vendored FFmpeg checkout under
`src/qmlav/3rd/FFmpeg` (used only for Android). Cosmetic. Likewise make's
"Circular ... dependency dropped" between translations and the QML cache.

## Hardware decoding — current state

`-hwaccel videotoolbox` works and is now the macOS default in
`RootWindow.qml`'s `defaultAVFormatOptions`. CPU drops to near zero. Caveat:
that is a `Settings` default, so an already-persisted value in the config file
wins. Check Settings → Viewport → Default FFmpeg options, and note per-viewport
options override the global default.

Without an output module, frames still take a GPU→CPU→GPU round trip:
`QmlAVVideoBuffer_GPU::map()` calls `av_hwframe_transfer_data()` **on Qt's
render thread**, serialized across all viewports. This — not decode — is the
suspected scaling limit, though it has never been measured. Target workload is
32× 640x480 plus one 4K on maximize.

Adding `-hwaccel_output cvgl` selects the CoreVideo module and bypasses that
round trip entirely. Verified working: video renders, correctly oriented, from a
CVPixelBuffer mapped straight to a GL texture. Only ever tested with **one**
720p stream, so the target workload above is still unmeasured — but it is now
measurable, which it was not before.

Note the transfer path still applies to every viewport *without* `cvgl`, and on
Linux. Moving that call off the render thread would be a portable win; the
serialization is the problem rather than the bandwidth, which for the target
workload is ~800 MB/s against ~800 GB/s of unified memory.

A suspected hang during zoom/pan at 16 streams was never reproduced; no crash
report exists because it was force-quit. Watch for it.

## CoreVideo zero-copy output — resolved

The `videotoolbox-bgra` branch works end to end. Two things had to be fixed, and
both are worth understanding before touching this code.

**1. BGRA needs full colour range.** VideoToolbox exposes each pixel format
under one specific range, and libavcodec resolves `sw_format` with
`full_range = (avctx->color_range == AVCOL_RANGE_JPEG)`. FFmpeg 8.1.2 registers
`AV_PIX_FMT_BGRA` as full-range only, so a stream declaring limited or
unspecified range missed the lookup — and the miss was **fatal**, not a
fallback: hardware decoding stopped entirely.

```
Failed to map underlying FFmpeg pixel format bgra (unknown range) to a VideoToolbox format!
Failed setup for format videotoolbox_vld: hwaccel initialisation returned error.
```

`requestBGRAHWFrames()` now probes both ranges with
`av_map_videotoolbox_format_from_pixfmt2()` and aligns `color_range` only once
BGRA frames are certain. Beware: `av_hwframe_ctx_init()` succeeds with a BGRA
`sw_format` even when libavcodec will later reject it, so the
`Requested BGRA HW frames` log line does **not** prove the format was accepted.

Also note the vendored `src/qmlav/3rd/FFmpeg` copy has BGRA registered as
limited-range, the opposite of the Homebrew 8.1.2 that actually links. It is
Android-only — don't read it to predict runtime behaviour.

**2. The texture target is `GL_TEXTURE_RECTANGLE_ARB` (`0x84F5`), and that is
fine.** CVOpenGLTextureCache never returns `GL_TEXTURE_2D`. This does *not*
require an FBO blit — Qt 5 already supports rectangle textures via
`QAbstractVideoBuffer::GLTextureRectangleHandle`, which selects
`QSGVideoMaterial_Texture_Rectangle` and its `texture2DRect` shader (the path
Qt's own AVFoundation backend uses). Declaring `GLTextureHandle` instead routes
frames into the `sampler2D` material, whose `glBindTexture(GL_TEXTURE_2D, id)`
fails with `GL_INVALID_OPERATION` — giving black viewports while decode, texture
creation and every log line all look perfectly healthy. That material also
handles `CVOpenGLTextureIsFlipped()`, so no scan-line direction change is needed.

Expect three one-off errors at stream start, before the first keyframe. They
recover and do not recur:

```
[h264] hardware accelerator failed to decode picture
[h264] vt decoder cb: output image buffer is null: -12909, reconfig 1
[QmlAVDecoder] Unable send packet to decoder: "Unknown error occurred"
```

The module compiles with six expected deprecation warnings — Apple deprecated
the CoreVideo/OpenGL bridge in 10.14 in favour of Metal.

## Don't reach for Metal in Qt 5

Qt 5.15 does ship an RHI path with a Metal backend (`QSG_RHI`,
`QSG_RHI_BACKEND=metal` in `QtQuick`), but `QtMultimediaQuick` — where the video
nodes live — contains no `QRhi`, no `.qsb` and no `QShader`. Its shaders are raw
GLSL 1.x (`gl_FragColor`, `texture2D`). Enabling Metal breaks video output
rather than accelerating it. Metal is a Qt 6 conversation, and worth checking
first whether Qt 6's FFmpeg multimedia backend handles VideoToolbox frames
natively — much of this module may simply be deletable rather than portable.

## Conventions

Match upstream style: 4 spaces, `m_` member prefix, brace on the same line for
control flow and the next line for functions. Comments explain *why*, since the
Linux-vs-macOS divergences are otherwise invisible.

Keep macOS changes guarded (`if (APPLE)`, `#if defined(__APPLE__)`,
`Q_OS_MACOS`) so the Linux build is never altered. Note CMake reports `UNIX` as
true on macOS, so any `APPLE` branch must come *before* the `UNIX` one.
