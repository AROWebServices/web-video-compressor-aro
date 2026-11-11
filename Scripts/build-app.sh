#!/bin/bash
# Builds a release binary and wraps it in a .app bundle under dist/.
#   ./Scripts/build-app.sh            build only
#   ./Scripts/build-app.sh --install  build, then copy the app to /Applications
source "$(dirname "$0")/common.sh"
cd "$ROOT"
VERSION="1.0.0"

swift build -c release --scratch-path "$BUILD_DIR" --product WebVideoCompressor
BIN="$(swift build -c release --scratch-path "$BUILD_DIR" --show-bin-path)/WebVideoCompressor"

APP="$ROOT/dist/$APP_NAME.app"
rm -rf "${APP:?}"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/WebVideoCompressor"
cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>$APP_NAME</string>
    <key>CFBundleDisplayName</key><string>$APP_NAME</string>
    <key>CFBundleIdentifier</key><string>local.webvideocompressor</string>
    <key>CFBundleExecutable</key><string>WebVideoCompressor</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$(git rev-list --count HEAD 2>/dev/null || echo 1)</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.video</string>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST
# Ad-hoc signature with the hardened runtime: enough to run on the Mac that
# built it. No Apple Developer account is involved.
codesign --force --options runtime --sign - "$APP" >/dev/null
echo "Built: $APP"

if [[ "${1:-}" == "--install" ]]; then
    DEST="/Applications/$APP_NAME.app"
    pkill -x WebVideoCompressor 2>/dev/null || true
    rm -rf "${DEST:?}"
    ditto "$APP" "$DEST"
    echo "Installed: $DEST"
fi
