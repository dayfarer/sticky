#!/bin/zsh
# Builds Sticky.app and installs it to ~/Applications.
set -e
cd "$(dirname "$0")"
swift build -c release
APP="$HOME/Applications/Sticky.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/Sticky "$APP/Contents/MacOS/Sticky"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Sticky</string>
  <key>CFBundleIdentifier</key><string>local.sticky</string>
  <key>CFBundleExecutable</key><string>Sticky</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
# Stable identity so keychain "Always Allow" survives rebuilds.
codesign --force --sign - -r='designated => identifier "local.sticky"' "$APP"
echo "Installed $APP"
