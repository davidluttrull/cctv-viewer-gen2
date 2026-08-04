# Building CCTV Viewer on Linux

Targets Linux Mint. Mint 21 is Ubuntu 22.04, Mint 22 is Ubuntu 24.04; the
package names below are the same on both.

**Status:** the Linux target builds clean in CI (`.github/workflows/linux-release.yml`,
zero warnings) and packages as an AppImage. **Hardware acceleration is on by
default** on `xcb` (X11) - see section 5.

## 1. Clone with submodules

```sh
git clone --recurse-submodules https://github.com/davidluttrull/cctv-viewer-stretch.git
cd cctv-viewer-stretch
```

`master` is the trunk and carries both platforms. `src/qmlav` is a submodule and
the build fails without it; if you cloned without `--recurse-submodules`, run
`git submodule update --init --recursive`.

## 2. Dependencies

This exact set is what CI verified. Two of these are easy to miss because
Debian's package names do not match CMake's component names, and both cost a
failed run:

- `qtmultimedia5-dev` — `qml-module-qtmultimedia` is the *runtime* module and
  does not provide the `Qt5Multimedia` CMake config.
- `qttools5-dev` — `qttools5-dev-tools` ships the `lupdate`/`lrelease` binaries
  but not the `Qt5LinguistTools` CMake config.

```sh
sudo apt install \
  cmake pkg-config \
  qtbase5-dev qtdeclarative5-dev qtquickcontrols2-5-dev \
  qtmultimedia5-dev qttools5-dev qttools5-dev-tools libqt5svg5-dev \
  libavcodec-dev libavformat-dev libavutil-dev \
  libswscale-dev libswresample-dev libavdevice-dev libavfilter-dev \
  libva-dev libx11-dev libgl1-mesa-dev libglx-dev libegl-dev
```

`libegl-dev` is for the VA-API hardware-acceleration path (section 5) - not a
transitive dependency of anything else in this list, so it is easy to drop by
copy-pasting an older version of this command.

Runtime QML modules — not needed to compile, but a missing one is a blank window
at runtime with no build error:

```sh
sudo apt install \
  qml-module-qtquick2 qml-module-qtquick-window2 \
  qml-module-qtquick-controls2 qml-module-qtquick-layouts \
  qml-module-qtquick-templates2 qml-module-qtquick-dialogs \
  qml-module-qtgraphicaleffects qml-module-qt-labs-settings \
  qml-module-qtmultimedia
```

`CMakeLists.txt` requires the `QuickCompiler` component, which is Qt 5 only.
`Qt5QuickCompiler` **is** packaged on 22.04 (in `qtdeclarative5-dev`) — worth
knowing, because it is not obviously available and its absence would block the
Release build entirely.

Mint 21 carries FFmpeg 4.4 (libavcodec 58), four major versions behind the
Homebrew FFmpeg the macOS port is developed against. That has not caused a
problem — the tree compiles clean against both.

## 3. Configure and build

```sh
cmake -S . -B build -DCMAKE_BUILD_TYPE=Release
cmake --build build -j"$(nproc)"
```

Use `Release`. `Debug` enables `-Werror` with a strict warning set. Unlike
macOS there is no bundling or signing step — the binary runs from the build tree.

## 4. Run

Logs only reach stderr, so launch from a terminal:

```sh
QT_LOGGING_RULES='qmlav.*=true' ./build/cctv-viewer 2>&1 | tee /tmp/cctv.log
```

`--config <path>` points the app at an alternate settings file. Use it for
experiments rather than editing the real config, which holds camera credentials
in plaintext. A 1×1 layout is maximized by definition, so a single-viewport
config exercises the maximized path at startup with no clicking.

## 5. Hardware acceleration

`QmlAVHWOutput_VAAPI_EGL` in `src/qmlav/src/qmlavhwoutput.cpp` runs the decoded
VA-API surface (NV12) through VA-API's VPP to convert it to a single RGB
surface on the GPU, exports that surface as a DRM PRIME dma-buf, and imports it
directly as a GL texture via EGL. The VPP round trip exists because Qt 5's
video material only knows how to sample a single already-RGB texture, not
two-plane YUV - see the class comment in `qmlavhwoutput.h` for the full
reasoning.

