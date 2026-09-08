#!/bin/bash
set -euo pipefail

# Build the disk image around an already-notarized, already-stapled Revis.app.
#
# Called by release.sh, which is where the ordering that matters lives: the app is
# notarized and stapled BEFORE it comes in here, so the image is built around a copy
# that already carries its own ticket. Runnable by hand for a look at the layout.
#
# Usage: ./scripts/create-dmg.sh /path/to/Revis.app
#
# Writes build/revis-VERSION.dmg and build/revis-latest.dmg.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
VERSION=$(tr -d '[:space:]' < "$PROJECT_DIR/VERSION")
DMG_NAME="revis-${VERSION}.dmg"
DMG_PATH="$PROJECT_DIR/build/$DMG_NAME"
LATEST_DMG_PATH="$PROJECT_DIR/build/revis-latest.dmg"
VOLUME_NAME="Revis"
# The volume is built under a temporary name and renamed to VOLUME_NAME at the end.
# macOS App Management protects the exact path /Volumes/Revis/Revis.app on a machine
# that has launched the app from a mounted DMG, and blocks writing a bundle there.
# Building under another name keeps the copy on an unguarded path; the rename happens
# once the app is in place, so nothing is ever written to the protected path.
BUILD_VOLUME_NAME="Revis-Installer"
APP_NAME="Revis.app"
# The window size and icon positions are literals inside the AppleScript below, not shell
# variables: the heredoc is quoted so that osascript sees the script rather than an
# expansion of it, and a variable up here would look authoritative while changing nothing.

APP_PATH="${1:-}"
if [ -z "$APP_PATH" ] || [ ! -d "$APP_PATH" ]; then
    echo "Usage: $0 /path/to/Revis.app"
    echo ""
    echo "Normally called by ./scripts/release.sh, which exports and notarizes the app first."
    exit 1
fi

echo "=== Creating DMG: $DMG_NAME ==="

mkdir -p "$PROJECT_DIR/build"
rm -f "$DMG_PATH" "$LATEST_DMG_PATH"

# Detach any stale Revis volumes left mounted by a previous interrupted run (the final
# /Volumes/Revis and the transient /Volumes/Revis-Installer), otherwise hdiutil hits
# "Resource busy" and DMG creation fails.
for dev in $(hdiutil info 2>/dev/null | awk '/\/Volumes\/Revis/ {print $1}'); do
    hdiutil detach "$dev" -force >/dev/null 2>&1 || true
done

STAGING="$PROJECT_DIR/build/dmg-staging"
TEMP_DMG="$PROJECT_DIR/build/temp.dmg"
rm -rf "$STAGING" "$TEMP_DMG"
mkdir -p "$STAGING"

cp -R "$APP_PATH" "$STAGING/$APP_NAME"

APP_SIZE=$(du -sm "$STAGING" | cut -f1)
DMG_SIZE=$(( APP_SIZE + 20 ))

# Build under the temporary volume name so it auto-mounts at /Volumes/Revis-Installer —
# Finder can only script a volume that lives under /Volumes, and this keeps the app off
# the App-Management-protected /Volumes/Revis/Revis.app path.
hdiutil create -size "${DMG_SIZE}m" \
    -volname "$BUILD_VOLUME_NAME" \
    -fs HFS+ \
    -fsargs "-c c=64,a=16,e=16" \
    "$TEMP_DMG"

ATTACH_OUTPUT=$(hdiutil attach -readwrite -owners off -noverify -noautoopen "$TEMP_DMG")
echo "$ATTACH_OUTPUT"
MOUNT_DIR=$(echo "$ATTACH_OUTPUT" | awk '/Apple_HFS/ {for (i = 3; i <= NF; i++) printf "%s%s", $i, (i < NF ? OFS : ORS); exit}')

if [ -z "$MOUNT_DIR" ] || [ ! -d "$MOUNT_DIR" ]; then
    echo "❌ Failed to determine DMG mount point"
    exit 1
fi
VOLUME_DISPLAY_NAME=$(basename "$MOUNT_DIR")

# Give Finder a moment to notice the newly-mounted volume before scripting it.
sleep 2

# `ditto`, not `cp -R`: a re-signed binary leaves a restricted `com.apple.provenance`
# xattr on every file, which `cp -R` cannot replicate onto the HFS+ image ("Operation
# not permitted"). `ditto` copies the bundle intact, signature and stapled ticket and all.
ditto "$STAGING/$APP_NAME" "$MOUNT_DIR/$APP_NAME"
ln -s /Applications "$MOUNT_DIR/Applications"

# Icon size and window layout, via Finder. Finder persists this into .DS_Store inside
# the mounted image, which is what the shipped DMG carries.
LAYOUT_SET=0
for _ in 1 2 3 4 5; do
    if osascript - "$VOLUME_DISPLAY_NAME" << 'APPLESCRIPT'
on run argv
    set volumeName to item 1 of argv
