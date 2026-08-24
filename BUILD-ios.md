# Building CCTV Viewer for iPad — spike status

**This is not a port yet.** It is the groundwork plus one measurement tool. It
existed to answer a single question before anyone committed to the large piece
of work (a Qt 6 migration), and as of 2026-08-24 that question is answered on
real hardware — §1 has the number. Read §7 before writing any iOS code.

The build happens on the Mac. State as of 2026-08-24, verified on macOS 26.5.2
(Apple M1 Ultra), Xcode 26.6, iOS SDK 26.5, simulator runtime iOS 26.5, CMake
4.4.2, FFmpeg n8.1.2. Device results are from an iPad Pro 12.9-inch 5th
generation (`iPad13,8`, M1) on iPadOS 26.6.

## 1. The question this spike exists to answer

How many concurrent VideoToolbox decode sessions will iPadOS grant one app?

**At least 32.** Every session got real hardware decode with the app's
single-plane BGRA output, and nothing failed at any count tried:

| sessions | decoding | failed | aggregate | software fallbacks | footprint |
|---|---|---|---|---|---|
| 16 (the 4x4 grid) | 16 | 0 | 479 fps | 0 | 92MB |
| 24 | 24 | 0 | 717 fps | 0 | 145MB |
| 32 | 32 | 0 | 957 fps | 0 | 178MB |

Each run held steady for at least 90 seconds after the last session started.
**32 is a floor, not the limit** — the ceiling was never reached, so it remains
unknown. The grid needs 16, so the hardware has at least double the headroom
the app asks of it.

Throughput is **not** the constraint and never was. The saved 4x4 preset decodes
16 substreams at 704x480 H.264 30fps — roughly 162 Mpixel/s, about two thirds of
a single 4K30 stream, which an M1 media engine handles without noticing. The
fullscreen path is one 2560x1440 or 3840x2160 stream, which is also nothing.
Session *count* is a policy and memory limit rather than a silicon one, so it
cannot be derived — it has to be measured on hardware.

The answer unblocks the decision in §8.

## 2. Prerequisites

- **Full Xcode**, not Command Line Tools. `xcode-select -p` must point inside
  `Xcode.app`. Then `sudo xcodebuild -license accept` — until that is done even
  `/usr/bin/git` refuses to run, which produces baffling failures in scripts
  that never mention Xcode.
- **The iOS platform**, which Xcode 15 and later do not bundle:
  `xcodebuild -downloadPlatform iOS`. A 3-4GB `Xcode.app` is the tell that this
  has not been done.
- For **device** runs only: the paid Apple Developer Program. A free Apple ID
  signs builds that stop launching after 7 days; paid gets a year and up to 100
  devices. The simulator needs neither.
- Two more things device runs need, neither of which the build can do for you,
  and both of which fail in a way that does not name the real cause:
  - **The Apple ID has to be signed in to Xcode** (Settings → Accounts).
    Without it the build stops at `No Accounts: Add a new account in Accounts
    settings`, which reads like a missing tool rather than a missing login.
  - **The iPad has to be registered in the developer account.**
    `-allowProvisioningUpdates` is meant to do this and did not here — it
    failed with `Device "..." isn't registered in your developer account`.
    Register the hardware UDID (§6) by hand at developer.apple.com → Devices.
    Only the Admin and Account Holder roles may, and the 100-device annual
    ceiling resets at renewal rather than rolling.

## 3. Static FFmpeg

```sh
sh ios/make-ffmpeg.sh                # device + simulator
sh ios/make-ffmpeg.sh --device       # one target
sh ios/make-ffmpeg.sh --force        # ignore the up-to-date stamps
```

Output, gitignored, ~29MB of archives per target:

```
build-ios/ffmpeg/prefix/ios-arm64/{lib,include}
build-ios/ffmpeg/prefix/ios-arm64-simulator/{lib,include}
```

Why this exists at all: macOS gets FFmpeg from Homebrew as dylibs found by
pkg-config, and neither half works here. There are no iOS bottles, and iOS
forbids shipping your own dynamic libraries in an app bundle, so everything must
be a static archive linked into the executable.

