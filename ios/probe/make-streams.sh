#!/bin/sh
#
# Extract the camera URLs from this Mac's CCTV Viewer settings into
# ios/probe/streams.json, which the probe app bundles and reads at launch.
#
#     sh ios/probe/make-streams.sh
#
# Why generate it instead of typing the cameras into the probe: the URLs carry
# credentials. Keeping them in a gitignored generated file means no password
# ever reaches the repository, and the probe tests the *real* streams the app
# will have to handle rather than an idealised one. Every URL here comes
# straight out of the layout already saved on this Mac.
#
# The settings file is INI-shaped with one line holding the whole layout
# collection as escaped JSON, so this reads it the way Config does rather than
# pretending it is a plist -- plutil refuses it despite the .plist name.

set -e

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
CONFIG="$HOME/Library/Preferences/org.cctv-viewer.CCTV Viewer.plist"
OUT="$ROOT/ios/probe/streams.json"

[ -f "$CONFIG" ] || {
    echo "error: no CCTV Viewer settings at:" >&2
    echo "  $CONFIG" >&2
    echo "  Run the macOS app once and save a layout first." >&2
    exit 1
}

CONFIG="$CONFIG" OUT="$OUT" python3 - <<'PY'
import json, os, re, sys
from urllib.parse import urlsplit

raw = open(os.environ["CONFIG"], encoding="utf-8", errors="replace").read()
m = re.search(r'^models="(.*)"$', raw, re.M | re.S)
if not m:
    sys.exit("error: no 'models' key in the settings file")

models = json.loads(m.group(1).replace('\\"', '"'))

# The grid URLs are the substreams (subtype=1 on these Dahua cameras) and are
# what a 16-up layout actually decodes; urlHigh is the main stream, used only
# when a viewport goes fullscreen. Keep both -- the probe measures the grid
# first and then one main stream, because those are two different questions.
seen, streams = set(), []
for model in models:
    for item in model.get("items", []):
        url = item.get("url", "")
        if not url.startswith("rtsp://") or url in seen:
            continue
        seen.add(url)
        # urlsplit rather than stripping up to '@': not every camera in the
        # layout has credentials in its URL, and on those the naive strip
        # leaves the scheme behind and every such camera reports as "rtsp".
        host = urlsplit(url).hostname or "?"
        streams.append({"host": host, "url": url, "urlHigh": item.get("urlHigh", "")})

if not streams:
    sys.exit("error: no rtsp:// URLs found in any saved layout")

with open(os.environ["OUT"], "w", encoding="utf-8") as f:
    json.dump({"streams": streams}, f, indent=1)
    f.write("\n")

# Hosts only. The URLs themselves stay out of the terminal, out of any
# transcript, and out of git.
print(f"wrote {len(streams)} streams")
print("hosts: " + ", ".join(s["host"] for s in streams))
PY