**The VPP output surface is double-buffered, and needs to stay that way.** A
single reused surface caused real, visible stutter and artifacting against
actual cameras on a multi-camera wall - never against the synthetic
single-viewport test stream below, which isn't enough load to expose it. VPP
and the GPU's render engine are independent, unsynchronized hardware queues,
so nothing stops VPP overwriting frame N+1 into the same buffer the render
engine is still reading from to display frame N. `m_rgbSurfaces[2]` alternates
per frame for exactly this reason - do not collapse it back to one surface as
a "simplification."

**On by default on Linux**, via the same `Settings`-default mechanism as the
macOS `cvgl` block: `src/RootWindow.qml`'s `defaultAVFormatOptions` sets it for
any config where nothing has been persisted yet. `main.cpp` forces
`QT_XCB_GL_INTEGRATION=xcb_egl` before `QGuiApplication` exists (constraint 3
below), so no environment setup is needed either - a stock launch on X11 gets
hardware decoding for free.

Select it by hand (Settings → Viewport → "Default FFmpeg options") if
overriding a persisted value:

```
-hwaccel vaapi -hwaccel_output egl
```

An existing config already has *some* value persisted for
`defaultAVFormatOptions` - that's the whole point of it being a per-install
setting - so upgrading an existing install does not retroactively turn this
on. It has to be set once, by hand or by resetting that key, same as any other
`Settings` default.

### Hard constraints

`QmlAVOptions::hwOutput()` refuses the module unless the first two hold, and
the third is required for a different reason - see below:

```cpp
if (avHWDeviceType() != AV_HWDEVICE_TYPE_VAAPI ||
    QGuiApplication::platformName() != "xcb") { ...refuse... }
```

1. `hwaccel` must be `vaapi`. Setting only `hwaccel_output` silently does nothing.
2. **X11 only.** Under Wayland `platformName()` is `wayland`, not `xcb`, and the
   module refuses to load. Mint's Cinnamon defaults to X11, so this normally
   holds — but it is a real ceiling, and `QT_QPA_PLATFORM=xcb` is the workaround
   if the session is Wayland.
3. **`QT_XCB_GL_INTEGRATION=xcb_egl` must be set before `QGuiApplication` exists.**
   `main.cpp` does this automatically (skipped if the environment already sets
   one, so a deliberate override still wins) - this is only something to think
   about if that guard is ever removed, or when running code that constructs
   `QGuiApplication` some other way. Qt 5's default GL integration on X11 is
   GLX. This module imports a dma-buf as an `EGLImage` via
   `eglGetCurrentDisplay()` and then binds it as a texture in whatever GL
   context is current - which only works when that context is itself EGL-based.
   Under the default GLX integration, an earlier version of this code obtained
   its own, separate EGL display (`eglGetDisplay(glXGetCurrentDisplay())`)
   instead, and that segfaulted inside the Mesa driver on every single frame:
   importing a dma-buf through one Mesa screen and binding it as a texture
   through a different one is not safe on this stack, even though both
   ultimately talk to the same GPU over the same X11 connection. Two other
   hypotheses were checked and ruled out before finding this - the DRM-PRIME
   descriptor's fields (fourcc, pitch, offset) are correct, and the surface's
   format modifier reports `0x0` (linear), so Intel's implicit-tiling was not
   the cause either.

A stock launch already has this covered - `QT_XCB_GL_INTEGRATION` doesn't need
setting by hand unless testing what happens without `main.cpp`'s guard:

```sh
QT_LOGGING_RULES='qmlav.*=true' ./build/cctv-viewer --config <path> 2>&1 | tee /tmp/cctv.log
```

### Check the driver first

```sh
sudo apt install vainfo intel-media-va-driver
vainfo
```

`vainfo` must list H264 decode entrypoints. On Intel it selects the `iHD` driver
on newer hardware and `i965` on older; if `vainfo` fails, nothing in the app can
work and the problem is the driver, not this code. Note that `i965` does not
recognize Gen8+ hardware at all - on a modern Intel GPU there is no fallback
driver to switch to if something about `iHD` doesn't work, which is exactly why
the EGL integration fix above, not a driver swap, was the way through this.

### The local test stream needs `-pix_fmt yuv420p`

The `ffmpeg` CLI is not one of the dev packages above and is not pulled in by
any of them - `sudo apt install ffmpeg` if `ffmpeg -version` doesn't work.

