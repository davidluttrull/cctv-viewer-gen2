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

### Updating an AppImage

From v0.1.14 the AppImage updates itself. With
[appimageupdatetool](https://github.com/AppImageCommunity/AppImageUpdate):

	appimageupdatetool -O CCTV_Viewer-*-x86_64.AppImage

Only changed blocks are fetched - a few MB rather than the whole image. `-O`
replaces the file in place; without it a new versioned file is written beside
the old one and every launcher still points at the old one.

Quit the app first, and note it is not named `cctv-viewer`: the kernel truncates
the process name to `cctv-viewer.App`, and there is an `AppRun.wrapped` child
beside it. Killing one and not the other leaves the survivor holding the lock
file in `/tmp`, so the next start aborts with "The application is already
running!" over a blank screen.

	pkill -f '[c]ctv-viewer\.AppImage|[.]mount_cctv'

### Running it as a kiosk

For an unattended wall, run it under systemd rather than an autostart entry, and
let the unit's control-group kill take the whole process tree - that is what
makes an automated update safe. Ready-made units are in
[deploy/linux-kiosk](deploy/linux-kiosk):

	cp deploy/linux-kiosk/*.service deploy/linux-kiosk/*.timer ~/.config/systemd/user/
	cp deploy/linux-kiosk/cctv-viewer-update.sh ~/Apps/
	systemctl --user daemon-reload
	systemctl --user enable --now cctv-viewer.service cctv-viewer-update.timer

The timer checks nightly and stops the wall only when there is something to
install, rolling back to the previous AppImage if the update fails. Disable any
XDG autostart entry for the app first, or you get two instances and the lock
file collision above.

Building from source, hardware decoding and packaging are covered in
[BUILD-linux.md](BUILD-linux.md).

## Updating a manual installation

A source build runs from its build directory, so there is nothing to
re-install - updating means rebuilding the clone your launcher points at.
Deployed clones sit at `~/cctv-viewer-stretch`; the repository has since been
renamed to `cctv-viewer-gen2`, but GitHub redirects the old URL, so an existing
`origin` still pulls.

Stop the running copy first - the app is single-instance, and you are about to
overwrite the binary that is executing:

	pkill -x cctv-viewer

Update and rebuild:

	cd ~/cctv-viewer-stretch
	git pull
	git submodule update --init src/qmlav
	cmake -S . -B build -DCMAKE_BUILD_TYPE=Release
	cmake --build build -j"$(nproc)"

Then restart it the way your launcher does - for a kiosk,
`./build/cctv-viewer -f -k`. Check what you got with
`./build/cctv-viewer --version`.

The submodule step is not optional. `git pull` leaves `src/qmlav` at the old
commit, and the result builds and runs without complaint against the old media
backend.

Settings are untouched: they live in `~/.config/CCTV Viewer/CCTV Viewer.conf`,
outside the source tree.

If a release adds a Qt or QML module, configure fails or the window comes up
blank - re-check the dependencies in [BUILD-linux.md](BUILD-linux.md).

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
