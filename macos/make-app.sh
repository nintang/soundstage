#!/bin/sh
# Builds the native SoundStage.app from the Swift package.
set -e
cd "$(dirname "$0")"

swift build -c release

APP=build/SoundStage.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp .build/release/SoundStage "$APP/Contents/MacOS/SoundStage"
chmod +x "$APP/Contents/MacOS/SoundStage"
cp Info.plist "$APP/Contents/Info.plist"
cp AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# Ad-hoc sign the whole bundle; strip any inherited quarantine so a local open works.
codesign --force --deep -s - --identifier com.dn.soundstage "$APP"
xattr -cr "$APP" 2>/dev/null || true

echo "Built $APP"
echo "Install: ./macos/install.sh   or   cp -R $APP /Applications/"
