[![License: GPL v3](https://img.shields.io/badge/License-GPLv3-blue.svg)](https://www.gnu.org/licenses/gpl-3.0)
[![cctv-viewer](https://img.shields.io/badge/Launchpad_PPA-daily/latest+git-0e8420?logo=launchpad)](https://launchpad.net/~ievgeny/+archive/ubuntu/cctv-viewer)
[![cctv-viewer](https://snapcraft.io/cctv-viewer/badge.svg)](https://snapcraft.io/cctv-viewer)
[![cctv-viewer](https://snapcraft.io/cctv-viewer/trending.svg?name=0)](https://snapcraft.io/cctv-viewer)

# CCTV Viewer

CCTV Viewer - a simple application for simultaneously viewing multiple video streams. Designed for high performance and low latency.
Based on ffmpeg.

To clone this repository be sure to use the following command:

	git clone --recurse-submodules https://github.com/davidluttrull/cctv-viewer-gen2.git

## Install on Linux

Download the latest `.AppImage` from
[Releases](https://github.com/davidluttrull/cctv-viewer-gen2/releases), make it
executable and run it. x86_64, built against Ubuntu 22.04 so it also runs on
newer distributions:

	chmod +x CCTV_Viewer-*-x86_64.AppImage
	./CCTV_Viewer-*-x86_64.AppImage

The AppImage needs FUSE 2 to mount itself. Debian and Ubuntu derivatives ship it
as `libfuse2` (`libfuse2t64` on Ubuntu 24.04 and Linux Mint 22); without it the
app exits complaining it "cannot mount AppImage". To run without installing
anything, extract it instead:

	./CCTV_Viewer-*-x86_64.AppImage --appimage-extract-and-run

Hardware decoding uses VA-API and is on by default. The AppImage deliberately
does not bundle libva, so it uses the host's driver - install the one for your
GPU (`intel-media-va-driver-non-free` on recent Intel, `mesa-va-drivers` on AMD)
if `vainfo` reports no profiles. The app still runs without it, decoding on the
CPU.

Building from source, hardware decoding and packaging are covered in
[BUILD-linux.md](BUILD-linux.md).

## Updating a manual installation

A source build runs straight out of the build directory - nothing is copied into
`/usr`, so there is no package to upgrade and no installer to re-run. Updating
means rebuilding the clone your launcher already points at.

Stop the running copy first. The app is single-instance, and the binary you are
about to overwrite is the one executing:

	pkill -x cctv-viewer

Update the source. `git pull` alone is not enough - it does not move submodules,
so `src/qmlav` stays at the old commit and you rebuild the new application
against the old media backend, with no error to tell you so:

	cd /path/to/cctv-viewer-gen2
	git pull
	git submodule update --init src/qmlav

Rebuild and restart:

	cmake -S . -B build -DCMAKE_BUILD_TYPE=Release
	cmake --build build -j"$(nproc)"
	./build/cctv-viewer

Settings survive all of this untouched. They live in
`~/.config/CCTV Viewer/CCTV Viewer.conf`, outside the source tree, and carry
presets, viewport layouts, kiosk flags and window state across rebuilds. It is a
small text file - copy it somewhere before a big jump if you want a way back.

Three things that catch people out:

**Launcher entries hardcode absolute paths.** A hand-written `.desktop` file
names the binary in full (`Exec=/home/you/cctv-viewer-gen2/build/cctv-viewer`),
and usually the icon too. Renaming or moving the clone breaks every one of them
silently - the menu entry simply stops doing anything. Check
`~/.local/share/applications` and `~/.config/autostart` for entries to repoint.

**A moved or renamed clone needs its build directory deleted.** CMake records
absolute paths in `build/CMakeCache.txt`, so a build tree that no longer sits
where it was configured fails with errors naming the old location. Remove
`build` and configure again; nothing in it is worth keeping.

**Dependencies change between versions.** A newly required Qt or QML module
surfaces either as a `find_package` failure at configure time or as a blank
window at runtime - QML modules are resolved when the app starts, not when it
compiles, so a missing one is not a build error. Re-check the dependency list in
[BUILD-linux.md](BUILD-linux.md) instead of assuming last time's packages still
cover it.

## Install on macOS

Download the latest `.dmg` from
[Releases](https://github.com/davidluttrull/cctv-viewer-gen2/releases), open
it, and drag **cctv-viewer** onto Applications. Apple silicon (M1 and later).

These builds are signed ad-hoc rather than with an Apple Developer ID, so macOS
blocks the app the first time and reports that it "cannot be opened because
Apple cannot check it for malicious software". To allow it, once per machine:
open **System Settings > Privacy & Security**, scroll to Security, find the line
about cctv-viewer being blocked and click **Open Anyway**.

On first connection macOS asks for **Local Network** access. Without it the app
cannot reach cameras and every viewport sits at "Loading...".

Building from source, hardware decoding and packaging are covered in
[BUILD-macos.md](BUILD-macos.md).