`ffmpeg -f lavfi -i testsrc=... -c:v libx264 ...` with no explicit `-pix_fmt`
encodes YUV 4:4:4 - `testsrc`'s raw output is `rgb24`, and libx264 picks the
closest lossless match to it. VA-API only decodes the 4:2:0 profiles `vainfo`
lists above, so a 4:4:4 stream makes `negotiatePixelFormatCb()` in
`qmlavdecoder.cpp` silently fall through to CPU decode - no warning, and the
picture plays back fine, which reads as "hardware acceleration works" when
nothing was accelerated. Real cameras send 4:2:0, so this never bites in
production; it only bites this synthetic test stream. Always force it:

```sh
ffmpeg -re -f lavfi -i "testsrc=size=640x480:rate=15" -pix_fmt yuv420p -c:v libx264 \
  -preset ultrafast -tune zerolatency -g 15 \
  -f mpegts "udp://127.0.0.1:9999?pkt_size=1316"
```

(Same recipe the macOS section above documents, plus `-pix_fmt yuv420p`.)

### How to verify it actually works

**Decode succeeding proves nothing about display.** This is the hard-won lesson
from the macOS side, where decode, texture creation and every log line looked
healthy while every viewport was black - and it bit this port too, twice
(the silent CPU fallback above, then the GLX-integration segfault), before
landing on the current implementation.

`QmlAVHWOutput_VAAPI_EGL` has no per-instance success log line, only warnings
on failure (`vaExportSurfaceHandle() failed`, `eglCreateImageKHR() failed`,
`GL_OES_EGL_image is not supported`, ...), so counting log lines the way the
macOS CoreVideo module allows does not apply here - a silent CPU fallback and a
genuinely working hardware path both produce a perfectly quiet log. Check
instead:

1. **Look at the window.** Do not infer success from clean logs.
2. **GPU engine counters**, which is what actually tells the two apart:

   ```sh
   sudo intel_gpu_top
   ```

   Look for non-zero `Video` (decode) and `Render/3D` (the VPP conversion)
   engine usage attributed to the `cctv-viewer` process while a stream plays.
   Both reading 0% means nothing is running on the GPU, no matter how correct
   the picture looks or how quiet the log is - CPU decode renders correctly too.

Counting live connections answers "which streams are running" without the screen:

```sh
lsof -nP -a -p "$(pgrep -x cctv-viewer)" -i TCP | grep -c ESTABLISHED
```

### What used to be here

An earlier version of this module, `QmlAVHWOutput_VAAPI_GLX`, mapped the VA-API
surface to an X11 pixmap via `vaPutSurface()`, then to a GLX pixmap, then to a
GL texture via `GLX_EXT_texture_from_pixmap` - the direct Linux equivalent of
what `cvgl` does on macOS. `vaPutSurface()` returned
`VA_STATUS_ERROR_INVALID_PARAMETER` on every single frame on `iHD` - the only
driver this hardware supports. The legacy VA/X11 `vaPutSurface` path that
approach depends on is known to be poorly supported on Intel's modern media
driver; this is a known category of problem across the ecosystem (several
other GL/VA-API integrations have moved off it for the same reason), not
something specific to this codebase.

Likewise the BGRA colour-range problem noted in the macOS section above was
specific to FFmpeg's VideoToolbox format table and has no VA-API analogue.

## 6. AppImage

CI builds it on tag push or manual dispatch; the artifact appears on the release
and in the Actions tab. To reproduce locally, see `linux-release.yml` — the only
non-obvious steps are `QML_SOURCES_PATHS` (the analogue of macdeployqt's
`-qmldir=.`, so linuxdeploy's Qt plugin knows which QML modules to bundle) and
deleting `libva*` from the AppDir afterwards, so the host's libva and vendor
driver stay authoritative. A bundled libva that cannot load the host driver
costs hardware decoding silently.

The workflow pins `ubuntu-22.04` deliberately. An AppImage built against a newer
glibc will not start on an older distribution, so building on 22.04 covers Mint
21 and still runs on Mint 22. Bumping it drops Mint 21 support.

**The AppImage has never been launched.** CI proves it builds and packages, not
that it runs.

## Gotchas

`git pull` fails with "You have unstaged changes" because the build runs
`lupdate`, which rewrites the tracked files in `translations/`. Discard them —
they are regenerated every build:

```sh
git checkout -- translations/
git pull --rebase
```

`cctv-viewer.qrc` is the list of QML that actually ships. The QML is compiled
into the binary, so a `.qml` file the `.qrc` does not name is dead code, and
editing one fails silently — the build succeeds and nothing changes.
