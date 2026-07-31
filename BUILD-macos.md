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

## 2. Check the submodule commit

`.gitmodules` points at our fork and the recorded commit is now the right one —
the tip of `videotoolbox-bgra`, which carries the VideoToolbox output module and
the two fixes that make it display video. A plain init is enough:

```sh
git submodule sync
git submodule update --init --recursive
git submodule status src/qmlav
```

A leading `-` means uninitialized, `+` means the checkout does not match the
recorded commit. Neither should appear. No manual branch checkout is needed;
earlier revisions of this document told you to check out `videotoolbox` by hand,
which is now wrong — that branch predates the fixes and renders black viewports.

Note the submodule lands detached at the recorded commit rather than on a
branch. To commit changes to qmlav you have to `git checkout videotoolbox-bgra`
inside it first, then advance the gitlink by hand:

```sh
cd src/qmlav && git checkout videotoolbox-bgra && cd ../..
git add src/qmlav && git commit -m "Point qmlav at ..."
```

**Push the submodule before the superproject.** A gitlink referencing a commit
that only exists locally leaves everyone else with
`fatal: reference is not a tree`.

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

**Both steps must be repeated after every rebuild, not just the first deploy.**
Relinking replaces the executable with one that references Homebrew's Qt again,
while the bundle still carries the frameworks `macdeployqt` copied in. Two copies
of Qt then load into one process and the platform plugin fails:

```
Class QMacAutoReleasePoolTracker is implemented in both .../Cellar/qt@5/...
  and .../cctv-viewer.app/Contents/Frameworks/QtCore.framework/...
qt.qpa.plugin: Could not load the Qt platform plugin "cocoa" ... even though it was found.
```

Treat `cmake --build` → `macdeployqt` → `codesign` as one indivisible sequence.

`-qmldir=.` lets `macdeployqt` scan the QML files to find which Qt Quick
modules are imported at runtime. Without it the app opens to a blank window.

An ad-hoc signature is enough to *run* the app anywhere, but not enough to get
it past Gatekeeper on a Mac that downloaded it — see section 8.

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

### The Dock icon

```sh
brew install librsvg
sh macos/make-icns.sh
cmake -S . -B build ...   # reconfigure; CMake only picks it up at configure time
```

`macos/make-icns.sh` rasterizes `macos/appicon.svg` into
`macos/cctv-viewer.icns`. The `.icns` is a binary artifact and is not committed,
so a fresh clone builds with the generic icon until this is run — CMake prints a
status line saying so rather than failing.

The source is macOS-specific and drawn on Apple's icon grid (an 824×824 rounded
square centred in a 1024 canvas). `images/cctv-viewer.svg` remains the Linux and
Windows icon and is unchanged.

`rsvg-convert` is required and there is deliberately no fallback. `qlmanage` can
also rasterize SVG, but it composites onto opaque white instead of preserving
alpha, which bakes a white square around the rounded corners — obvious in the
Dock, and invisible in the script's output.

## 8. Publishing a disk image

```sh
sh macos/make-dmg.sh            # after build → macdeployqt → codesign
```

Writes `build/CCTV-Viewer-<version>-<arch>.dmg` plus
`build/release-notes.md`. The image holds the app, a symlink to `/Applications`
to drag it onto, and a read-me.

The script refuses to run on a bundle whose signature does not verify, or one
with no Qt frameworks copied in. Both mistakes produce an image that installs
cleanly and then fails on the user's machine — the first with a SIGKILL, the
second with missing-library errors — so they are worth catching here.

It also does not go through `install()` or CPack. Both rewrite Mach-O load
commands as they stage files, which invalidates the signature applied in step 6,
which is exactly the failure that step warns about. `ditto` copies the bundle
byte for byte instead.

### Gatekeeper, and what users actually see

An ad-hoc signature is valid but anonymous. A disk image downloaded from GitHub
carries a quarantine flag, and for an app that is not notarized, macOS 15 and
later refuse to open it — the Control-click → Open shortcut that used to bypass
this was removed. The real first-launch sequence is:

1. Double-click; macOS says it "cannot be opened because Apple cannot check it
   for malicious software".
2. System Settings → Privacy & Security → scroll to Security → **Open Anyway**.

Or `xattr -dr com.apple.quarantine /Applications/cctv-viewer.app`. Once per
machine either way. `make-dmg.sh` reads the signature off the bundle and writes
the read-me and release notes to match, so those instructions cannot drift out
of sync with what was actually shipped.

### CI

`.github/workflows/macos-release.yml` runs the whole sequence on GitHub's macOS
runner in about two and a half minutes. Pushing a tag publishes a release with
the image attached.

The runners are Apple silicon, so the result is **arm64 only**. Intel Macs would
need a second job on `macos-13` and a second image.

The workflow also declares `workflow_dispatch`, but that will not appear in the
Actions tab or work from `gh workflow run` until the file exists on the
repository's **default branch**. It currently lives only on `macos-build`, and
GitHub registers manual triggers from the default branch alone:

```
HTTP 404: workflow macos-release.yml not found on the default branch
```

