#!/bin/bash
# Build the release disk image: the app plus the /Applications drop target,
# laid out so the window reads as an install step and not as an app to run.
set -e

APP_PATH="$1"
DMG_PATH="$2"
VOLUME_NAME="${3:-Vibe Notch}"

if [ ! -d "$APP_PATH" ] || [ -z "$DMG_PATH" ]; then
    echo "Usage: make-dmg.sh <app-path> <dmg-path> [volume-name]"
    exit 1
fi

APP_NAME="$(basename "$APP_PATH")"
WORK_DIR="$(dirname "$DMG_PATH")/.dmg-build"
STAGE_DIR="$WORK_DIR/stage"
RW_DMG="$WORK_DIR/rw.dmg"

# Icon geometry — the app on the left, /Applications on the right, in a window
# just wide enough to hold both with the drag between them.
WINDOW_LEFT=200
WINDOW_TOP=120
WINDOW_WIDTH=600
WINDOW_HEIGHT=400
ICON_SIZE=100
APP_ICON_X=150
APP_ICON_Y=200
DROP_ICON_X=450
DROP_ICON_Y=200

# Set once the image is attached, so an early exit still unmounts it instead of
# deleting the work directory out from under a mounted volume.
DEVICE=""

cleanup() {
    if [ -n "$DEVICE" ]; then
        hdiutil detach "$DEVICE" -force >/dev/null 2>&1 || true
    fi
    rm -rf "$WORK_DIR"
}
trap cleanup EXIT

rm -rf "$WORK_DIR"
mkdir -p "$STAGE_DIR"

# ditto rather than cp -R: it preserves the extended attributes, and the
# notarization ticket stapled onto the app lives in one of them.
echo "Staging $APP_NAME..."
ditto "$APP_PATH" "$STAGE_DIR/$APP_NAME"

# The whole point of the exercise. Without this the volume holds one launchable
# app and nothing that suggests installing it, so the user runs Vibe Notch off
# the read-only image — where it works until they eject, and never updates.
ln -s /Applications "$STAGE_DIR/Applications"

# A read/write image first: Finder has to be able to write the .DS_Store that
# carries the window size and the icon positions. Slack on top of the content
# size, because an image sized exactly to fit has nowhere to put it.
SIZE_KB=$(( $(du -sk "$STAGE_DIR" | awk '{print $1}') + 51200 ))

# A stale mount of the same volume name would make Finder lay out the wrong
# disk, and the layout would silently not reach this image.
EXISTING_MOUNT="/Volumes/$VOLUME_NAME"
if [ -d "$EXISTING_MOUNT" ]; then
    echo "Detaching stale mount at $EXISTING_MOUNT..."
    hdiutil detach "$EXISTING_MOUNT" -force >/dev/null 2>&1 || true
fi

echo "Creating read/write image..."
hdiutil create \
    -srcfolder "$STAGE_DIR" \
    -volname "$VOLUME_NAME" \
    -fs HFS+ \
    -format UDRW \
    -size "${SIZE_KB}k" \
    -ov "$RW_DMG" >/dev/null

ATTACH_OUTPUT=$(hdiutil attach "$RW_DMG" -readwrite -noverify -noautoopen)
DEVICE=$(echo "$ATTACH_OUTPUT" | grep -E '^/dev/' | head -1 | awk '{print $1}')
MOUNT_POINT=$(echo "$ATTACH_OUTPUT" | sed -n 's|.*\(/Volumes/.*\)$|\1|p' | head -1)

if [ -z "$DEVICE" ] || [ ! -d "$MOUNT_POINT" ]; then
    echo "ERROR: could not mount the image just created."
    echo "$ATTACH_OUTPUT"
    exit 1
fi

detach_image() {
    sync
    hdiutil detach "$DEVICE" >/dev/null 2>&1 \
        || (sleep 2 && hdiutil detach "$DEVICE" -force >/dev/null 2>&1) \
        || true
    DEVICE=""
}

# Driving Finder needs Automation permission for whichever app is running this
# script, and the first run raises a TCC prompt that can be denied or missed.
# The layout is cosmetic and the /Applications link is not, so a refusal costs
# the window arrangement and still ships an installable image.
echo "Applying window layout..."
if ! osascript - "$VOLUME_NAME" "$APP_NAME" \
    "$WINDOW_LEFT" "$WINDOW_TOP" "$WINDOW_WIDTH" "$WINDOW_HEIGHT" \
    "$ICON_SIZE" "$APP_ICON_X" "$APP_ICON_Y" "$DROP_ICON_X" "$DROP_ICON_Y" <<'APPLESCRIPT'
on run argv
    set volName to item 1 of argv
    set appName to item 2 of argv
    set winLeft to (item 3 of argv) as integer
    set winTop to (item 4 of argv) as integer
    set winWidth to (item 5 of argv) as integer
    set winHeight to (item 6 of argv) as integer
    set iconSize to (item 7 of argv) as integer
    set appX to (item 8 of argv) as integer
    set appY to (item 9 of argv) as integer
    set dropX to (item 10 of argv) as integer
    set dropY to (item 11 of argv) as integer

    tell application "Finder"
        tell disk volName
            open
            set current view of container window to icon view
            set toolbar visible of container window to false
            set statusbar visible of container window to false
            set bounds of container window to {winLeft, winTop, winLeft + winWidth, winTop + winHeight}
            set viewOptions to icon view options of container window
            set arrangement of viewOptions to not arranged
            set icon size of viewOptions to iconSize
            set position of item appName of container window to {appX, appY}
            set position of item "Applications" of container window to {dropX, dropY}
            update without registering applications
            close
        end tell
    end tell
end run
APPLESCRIPT
then
    echo "WARNING: Finder would not arrange the window — shipping the image with"
    echo "the default layout. Grant Automation access for Finder to fix it."
fi

# Finder writes .DS_Store lazily; give it a moment to land before unmounting.
sleep 2
detach_image

echo "Compressing..."
rm -f "$DMG_PATH"
hdiutil convert "$RW_DMG" -format UDZO -imagekey zlib-level=9 -o "$DMG_PATH" >/dev/null

echo "DMG created: $DMG_PATH"
