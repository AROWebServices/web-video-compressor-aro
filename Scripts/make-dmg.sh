#!/bin/bash
# Builds the app and packs it into a disk image under dist/: open the .dmg on
# another Mac and drag the app onto the Applications shortcut.
source "$(dirname "$0")/common.sh"
"$ROOT/Scripts/build-app.sh"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT/dist/$APP_NAME.app/Contents/Info.plist")"
DMG="$ROOT/dist/$APP_NAME $VERSION.dmg"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

ditto "$ROOT/dist/$APP_NAME.app" "$STAGE/$APP_NAME.app"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG" >/dev/null
echo "Disk image: $DMG"