Four decisions in that script are load-bearing:

- **It clones its own FFmpeg** rather than using `src/qmlav/3rd/FFmpeg`. That
  submodule is pinned at **n5.1.3** for Android, while the macOS build compiles
  against Homebrew's 8.1.2 and the `videotoolbox` branch of qmlav is written
  against the 8.x API (`av_map_videotoolbox_format_from_pixfmt2`,
  `hwcontext_videotoolbox.h`). Building iOS off the submodule would mean
  maintaining two FFmpeg dialects in one codebase. `FFMPEG_TAG` must therefore
  track whatever the Mac links, or iOS silently compiles against an older API.
- **It clones from `git.ffmpeg.org`,** FFmpeg's canonical repository, not the
  GitHub mirror — this project is kept in house and no build should depend on
  GitHub. Verified equivalent rather than assumed: both serve n8.1.2 as
  `1c2c67c0b9f7f66ab32c19dcf7f227bcd290aa4c`.
- **`--disable-autodetect`.** Cross-compiling on a Homebrew Mac, configure will
  otherwise find the host's x264, OpenSSL and a dozen others and emit archives
  referencing libraries no iPad has. Everything wanted must then be named:
  hence `--enable-videotoolbox` and `--enable-zlib` (zlib ships in the SDK).
- **Codecs, muxers and protocols are deliberately left unpruned.** A viewer
  needs no encoders and one muxer, but the dependency graph is not obvious —
  the RTSP demuxer *selects the RTP muxer*, so a plain `--disable-muxers`
  breaks streaming and the failure presents as a network problem. Roughly 25MB
  the linker mostly discards. Prune later, with a device to test on.

`avdevice` stays enabled because `qmlavdemuxer.cpp:37` calls
`avdevice_register_all()` unconditionally.

The verify pass reads `vtool -show-build-version`, not `lipo`. Device and
simulator archives are **both arm64**, so `lipo -archs` reports the same thing
for each and cannot distinguish them; mixing them up is the classic iOS
static-library failure where the link succeeds and the install then refuses.

## 4. The session-count probe

`ios/probe/` is a throwaway measurement tool — no Qt, no rendering. It opens the
real cameras with the same FFmpeg options the app uses, ramps sessions up one at
a time, and reports where it breaks. **§1 is answered, so this directory can go
whenever the port work starts.** It is kept for now only so the measurement can
be repeated on other hardware.

```sh
sh ios/probe/make-streams.sh     # generate the camera list (run first)
sh ios/make-probe.sh             # simulator, 16 sessions, BGRA
sh ios/make-probe.sh --nv12      # skip the BGRA request (see §7)
sh ios/make-probe.sh --sessions 24
sh ios/make-probe.sh --device --team <TEAMID>      # build, install, run on iPad
sh ios/make-probe.sh --device --build-only         # no device needed
```

`make-streams.sh` extracts the URLs from this Mac's saved layout into
`ios/probe/streams.json`. **That file carries camera credentials and is
gitignored — it must never be committed.** Nothing of the kind has ever been in
this repository's history; it was checked. Regenerate it on any machine that
needs it rather than copying it around.

The probe mirrors qmlav deliberately, including the BGRA frames request and the
resync behaviour. A probe that configures VideoToolbox differently from the app
measures a configuration nobody will ship — and both of the probe's own bugs
(§7) came from diverging from qmlav rather than following it.

## 5. Running on the simulator

Two traps, both of which cost time:

- **A headless-booted simulator suspends the app.** `simctl boot` without the
  GUI produces a log that stops after one tick at `up=1s`, which looks exactly
  like a crash. Open the GUI: `open -a Simulator --args -CurrentDeviceUDID <udid>`.
- **Even a simulator bundle must be signed.** Ad-hoc is enough
  (`codesign --force --sign -`), and involves no account or certificate.
  `make-probe.sh` does this already.

**What a simulator run cannot tell you:** the iOS Simulator has **no
VideoToolbox hardware decode**. Every session logs `Failed setup for format
videotoolbox_vld: hwaccel initialisation returned error` and falls back to
`yuvj420p` in system memory. A clean simulator run proves the plumbing — that
the static FFmpeg links, RTSP connects, the decode loop runs — and nothing
whatsoever about §1. The probe's readout says so itself when it sees frames
arriving in system memory.

