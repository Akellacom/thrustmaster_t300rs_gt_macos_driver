#!/bin/bash
# Wraps the ETS2FFControl binary into a macOS .app bundle.
# Result: ./ETS2FFControl.app — double-clickable.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"

echo "Building release…"
swift build -c release

APP_NAME="ETS2FFControl"
APP_DIR="$ROOT/$APP_NAME.app"
CONTENTS="$APP_DIR/Contents"
MACOS="$CONTENTS/MacOS"
RES="$CONTENTS/Resources"

rm -rf "$APP_DIR"
mkdir -p "$MACOS" "$RES"

cp ".build/release/$APP_NAME" "$MACOS/$APP_NAME"
chmod +x "$MACOS/$APP_NAME"

cat > "$CONTENTS/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>              <string>Thrustmaster Wheel Control</string>
    <key>CFBundleDisplayName</key>       <string>Thrustmaster Wheel Control</string>
    <key>CFBundleIdentifier</key>        <string>com.akellacom.ets2ffcontrol</string>
    <key>CFBundleVersion</key>           <string>1.0</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundlePackageType</key>       <string>APPL</string>
    <key>CFBundleExecutable</key>        <string>ETS2FFControl</string>
    <key>LSMinimumSystemVersion</key>    <string>13.0</string>
    <key>NSHighResolutionCapable</key>   <true/>
    <key>NSPrincipalClass</key>          <string>NSApplication</string>
    <key>LSApplicationCategoryType</key> <string>public.app-category.utilities</string>
</dict>
</plist>
PLIST

# Ad-hoc sign so Gatekeeper lets it launch without "unidentified developer"
# grief. This still shows the usual first-launch confirmation.
codesign --force --deep --sign - "$APP_DIR" 2>/dev/null || true

echo "Built $APP_DIR"
echo
echo "To launch: open $APP_DIR"
echo "Make sure the daemon is running first:"
echo "  sudo .build/release/ThrustmasterWheel --range 1080 --ets2"
