#!/bin/sh
# Copy a locally built SoundStage.app into /Applications, clear Gatekeeper
# quarantine, and open it. For source builds — release downloads just need
# xattr -dr com.apple.quarantine after moving the .app.
set -e
cd "$(dirname "$0")"

APP="${1:-build/SoundStage.app}"
DEST="/Applications/SoundStage.app"

[ -d "$APP" ] || { echo "error: no app at $APP — run ./macos/make-app.sh first" >&2; exit 1; }

killall SoundStage 2>/dev/null || true
rm -rf "$DEST"
ditto "$APP" "$DEST"
xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true
codesign --force --deep -s - --identifier com.dn.soundstage "$DEST"
open "$DEST"
echo "Installed $DEST"