## 6. Running on a device

Signing is wired up, and one command does the whole job — build, provision,
install, launch:

```sh
sh ios/make-probe.sh --device --team <TEAMID>
sh ios/make-probe.sh --device --team <TEAMID> --sessions 32
sh ios/make-probe.sh --device --team <TEAMID> --nv12
sh ios/make-probe.sh --device --team <TEAMID> --build-only   # no device needed
```

`--team` can come from `DEVELOPMENT_TEAM` in the environment instead. Enable
**Developer Mode** on the iPad first (Settings → Privacy & Security; needs a
restart), connect by cable, tap **Trust**. §2 covers the two account-side
prerequisites, both of which have to be in place before any of this works.

**Tap Allow on the local network prompt** the first time the app runs. iOS 14
and later put unicast connections to LAN addresses behind that permission, and
the cameras are on a private LAN subnet; without it every RTSP connection fails looking
like a network fault. `NSLocalNetworkUsageDescription` is already in
`Info.plist.in`. The grant persists, so only the first run needs the tap, and
the simulator never asks. Keep the app foregrounded — `idleTimerDisabled`
covers screen sleep, not someone swiping away.

The probe never exits on its own, and `devicectl ... --console` waits for the
app to terminate. Run it bounded: background it against a log file, allow the
ramp (sessions × `--ramp` seconds) plus settle time, then interrupt. devicectl
forwards the signal to the app, which exits cleanly.

### Three things the device path needs that the simulator path does not

Every one of these produced a build or an install that looked healthy until it
wasn't, and none of them names its real cause in the failure.

- **`streams.json` has to go through Xcode's Resources phase, not a POST_BUILD
  copy.** Under the Xcode generator `$<TARGET_BUNDLE_DIR:>` expands to a path
  containing a literal `${EFFECTIVE_PLATFORM_NAME}` that nothing substitutes,
  so the copy quietly creates a *sibling directory* named
  `Release${EFFECTIVE_PLATFORM_NAME}` and the bundle ships without the file —
  the probe then dies with its own "no streams.json in the bundle" message. A
  POST_BUILD copy also runs after Xcode signs, so even a correct path would
  leave a file the signature does not cover, which a device refuses to install.
  The Resources phase solves both at once: on iOS it copies to the bundle root,
  and it runs before signing. `ios/probe/CMakeLists.txt` branches on
  `CMAKE_GENERATOR` for this, because the Makefile generator still needs the
  POST_BUILD copy — there, `MACOSX_PACKAGE_LOCATION` really does create a
  `Resources/` subdirectory `NSBundle` never looks in.
- **The device build has to go through `xcodebuild -scheme`, not `cmake
  --build`.** Automatic provisioning only adds a device to the team when
  xcodebuild is told to build *for* that device, and xcodebuild ignores
  `-destination` unless a scheme is passed. It says so, in one warning easily
  lost in the noise: `Ignoring provided run destination because no scheme was
  passed`. `cmake --build` has no way to pass a scheme, hence
  `CMAKE_XCODE_GENERATE_SCHEME` and a direct xcodebuild call in
  `ios/make-probe.sh`. Get this wrong and the build succeeds, signs against a
  profile that provisions some *other* device, and the install fails much later
  with `0xe8008012 This provisioning profile cannot be installed on this
  device`.
- **Two identifiers are in play and they are not interchangeable.**
  `devicectl`'s Identifier column is a CoreDevice UUID, shaped like any other
  UUID (`8-4-4-4-12` hex). Provisioning, `-destination` and the developer portal
  all want the hardware UDID, an entirely different ECID-style string shaped
  `8-16` hex, which `xcrun devicectl device info details` reports as `udid`. `ios/make-probe.sh` resolves the first and converts to the second
  before building, because provisioning has to name the device *before* the
  build, not after it.

Checks worth running on a signed bundle before trying to install it:

