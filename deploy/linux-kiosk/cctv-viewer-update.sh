#!/usr/bin/env bash
# Update the kiosk AppImage, disturbing the wall only when there is something
# to install. Run by cctv-viewer-update.timer; safe to run by hand.
set -uo pipefail

APP="${HOME}/Apps/cctv-viewer.AppImage"
UPD="${HOME}/Apps/appimageupdatetool.AppImage"
UNIT="cctv-viewer.service"

log() { echo "$(date '+%F %T') $*"; }

# --check-for-update: 0 = already current, 1 = update available, anything else
# is an error (no network, GitHub down, malformed release). Only 1 is allowed
# to stop the wall - an error must leave a working kiosk running.
"$UPD" --check-for-update "$APP" >/dev/null 2>&1
rc=$?
case "$rc" in
    0) log "already up to date; wall untouched"; exit 0 ;;
    1) log "update available" ;;
    *) log "update check failed (exit $rc); wall untouched"; exit 0 ;;
esac

cp -f "$APP" "$APP.previous" || { log "could not back up; aborting"; exit 1; }

log "stopping $UNIT"
systemctl --user stop "$UNIT"

if "$UPD" -O "$APP"; then
    chmod +x "$APP"
    log "updated to $("$APP" --version 2>/dev/null | head -1)"
else
    log "update FAILED - rolling back to previous build"
    cp -f "$APP.previous" "$APP"
    chmod +x "$APP"
fi

log "starting $UNIT"
systemctl --user start "$UNIT"
log "done"