tell application "Finder"
    set desktopBounds to bounds of window of desktop
    set screenWidth to item 3 of desktopBounds
    set screenHeight to item 4 of desktopBounds
    set windowWidth to 640
    set windowHeight to 420
    set leftPos to (screenWidth - windowWidth) div 2
    set topPos to (screenHeight - windowHeight) div 2
    tell disk volumeName
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set bounds of container window to {leftPos, topPos, leftPos + windowWidth, topPos + windowHeight}
        set theViewOptions to icon view options of container window
        set arrangement of theViewOptions to not arranged
        set icon size of theViewOptions to 160
        set text size of theViewOptions to 16
        set background color of theViewOptions to {65535, 65535, 65535}
        set position of item "Revis.app" of container window to {150, 165}
        set position of item "Applications" of container window to {430, 165}
        update without registering applications
        delay 2
        close
        open
        update without registering applications
        delay 2
        close
    end tell
end tell
end run
APPLESCRIPT
    then
        LAYOUT_SET=1
        break
    fi
    sleep 2
done

if [ "$LAYOUT_SET" -ne 1 ]; then
    echo "❌ Finder did not apply the DMG window layout"
    hdiutil detach "$MOUNT_DIR" >/dev/null 2>&1 || true
    exit 1
fi

# Wait for Finder to flush the folder view settings into .DS_Store.
for _ in 1 2 3 4 5; do
    [ -f "$MOUNT_DIR/.DS_Store" ] && break
    sleep 1
done

if [ ! -f "$MOUNT_DIR/.DS_Store" ]; then
    echo "❌ Finder did not persist the DMG window layout (.DS_Store missing)"
    hdiutil detach "$MOUNT_DIR" >/dev/null 2>&1 || true
    exit 1
fi

# The volume wears the app's own icon.
if [ -f "$MOUNT_DIR/$APP_NAME/Contents/Resources/AppIcon.icns" ]; then
    cp "$MOUNT_DIR/$APP_NAME/Contents/Resources/AppIcon.icns" "$MOUNT_DIR/.VolumeIcon.icns"
    SetFile -c icnC "$MOUNT_DIR/.VolumeIcon.icns" 2>/dev/null || true
    SetFile -a V "$MOUNT_DIR/.VolumeIcon.icns" 2>/dev/null || true
    chflags hidden "$MOUNT_DIR/.VolumeIcon.icns" 2>/dev/null || true
    SetFile -a C "$MOUNT_DIR" 2>/dev/null || true
fi

# Finder creates metadata on mounted images. Keep what the appearance needs, remove the
# transient system directories so they do not ship inside the final DMG at all.
rm -rf "$MOUNT_DIR/.fseventsd" "$MOUNT_DIR/.Trashes" 2>/dev/null || true

for hidden_item in ".DS_Store" ".VolumeIcon.icns"; do
    if [ -e "$MOUNT_DIR/$hidden_item" ]; then
        SetFile -a V "$MOUNT_DIR/$hidden_item" 2>/dev/null || true
        chflags hidden "$MOUNT_DIR/$hidden_item" 2>/dev/null || true
    fi
done

chmod -Rf go-w "$MOUNT_DIR" 2>/dev/null || true
sync

# Rename the volume from its build name to the final "Revis". The app is already in
# place, so this never writes a bundle to the guarded /Volumes/Revis/Revis.app path — it
# only relabels the volume. `hdiutil convert` below carries the new name into the shipped
# DMG, so the mounted volume reads "Revis" for the user.
if ! diskutil rename "$MOUNT_DIR" "$VOLUME_NAME" >/dev/null 2>&1; then
    echo "❌ Failed to rename volume to $VOLUME_NAME"
    hdiutil detach "$MOUNT_DIR" -force >/dev/null 2>&1 || true
    exit 1
fi
MOUNT_DIR="/Volumes/$VOLUME_NAME"

# Sweep the transient system dirs AGAIN, now: the rename above remounts the volume and
# macOS recreates .fseventsd/.Trashes on the fresh mount, so the earlier removal does not
# survive into the shipped image. Remove them here and detach promptly so nothing
# repopulates before `convert`.
rm -rf "$MOUNT_DIR/.fseventsd" "$MOUNT_DIR/.Trashes" 2>/dev/null || true
sync

# Unmount — retry, because Finder and Spotlight can briefly hold the volume ("Resource busy").
detach_ok=0
for _ in 1 2 3 4 5; do
    if hdiutil detach "$MOUNT_DIR" >/dev/null 2>&1; then
        detach_ok=1
        break
    fi
    sleep 2
done
if [ "$detach_ok" -ne 1 ]; then
    echo "⚠️  Volume busy; forcing detach"
    hdiutil detach "$MOUNT_DIR" -force
fi

hdiutil convert "$TEMP_DMG" \
    -format UDZO \
    -imagekey zlib-level=9 \
    -o "$DMG_PATH"

rm -f "$TEMP_DMG"
rm -rf "$STAGING"

[ -f "$DMG_PATH" ] || { echo "❌ DMG creation failed"; exit 1; }

cp "$DMG_PATH" "$LATEST_DMG_PATH"

echo ""
echo "=== DMG Created ==="
echo "  Version: $VERSION"
echo "  DMG:     $DMG_PATH"
echo "  Latest:  $LATEST_DMG_PATH"
echo "  Size:    $(du -h "$DMG_PATH" | cut -f1)"