```sh
codesign -dv <app>                          # Identifier and TeamIdentifier
codesign --verify --strict --verbose=2 <app>
ls <app>                                    # streams.json at the flat root?
security cms -D -i <app>/embedded.mobileprovision | plutil -p - | \
    sed -n '/ProvisionedDevices/,/]/p'      # is this iPad in the profile?
```

## 7. Findings

### On the device: 32 hardware sessions, none refused

The numbers are in §1. What they settle:

- **Real hardware decode, on every session.** All of them reported
  `fmt=videotoolbox_vld`, and the software-fallback counter stayed at zero for
  every second of every run. The simulator cannot produce this result.
- **BGRA granted every time.** `bgra=1` on all 16, all 24 and all 32.
- **Not one hwaccel init error.** The simulator emitted hundreds.
- **The noisy encoder behaves exactly as qmlav expects.** It produced two `kVTVideoDecoderBadDataErr (-12909)` / "hardware accelerator
  failed to decode picture" events — the same source that motivated qmlav
  commit `4ad8a8f`. The resync absorbed both; those sessions delivered first
  frames and never entered the error state.

### The cameras and the app's options are not the problem

12 cameras on a private subnet plus a 4-channel encoder, all H.264. Host
addresses are deliberately not recorded in this file — the probe reads them from
`streams.json`, generated from local settings and gitignored.
Grid pulls `subtype=1` substreams (704x480, one at 1280x720); fullscreen pulls
`subtype=0` (2560x1440 or 3840x2160). The existing `url`/`urlHigh` split is why
the grid is cheap, and it is the single best thing about this app's chances on
an iPad.

Four streams failed in the simulator. On the Mac, with the probe's *exact*
options plus VideoToolbox, all four decode at a clean 30fps (240 frames in 8s),
and all four encoder streams run **concurrently** at 30fps (360 frames in
12s). There is no per-client concurrency limit and no bad camera.

Two incidental notes worth keeping: the encoder's streams emit
`kVTVideoDecoderBadDataErr (-12909)` even on the Mac — they are the noisy
sources that motivated qmlav commit `4ad8a8f`, and the resync absorbs them. One
camera reports non-monotonic DTS under the probe's tuned options and is clean
with plain defaults; it decodes either way.

### On the device, BGRA costs memory rather than sessions

Same 16 streams, same iPad, one flag apart:

| | sessions | failed | aggregate | footprint |
|---|---|---|---|---|
| BGRA (what the app requests) | 16/16 | 0 | 479 fps | 92MB |
| NV12 (`--nv12`) | 16/16 | 0 | 482 fps | 56MB |

Identical session count, identical throughput. BGRA costs about 36MB more at 16
sessions, roughly 2.3MB per session, which is what four bytes per pixel buys
against NV12's one and a half. At 32 BGRA sessions the footprint was 178MB.
Neither figure matters on this hardware, and BGRA is what the zero-copy render
path wants, so it stays.

### The simulator's BGRA result characterised a path the device never takes

On the simulator, which has no VideoToolbox hardware decode at all, BGRA failed
4 of 16 streams with hundreds of repeating hwaccel errors while NV12 ran all 16
cleanly:

| | sessions | failed | aggregate | hwaccel errors |
|---|---|---|---|---|
| BGRA, simulator | 12/16 | 4 | 361 fps | hundreds, repeating |
| NV12, simulator | 16/16 | 0 | 479 fps | 16 — one per session |

That was measuring the **software fallback path**, which the device never
enters. The defect behind it is still real, though: `requestBGRAHWFrames()`
releases its frames context if anything inside it fails, but the failure it
would need to survive happens *later*, at hwaccel init, after BGRA was already
granted — and nothing recovers from that. It would bite the macOS and Linux
builds on any machine where VideoToolbox or VA-API is unavailable. That makes it
a corner case worth fixing at leisure, not a blocker: on the iPad, VideoToolbox
never declined a session.

**Still untested: what hitting the ceiling looks like.** The original worry was
that a session cap presents exactly like hwaccel init failing, so viewports past
the limit would go black instead of degrading to CPU decode. Nothing failed at
32, so that path was never exercised — the worry is untriggered rather than
disproved, and it is a smaller one now that the grid sits so far inside the
limit.

