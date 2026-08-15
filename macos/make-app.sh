#!/bin/sh
# Builds the native SoundStage.app from the Swift package.
set -e
cd "$(dirname "$0")"

swift build -c release

APP=build/SoundStage.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp .build/release/SoundStage "$APP/Contents/MacOS/SoundStage"
cp Info.plist "$APP/Contents/Info.plist"
cp AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

codesign --force -s - "$APP"
echo "Built $APP"
