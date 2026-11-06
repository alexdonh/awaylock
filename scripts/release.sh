#!/bin/zsh
# Archive → Developer ID sign → notarize → staple → zip → Sparkle sign + appcast.
# Needs: Config/Local.xcconfig (team, Developer ID identity, bundle ID), real SU_* keys in Base.xcconfig,
#        `xcrun notarytool store-credentials awaylock-notary`, Sparkle's EdDSA key in the login keychain.
set -euo pipefail
cd "$(dirname "$0")/.."

PROFILE=${NOTARY_PROFILE:-awaylock-notary}
OUT=build/release
rm -rf "$OUT" && mkdir -p "$OUT/updates"

xcodebuild -project AwayLock.xcodeproj -scheme AwayLock -configuration Release \
  -archivePath "$OUT/AwayLock.xcarchive" -derivedDataPath build/dd archive

cat > "$OUT/export.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>method</key><string>developer-id</string></dict></plist>
PLIST
xcodebuild -exportArchive -archivePath "$OUT/AwayLock.xcarchive" -exportOptionsPlist "$OUT/export.plist" -exportPath "$OUT"

VERSION=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$OUT/AwayLock.app/Contents/Info.plist")
ZIP="$OUT/updates/AwayLock-$VERSION.zip"

ditto -c -k --keepParent "$OUT/AwayLock.app" "$OUT/notarize.zip"
xcrun notarytool submit "$OUT/notarize.zip" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$OUT/AwayLock.app"
ditto -c -k --keepParent "$OUT/AwayLock.app" "$ZIP"

SPARKLE_BIN=$(find build/dd/SourcePackages/artifacts -type d -path '*Sparkle/bin' | head -1)
"$SPARKLE_BIN/sign_update" "$ZIP"
"$SPARKLE_BIN/generate_appcast" --download-url-prefix "https://github.com/${GITHUB_REPO:-alexdonh/awaylock}/releases/download/v$VERSION/" "$OUT/updates"

echo "Upload $ZIP to GitHub Releases and $OUT/updates/appcast.xml to GitHub Pages."
