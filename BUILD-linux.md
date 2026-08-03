# Building CCTV Viewer on Linux

Targets Linux Mint. Mint 21 is Ubuntu 22.04, Mint 22 is Ubuntu 24.04; the
package names below are the same on both.

**Status:** the Linux target builds clean in CI (`.github/workflows/linux-release.yml`,
zero warnings) and packages as an AppImage. **Hardware acceleration is not
enabled yet** — that is the open task, see section 5. Until then Linux decodes
on the CPU while macOS does not.

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
  libva-dev libx11-dev libgl1-mesa-dev libglx-dev
```

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

## 5. Hardware acceleration — the open task

Nothing currently defaults hardware decoding on Linux, so this is CPU decode
today. The pieces already exist: `QmlAVHWOutput_VAAPI_GLX` in
`src/qmlav/src/qmlavhwoutput.cpp` maps a VA-API surface to an X11 pixmap, then
to a GLX pixmap, then to a GL texture — the Linux equivalent of what `cvgl` does
on macOS.

Select it with:

```
-hwaccel vaapi -hwaccel_output glx
```

Try it by hand first (Settings → Viewport → "Default FFmpeg options"), then make
it a default by mirroring the macOS block in `src/RootWindow.qml`'s
`defaultAVFormatOptions`. That is a `Settings` default, so it only applies where
nothing has been persisted — an existing install keeps its current value.

### Two hard constraints

`QmlAVOptions::hwOutput()` refuses the module unless **both** hold:

```cpp
if (avHWDeviceType() != AV_HWDEVICE_TYPE_VAAPI ||
    QGuiApplication::platformName() != "xcb") { ...refuse... }
```

1. `hwaccel` must be `vaapi`. Setting only `hwaccel_output` silently does nothing.
2. **X11 only.** Under Wayland `platformName()` is `wayland`, not `xcb`, and the
   module refuses to load. Mint's Cinnamon defaults to X11, so this normally
   holds — but it is a real ceiling, and `QT_QPA_PLATFORM=xcb` is the workaround
   if the session is Wayland.

### Check the driver first

```sh
sudo apt install vainfo intel-media-va-driver
vainfo
```

`vainfo` must list H264 decode entrypoints. On Intel it selects the `iHD` driver
on newer hardware and `i965` on older; if `vainfo` fails, nothing in the app can
work and the problem is the driver, not this code.

### How to verify it actually works

**Decode succeeding proves nothing about display.** This is the hard-won lesson
from the macOS side, where decode, texture creation and every log line looked
healthy while every viewport was black. Check both:

1. **Count the module's log lines against the viewport count.** The output module
   logs once per instance, so N lines in an N-viewport grid means all of them
   reached the zero-copy path. Fewer means some fell back, and the reason is in
   the log.
2. **Look at the window.** Do not infer success from clean logs.

Counting live connections answers "which streams are running" without the screen:

```sh
lsof -nP -a -p "$(pgrep -x cctv-viewer)" -i TCP | grep -c ESTABLISHED
```

### What not to go looking for

The macOS module hit a texture-target mismatch:
`CVOpenGLTextureCache` returns `GL_TEXTURE_RECTANGLE_ARB`, which Qt's default
`GLTextureHandle` material cannot bind, giving black viewports with healthy
logs. **The GLX path does not have this problem.** It explicitly requests
`GLX_BIND_TO_TEXTURE_TARGETS_EXT, GLX_TEXTURE_2D_BIT_EXT` and
`GLX_TEXTURE_TARGET_EXT, GLX_TEXTURE_2D_EXT`, then binds `GL_TEXTURE_2D`
(`qmlavhwoutput.cpp:71`), so `GLTextureHandle` is already correct. Do not
"fix" it to `GLTextureRectangleHandle`.

Likewise the BGRA colour-range problem was specific to FFmpeg's VideoToolbox
format table and has no VA-API analogue.

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