Tag pushes are unaffected — those are evaluated against the workflow file in the
tag's own commit, so releasing works regardless. To get the manual trigger,
the workflow file has to be merged to `master`.

### Switching to a Developer ID

Notarizing removes the first-launch warning entirely. The workflow already
branches on whether the credentials exist, so it is only a matter of adding these
repository secrets — no workflow edits:

| Secret | What it is |
|---|---|
| `MACOS_CERTIFICATE` | Developer ID Application certificate, exported as `.p12`, then `base64` |
| `MACOS_CERT_PASSWORD` | the password set when exporting that `.p12` |
| `APPLE_ID` | Apple ID of the developer account |
| `APPLE_TEAM_ID` | the 10-character team ID |
| `APPLE_APP_PASSWORD` | an app-specific password, from appleid.apple.com |

**That path has never been run.** It is written from Apple's documented steps —
sign inside-out with the hardened runtime, submit with `notarytool`, staple the
ticket — but with no account to test against, treat the first tag build after
adding the secrets as the real test, and check the workflow log rather than
assuming.

## 9. Hardware decoding

Nothing to configure. On macOS the default FFmpeg options are:

```
-hwaccel videotoolbox -hwaccel_output cvgl
```

`hwaccel` hands H.264/HEVC to the VideoToolbox media engine instead of the CPU.
`hwaccel_output cvgl` then keeps the decoded frames on the GPU: the
`CVPixelBuffer` is wrapped as an OpenGL texture through `CVOpenGLTextureCache`
and handed to Qt directly.

Without `cvgl`, decoding is still offloaded but every frame is dragged back
through system memory by `av_hwframe_transfer_data()` in
`QmlAVVideoBuffer_GPU::map()` — on Qt's render thread, serialized across all
viewports. That serialization, not the copy bandwidth, is what limits how many
viewports stay smooth.

### Measured

32 streams across two 4×4 windows (two processes), 12 × 704×480 plus 4 × 1280×720,
sustained 90 seconds on a Mac13,2:

| | per process |
|---|---|
| CPU | ~33% of one core (median) |
| RSS | 236–245 MB, flat |
| viewports on the zero-copy path | 16/16 |

That is roughly 3% of a 20-core machine for all 32 streams, with no memory
growth across ~86,000 frames. Maximizing a 4K stream stays responsive.

### Overriding it

`defaultAVFormatOptions` in `src/RootWindow.qml` is a `Settings` **default**, so
it only applies where nothing has been persisted yet. An existing install keeps
whatever is already in its config file. Check Settings → Viewport → "Default
FFmpeg options", and note per-viewport options override the global default.

To compare against the CPU path, clear `hwaccel` there and restart.

On first connection macOS prompts for Local Network access. Deny it and the
cameras never connect, with viewports sitting at "Loading..." and no obvious
cause. System Settings → Privacy & Security → Local Network.

## cvgl caveats

**BGRA requires full colour range, and getting it wrong kills decoding.**
VideoToolbox exposes each pixel format under one specific colour range, and
libavcodec resolves `sw_format` using `avctx->color_range`. FFmpeg 8.1.2
registers BGRA as full-range only, so a stream declaring limited or unspecified
range fails the lookup — and it is fatal rather than a fallback:

```
Failed to map underlying FFmpeg pixel format bgra (unknown range) to a VideoToolbox format!
Failed setup for format videotoolbox_vld: hwaccel initialisation returned error.
```

`QmlAVVideoDecoder::requestBGRAHWFrames()` handles this by probing both ranges
with `av_map_videotoolbox_format_from_pixfmt2()` and aligning `color_range` only
once BGRA frames are certain. Two traps worth knowing if this ever regresses:

- `av_hwframe_ctx_init()` **succeeds** with a BGRA `sw_format` that libavcodec
  will later reject, so the `Requested BGRA HW frames` log line does not prove
  the format was accepted.
- Whether a camera trips this is camera-dependent. Of 16 tested, 12 already
  declared full range and 4 did not — so a partial rollout can look like it
  works fine.

**Expect three one-off errors per stream at startup**, before the first
keyframe. They recover and do not recur:

```
[h264] hardware accelerator failed to decode picture
[h264] vt decoder cb: output image buffer is null: -12909, reconfig 1
[QmlAVDecoder] Unable send packet to decoder: "Unknown error occurred"
```

**The CoreVideo/OpenGL bridge is deprecated** as of macOS 10.14 in favour of
Metal, producing six compiler warnings. It still functions under Qt 5.

**Do not try to "fix" that with Metal under Qt 5.** Qt 5.15 does ship an RHI
path with a Metal backend, but `QtMultimediaQuick` — where the video nodes live
— has no `QRhi`, no `.qsb` and no `QShader`; its shaders are raw GLSL 1.x.
Enabling Metal breaks video output rather than accelerating it. Metal is a Qt 6
conversation, and worth checking first whether Qt 6's FFmpeg multimedia backend
handles VideoToolbox frames natively, since much of this module may then be
deletable rather than portable.

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
