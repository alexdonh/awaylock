#!/bin/zsh
# Regenerates scripts/dmg/background.tiff and scripts/dmg/DS_Store (the DMG window's size, icon size
# and positions, and background).
# Run locally after changing the layout (needs a GUI session; macOS asks once to let the terminal
# control Finder). build-dmg.sh copies the result into every DMG, so CI never scripts Finder.
# Positions must match scripts/dmg/background.swift.
set -euo pipefail
cd "$(dirname "$0")"

WORK=$(mktemp -d)
trap 'hdiutil detach "/Volumes/AwayLock" -quiet 2>/dev/null || true; rm -rf "$WORK"' EXIT
mkdir -p "$WORK/src/AwayLock.app/Contents" "$WORK/src/.background"
ln -s /Applications "$WORK/src/Applications"
swift background.swift background.tiff
cp background.tiff "$WORK/src/.background/"

hdiutil detach /Volumes/AwayLock -quiet 2>/dev/null || true
hdiutil create -volname AwayLock -srcfolder "$WORK/src" -format UDRW -ov "$WORK/layout.dmg" -quiet
hdiutil attach "$WORK/layout.dmg" -quiet

# Bounds include the title bar (32 pt), so the content area is 660×400.
osascript <<'APPLESCRIPT'
tell application "Finder"
  tell disk "AwayLock"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set bounds of container window to {200, 120, 860, 552}
    set opts to icon view options of container window
    set arrangement of opts to not arranged
    set icon size of opts to 128
    set text size of opts to 13
    set background picture of opts to file ".background:background.tiff"
    set position of item "AwayLock.app" of container window to {170, 178}
    set position of item "Applications" of container window to {490, 178}
    update without registering applications
    delay 2
    close
  end tell
end tell
APPLESCRIPT

sync
cp /Volumes/AwayLock/.DS_Store DS_Store
echo "Wrote scripts/dmg/background.tiff and scripts/dmg/DS_Store"
