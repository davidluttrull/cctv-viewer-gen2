[![License: GPL v3](https://img.shields.io/badge/License-GPLv3-blue.svg)](https://www.gnu.org/licenses/gpl-3.0)
[![cctv-viewer](https://img.shields.io/badge/Launchpad_PPA-daily/latest+git-0e8420?logo=launchpad)](https://launchpad.net/~ievgeny/+archive/ubuntu/cctv-viewer)
[![cctv-viewer](https://snapcraft.io/cctv-viewer/badge.svg)](https://snapcraft.io/cctv-viewer)
[![cctv-viewer](https://snapcraft.io/cctv-viewer/trending.svg?name=0)](https://snapcraft.io/cctv-viewer)

# CCTV Viewer

CCTV Viewer - a simple application for simultaneously viewing multiple video streams. Designed for high performance and low latency.
Based on ffmpeg.

To clone this repository be sure to use the following command:

	git clone --recurse-submodules https://github.com/iEvgeny/cctv-viewer.git

## Install on macOS

Download the latest `.dmg` from
[Releases](https://github.com/davidluttrull/cctv-viewer-stretch/releases), open
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
