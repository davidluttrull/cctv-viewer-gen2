# cctv-viewer-stretch — macOS port

Qt 5.15 / QML app for viewing many RTSP streams at once. Fork of
`iEvgeny/cctv-viewer`. Upstream targets Linux, Windows and Android; the macOS
port lives on the `macos-build` branch.

**`BUILD-macos.md` is the canonical build, deploy and hardware-decoding
reference.** Read it before doing any of that work — do not duplicate its
content here. This file covers only what an agent needs that a build guide
would not say.

## Build and run, in brief

```sh
cmake -S . -B build -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_PREFIX_PATH="$(brew --prefix qt@5)"
cmake --build build -j"$(sysctl -n hw.ncpu)"
"$(brew --prefix qt@5)/bin/macdeployqt" build/cctv-viewer.app -qmldir=.
codesign --force --deep --sign - build/cctv-viewer.app
```

All four steps, every time. Skipping the last two after a rebuild loads two
copies of Qt and the cocoa plugin fails — see `BUILD-macos.md` §6. Always
`Release`; `Debug` turns on `-Werror` with a warning set never tried against
clang.

Logs only reach stderr, so launch from a terminal, never Finder:

```sh
QT_LOGGING_RULES='qmlav.*=true' \
  ./build/cctv-viewer.app/Contents/MacOS/cctv-viewer 2>&1 | tee /tmp/cctv.log
```

`--config <path>` points the app at an alternate settings file. Use it for
experiments instead of touching
`~/Library/Preferences/org.cctv-viewer.CCTV Viewer.plist` — which, despite the
name, is an INI file and holds camera credentials in plaintext. Never paste its
contents anywhere.

## The submodule is the main trap

`src/qmlav` points at `davidluttrull/qmlav`, not upstream. The branch that
matters is **`videotoolbox-bgra`**; `videotoolbox` predates the fixes that make
video actually display.

- It checks out **detached** at the recorded commit. To commit, `git checkout
  videotoolbox-bgra` inside it first.
- The gitlink is advanced by hand: `git add src/qmlav && git commit`.
- **Always push the submodule before the superproject.** Otherwise the gitlink
  names a commit no one else can fetch.
- A branch may exist on the remote without being local — `git fetch` inside the
  submodule before concluding it is missing.

## Verifying video actually renders

Decode succeeding proves nothing about display. Two failure modes look healthy
in logs while the viewport is black, and both have bitten this port:

1. A pixel format the texture cache rejects.
2. A texture target Qt binds incorrectly.

`screencapture` fails here (`could not create image from display`) without
Screen Recording permission, so **ask the user to look at the window** rather
than inferring from clean logs. For a mechanical answer that needs no screen,
compile a small CGL program that does what Qt does — bind the texture name to
its expected target and check `glGetError()`.

Useful signal: the CoreVideo module logs its texture target once per instance,
so counting those lines equals the number of viewports that reached the
zero-copy path. 16 lines in a 4×4 grid means all of them.

## Things that are settled — do not re-litigate

- **`GL_TEXTURE_RECTANGLE_ARB` needs no FBO blit.** Qt 5 supports it via
  `QAbstractVideoBuffer::GLTextureRectangleHandle`, which selects
  `QSGVideoMaterial_Texture_Rectangle` and its `texture2DRect` shader. That
  material also handles `CVOpenGLTextureIsFlipped()`.
- **Metal is not an option under Qt 5.** `QtMultimediaQuick` is OpenGL-only.
  Details in `BUILD-macos.md`.
- **BGRA needs full colour range**, and the misleading part is that
  `av_hwframe_ctx_init()` succeeds anyway. Details in `BUILD-macos.md`.

## Known-unmeasured

`av_hwframe_transfer_data()` on the render thread is bypassed on macOS by the
`cvgl` default, but still applies to any viewport without it, and on Linux. It
has never been profiled. Moving it to the per-viewport decoder threads would be
a portable win — the serialization is the problem, not the bandwidth, which for
32 × 480p plus a 4K is under 1 GB/s against ~800 GB/s of unified memory.

## Conventions

Match upstream style: 4 spaces, `m_` member prefix, brace on the same line for
control flow and the next line for functions. Comments explain *why* — the
Linux-vs-macOS divergences are otherwise invisible.

Keep macOS changes guarded (`if (APPLE)`, `#if defined(__APPLE__)`,
`Q_OS_MACOS`, or `Qt.platform.os === "osx" || "macos"` in QML) so the Linux
build is never altered. CMake reports `UNIX` as true on macOS, so any `APPLE`
branch must come *before* the `UNIX` one.

Do not commit `translations/` churn — the build runs `lupdate`, which rewrites
those tracked files. `git checkout -- translations/` before pulling.
