#!/bin/bash
# Builds Fan Control.app into ./dist and (re)builds the privileged helper.
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="Fan Control"
BUNDLE_ID="com.local.fancontrol"
DIST="dist"
APP="$DIST/$APP_NAME.app"

echo "==> swift build (release)"
swift build -c release

echo "==> assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp .build/release/FanControlApp "$APP/Contents/MacOS/FanControlApp"
cp .build/release/smcwrite      "$DIST/smcwrite"
cp install-helper.sh            "$APP/Contents/Resources/install-helper.sh"
cp .build/release/smcwrite      "$APP/Contents/Resources/smcwrite"
chmod +x "$APP/Contents/Resources/install-helper.sh"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>FanControlApp</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleName</key><string>$APP_NAME</string>
    <key>CFBundleDisplayName</key><string>$APP_NAME</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
    <key>CFBundleIconFile</key><string>AppIcon</string>
</dict>
</plist>
PLIST

if [ -f Resources/AppIcon.icns ]; then
    cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
fi

echo "==> ad-hoc signing"
# Do not swallow this. A half-signed bundle still launches but makes
# SMAppService.register() fail, so "launch at login" breaks with no visible
# cause. Fail the build instead of shipping that state.
codesign --force --sign - "$APP"

# Install to /Applications and restart, so the running app is always the build
# that was just made. Skip with --no-install when you need the app stopped —
# notably before `swift run selftest`, which drives the same fans and will fight
# a running app.
if [ "${1:-}" != "--no-install" ]; then
    echo "==> installing to /Applications and restarting"
    pkill -f "Fan Control.app" 2>/dev/null && sleep 2
    rm -rf "/Applications/$APP_NAME.app"
    cp -R "$APP" /Applications/
    open "/Applications/$APP_NAME.app"
    sleep 2
    if pgrep -f "Fan Control.app" >/dev/null; then
        echo "   running: /Applications/$APP_NAME.app"
    else
        echo "   WARNING: app did not start" >&2
    fi
fi

echo
echo "Built:  $APP"
echo "Helper: $DIST/smcwrite  (install with: sudo ./install-helper.sh)"
