#!/bin/zsh
# Archive → Developer ID export → notarize + staple the app → DMG → sign, notarize, staple the DMG
# → Sparkle appcast. Output: build/release/updates/{AwayLock-<version>.dmg, appcast.xml}.
#
# Used by .github/workflows/release.yml; runs locally too. Environment:
#   TEAM_ID           Apple team ID; a "Developer ID Application" identity must be in a keychain.
#   NOTARY_KEY_PATH, NOTARY_KEY_ID, NOTARY_ISSUER
#                     App Store Connect API key (CI). Unset: keychain profile $NOTARY_PROFILE
#                     (default awaylock-notary, from `xcrun notarytool store-credentials`).
#   SPARKLE_KEY_FILE  EdDSA private key exported with `generate_keys -x`. Unset: login keychain.
#   RELEASE_NOTES     Optional Markdown file, embedded in the appcast item.
#   GITHUB_REPO       owner/name for download URLs (default alexdonh/awaylock).
set -euo pipefail
cd "$(dirname "$0")/.."

: "${TEAM_ID:?set TEAM_ID to your Apple team ID}"
REPO=${GITHUB_REPO:-alexdonh/awaylock}
OUT=build/release
APP="$OUT/AwayLock.app"
rm -rf "$OUT" && mkdir -p "$OUT/updates" "$OUT/dmg"

notarize() {
  # --wait can return 0 for a rejected submission; the stapler call after it fails instead.
  if [[ -n "${NOTARY_KEY_PATH:-}" ]]; then
    xcrun notarytool submit "$1" --key "$NOTARY_KEY_PATH" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER" --wait
  else
    xcrun notarytool submit "$1" --keychain-profile "${NOTARY_PROFILE:-awaylock-notary}" --wait
  fi
}

echo "==> archive"
xcodebuild -project AwayLock.xcodeproj -scheme AwayLock -configuration Release \
  -archivePath "$OUT/AwayLock.xcarchive" -derivedDataPath build/dd \
  DEVELOPMENT_TEAM="$TEAM_ID" CODE_SIGN_IDENTITY="Developer ID Application" archive

cat > "$OUT/export.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>developer-id</string>
  <key>signingStyle</key><string>manual</string>
  <key>teamID</key><string>$TEAM_ID</string>
</dict></plist>
PLIST
xcodebuild -exportArchive -archivePath "$OUT/AwayLock.xcarchive" -exportOptionsPlist "$OUT/export.plist" -exportPath "$OUT"

plist() { /usr/libexec/PlistBuddy -c "Print $1" "$APP/Contents/Info.plist"; }
VERSION=$(plist CFBundleShortVersionString)
# A placeholder key ships an app that can never update; refuse to build one.
if [[ "$(plist SUPublicEDKey)" == REPLACE* ]]; then
  echo "error: SU_PUBLIC_ED_KEY in Config/Base.xcconfig is still a placeholder" >&2
  exit 1
fi

echo "==> notarize app $VERSION ($(plist CFBundleVersion))"
ditto -c -k --keepParent "$APP" "$OUT/notarize.zip"
notarize "$OUT/notarize.zip"
xcrun stapler staple "$APP"

echo "==> dmg"
IDENTITY=$(codesign -dvv "$APP" 2>&1 | sed -n 's/^Authority=\(Developer ID Application:.*\)$/\1/p')
DMG="$OUT/updates/AwayLock-$VERSION.dmg"
ditto "$APP" "$OUT/dmg/AwayLock.app"
ln -s /Applications "$OUT/dmg/Applications"
hdiutil create -volname AwayLock -srcfolder "$OUT/dmg" -format UDZO -ov "$DMG"
codesign --sign "$IDENTITY" --timestamp "$DMG"
notarize "$DMG"
xcrun stapler staple "$DMG"
spctl -a -t open --context context:primary-signature -v "$DMG"

echo "==> appcast"
[[ -n "${RELEASE_NOTES:-}" ]] && cp "$RELEASE_NOTES" "${DMG%.dmg}.md"
SPARKLE_BIN=$(find build/dd/SourcePackages/artifacts -type d -path '*Sparkle/bin' | head -1)
KEY_ARGS=()
[[ -n "${SPARKLE_KEY_FILE:-}" ]] && KEY_ARGS=(--ed-key-file "$SPARKLE_KEY_FILE")
"$SPARKLE_BIN/generate_appcast" $KEY_ARGS --embed-release-notes \
  --download-url-prefix "https://github.com/$REPO/releases/download/v$VERSION/" \
  --link "https://github.com/$REPO" "$OUT/updates"

echo "Built $DMG and $OUT/updates/appcast.xml"