### Two probe bugs, both from diverging from qmlav

- **SIGSEGV at 0x70, about 1.6s in.** `avcodec_get_hw_frames_parameters()` is
  documented as "meant to get called from the get_format callback" and
  null-derefs on a context that has not reached that point. It was being called
  before `avcodec_open2`. qmlav does it correctly from inside
  `negotiatePixelFormatCb()` — `qmlavdecoder.cpp:294`.
- **Four cameras wrongly reported dead.** The probe counted 61 consecutive
  `avcodec_send_packet` errors and gave up. Per qmlav commit `4ad8a8f`, once
  packet loss corrupts a reference frame libavcodec returns the same error
  indefinitely and has no recovery of its own; the decoder must flush and drop
  packets until the next keyframe. The probe now does that, with `resyncs` and
  `dropped` counters in the readout so a noisy camera is distinguishable from a
  real ceiling.

## 8. The decision this gates

The port target is **Qt 6 with Metal**, for hardware reasons that the M1 iPad
settles. `qmlavhwoutput_videotoolbox.cpp` maps CVPixelBuffers through
`CVOpenGLTextureCache` and `GL_TEXTURE_RECTANGLE`, both desktop-GL-only. The
alternatives were Qt 5 plus `CVOpenGLESTextureCache` — OpenGL ES, deprecated by
Apple years ago, on an unsupported Qt that would have to be built from source —
or Qt 6 plus `CVMetalTextureCache`, which is the same zero-copy shape already
debugged on macOS and eventually unifies the Mac build instead of forking it.

§1 clears the hardware question: 32 concurrent hardware sessions with BGRA on
every one, against the 16 the grid needs. The decoder is not the obstacle, so
what follows is a question of effort rather than feasibility.

The cost is real: Qt 6 removed `QAbstractVideoSurface` and
`QAbstractVideoBuffer`, which qmlav is built on (60 `QVideoFrame`, 22
`QAbstractVideoBuffer`, 6 `QAbstractVideoSurface` references). Migrating that to
`QVideoSink` is the largest single chunk of this project. §1 came first for
exactly that reason, and it came back clean.

Beyond the decoder there is still a **touch UI pass** — 15 `cursorShape`
assignments, 7 `Shortcut` blocks, hover states, a wheel handler, drag-resizable
dividers and a desktop `Window` — and `QtQuick.Dialogs 1.3` (three files) needs
replacing, since its Qt 5 fallback implementation is QQC1-based and a poor bet
in a static iOS build.

## 9. Gotchas

- `.gitignore` has a `*build-*` pattern that also matches `BUILD-ios.md` — this
  file survives only because of the `!BUILD-*.md` negation, the same trap
  documented for `BUILD-macos.md`. A new script named `build-something.sh`
  would be silently ignored; `ios/make-*.sh` avoids it by convention.
- FFmpeg 8 moved component flags out of `config.h` into `config_components.h`.
  Grepping the old file for `CONFIG_RTSP_DEMUXER` finds nothing and looks like a
  misconfigured build.
- `build-ios/` holds an FFmpeg checkout plus archives, a few GB. Gitignored.
- The probe's status strings are written by worker threads and read unlocked by
  the UI timer. A torn read garbles one line for half a second; the counters
  that matter are atomics.
- The device and simulator builds use **different CMake generators** (Xcode and
  Unix Makefiles), so they land the bundle in different places —
  `build-ios/probe-device/Release-iphoneos/cctv-probe.app` against
  `build-ios/probe-simulator/cctv-probe.app`. A build directory also remembers
  which generator made it, and reconfiguring with another one is a hard error
  rather than a regeneration, so `ios/make-probe.sh` clears the tree when the
  generator changes.
- Xcode warns that `UIDeviceFamily` in `Info.plist` "will be overwritten" by
  `TARGETED_DEVICE_FAMILY`. Both say iPhone and iPad here, so the warning is
  noise — but it is the build setting that wins, not the plist.
- `xcrun devicectl device process launch --console` is the only way to see the
  probe's per-second readout without holding the iPad, and it blocks until the
  app exits. Backgrounding it and interrupting on a timer is the pattern in §6.
