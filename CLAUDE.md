# cctv-viewer-stretch — macOS port

Qt 5.15 / QML app for viewing many RTSP streams at once. Fork of
`iEvgeny/cctv-viewer`. Upstream targets Linux, Windows and Android; this fork
adds macOS and ships macOS and Linux release artifacts from one trunk.

`master` is the trunk — all work lands there, and platform differences are
handled by guards rather than by separate branches. `macos-build` is the former
name of this same lineage, kept only until the clones tracking it move over. Do
not start a parallel platform branch; see the Conventions section.

**`BUILD-linux.md` is the canonical reference for Linux** — build, AppImage, and
the VA-API hardware-acceleration path, which is on by default on `xcb` (X11).
Read it before any Linux work. Three things it will save you: the apt package
names do not match CMake's component names (`qtmultimedia5-dev` and
`qttools5-dev` are the ones that bite), the VA-API/EGL module is X11-only,
refusing to load unless `QGuiApplication::platformName()` is `xcb`, and it also
requires Qt's GL integration itself to be EGL-based
(`QT_XCB_GL_INTEGRATION=xcb_egl`, which `main.cpp` sets automatically) - Qt's
default GLX integration crashes the driver on every frame instead.

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
sh macos/fixup-bundle.sh
codesign --force --deep --sign - build/cctv-viewer.app
```

All five steps, every time. Skipping the last three after a rebuild loads two
copies of Qt and the cocoa plugin fails — see `BUILD-macos.md` §6. Always
`Release`; `Debug` turns on `-Werror` with a warning set never tried against
clang.

`macos/fixup-bundle.sh` finishes the job `macdeployqt` leaves half-done: it
repoints FFmpeg's references to its own libraries into the bundle, adds the
SVG image plugin, and then fails if anything in the bundle still resolves to a
path outside it. Both omissions are invisible on the build machine and fatal on
the user's — details in `BUILD-macos.md` §6. It must run before `codesign`,
because it rewrites load commands and so invalidates the signature.

`sh macos/make-icns.sh` regenerates the Dock icon (needed once per clone, and
after editing `macos/appicon.svg`; CMake only picks it up at configure time).
`sh macos/make-dmg.sh` packages a release image, and must run after the
`codesign` step above, not before.

**`cctv-viewer.qrc` is the list of QML that actually ships.** The QML is compiled
into the binary, so a `.qml` file the `.qrc` does not name is dead code wherever
it sits, and editing one fails silently — the build succeeds, the app runs, and
nothing changes. A stale copy of `ViewportsLayout.qml` at the repository root
absorbed the whole of 11a7908 that way; the commit read as done for three days
and had never executed. Check the `.qrc` before editing any QML outside `src/`.

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

Counting live connections answers questions about which streams are *running*
without needing the screen at all:

```sh
lsof -nP -a -p "$(pgrep -x cctv-viewer)" -i TCP | grep -c ESTABLISHED
```

That is how the stream cross-fade below was verified: two decoders start, and
one connection remains once the handoff has completed.

A 1×1 layout is maximized by definition, so a config with a single viewport
exercises the maximized path at startup with no clicking. `--config` takes any
path, and the layout lives in the `models` key as JSON — hand-writing one is
much less work than driving the GUI.

A local stream gives control over the failure modes that matter, with no camera
and nothing to look at:

```sh
ffmpeg -re -f lavfi -i "testsrc=size=640x480:rate=15" -c:v libx264 \
  -preset ultrafast -tune zerolatency -g 15 \
  -f mpegts "udp://127.0.0.1:9999?pkt_size=1316"
```

- **Stall:** `kill -STOP` the sender. Note `pgrep -f` matches the shell wrapper
  around a backgrounded command, not `ffmpeg` — stopping the wrapper leaves the
  child streaming. Use `pgrep -x ffmpeg`. Allow for the receive buffer draining
  first: 2 MB holds seconds of a low-bitrate stream.
- **Corrupted references:** add `-bsf:v noise=amount=1500`. Lower amounts corrupt
  every keyframe too, so nothing can ever decode and recovery cannot be observed.
- `udp://` binds a fixed local port, so a reconnect can hit `Address already in
  use` before the old socket is released. Real cameras use ephemeral client ports
  and do not.

## Things that are settled — do not re-litigate

- **`GL_TEXTURE_RECTANGLE_ARB` needs no FBO blit.** Qt 5 supports it via
  `QAbstractVideoBuffer::GLTextureRectangleHandle`, which selects
  `QSGVideoMaterial_Texture_Rectangle` and its `texture2DRect` shader. That
  material also handles `CVOpenGLTextureIsFlipped()`.
- **Metal is not an option under Qt 5.** `QtMultimediaQuick` is OpenGL-only.
  Details in `BUILD-macos.md`.
- **BGRA needs full colour range**, and the misleading part is that
  `av_hwframe_ctx_init()` succeeds anyway. Details in `BUILD-macos.md`.
- **Neither of those macOS bugs has a Linux analogue.** `QmlAVHWOutput_VAAPI_EGL`
  imports its dma-buf as a plain `GL_TEXTURE_2D`, so `GLTextureHandle` is
  correct there — do not "fix" it to `GLTextureRectangleHandle`. The colour
  range problem was specific to FFmpeg's VideoToolbox format table. (Linux has
  its own hard-won display-path lesson, unrelated to either of these — see
  `BUILD-linux.md` §5.)

- **Stream quality switching uses two overlapping players, not one player
  changing `source`.** Changing `source` tears down the RTSP connection and
  rebuilds it, which is seconds of "Loading...". `ViewportsLayout.qml` keeps the
  outgoing stream rendering until the incoming one has presented a frame, then
  cross-fades and stops the one behind — so the steady state is still one stream
  per viewport, and both directions are seamless. Collapsing this back to a
  single player is the obvious "simplification" and reintroduces the stall.

- **UDP is a deliberate choice, and the mitigations follow from it.** Lowest
  latency matters more here than losing the occasional frame, so anything that
  buys reliability with delay — `rtsp_transport tcp`, a larger `max_delay`,
  bigger reorder queues — is off the table. Reducing loss without adding latency
  (the 2 MB `buffer_size`) and recovering from it quickly (decoder resync, stall
  reconnect) is the approach. Details in `BUILD-macos.md`.

- **Reconnect a stalled stream only once it has shown a frame.** A stream that
  has never delivered one is usually just slow to connect, and is already covered
  by `demuxer_timeout` plus `QmlAVPlayer`'s retry on a terminal status;
  reconnecting it interrupts the connection it was in the middle of making. This
  was observed, not theorized: the demo streams take over 15s to start, and an
  unconditional reconnect made them fail to open before they came up.

- **Wait on `Player.firstFrameShown`, never `MediaPlayer.Buffered`.** The status
  reaches `Buffered` while the video surface is still empty, so a fade triggered
  on it fades in black — which looks exactly like the bug it was meant to fix.
  `firstFrameShown` is driven by qmlav's `videoFramePresented`, emitted after
  `present()` succeeds.

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
