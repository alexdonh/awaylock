#!/bin/zsh
# Archive → Developer ID sign → notarize → staple → zip → Sparkle sign + appcast.
# Needs: Config/Local.xcconfig (team, Developer ID identity, bundle ID), real SU_* keys in Base.xcconfig,
#        `xcrun notarytool store-credentials nearby-notary`, Sparkle's EdDSA key in the login keychain.
set -euo pipefail
cd "$(dirname "$0")/.."

PROFILE=${NOTARY_PROFILE:-nearby-notary}
OUT=build/release
rm -rf "$OUT" && mkdir -p "$OUT/updates"

xcodebuild -project Nearby.xcodeproj -scheme Nearby -configuration Release \
  -archivePath "$OUT/Nearby.xcarchive" -derivedDataPath build/dd archive

cat > "$OUT/export.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>method</key><string>developer-id</string></dict></plist>
PLIST
xcodebuild -exportArchive -archivePath "$OUT/Nearby.xcarchive" -exportOptionsPlist "$OUT/export.plist" -exportPath "$OUT"

VERSION=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$OUT/Nearby.app/Contents/Info.plist")
ZIP="$OUT/updates/Nearby-$VERSION.zip"

ditto -c -k --keepParent "$OUT/Nearby.app" "$OUT/notarize.zip"
xcrun notarytool submit "$OUT/notarize.zip" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$OUT/Nearby.app"
ditto -c -k --keepParent "$OUT/Nearby.app" "$ZIP"

SPARKLE_BIN=$(find build/dd/SourcePackages/artifacts -type d -path '*Sparkle/bin' | head -1)
"$SPARKLE_BIN/sign_update" "$ZIP"
"$SPARKLE_BIN/generate_appcast" --download-url-prefix "https://github.com/${GITHUB_REPO:?set GITHUB_REPO=owner/nearby}/releases/download/v$VERSION/" "$OUT/updates"

echo "Upload $ZIP to GitHub Releases and $OUT/updates/appcast.xml to GitHub Pages."
