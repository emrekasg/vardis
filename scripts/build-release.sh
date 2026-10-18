#!/bin/bash
# Builds the direct-download release into build/dist: Vardis-<version>.dmg, .zip and SHA256SUMS.txt.
#
# Signing is optional. Without these variables the app is ad-hoc signed (fine for local use and
# for people who build from source; downloaded copies need right-click > Open the first time).
#   DEVELOPER_ID_IDENTITY  e.g. "Developer ID Application: Name (TEAMID)"
#   APPLE_TEAM_ID          e.g. ABCDE12345
# Notarization runs when these are also set:
#   NOTARY_APPLE_ID, NOTARY_APP_PASSWORD   (app-specific password)
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION=$(awk -F' = ' '/^MARKETING_VERSION/ {print $2}' Config/Brand.xcconfig)
DIST=build/dist
ARCHIVE=$DIST/Vardis.xcarchive
rm -rf "$DIST" && mkdir -p "$DIST"

command -v xcodegen >/dev/null || { echo "Install xcodegen: brew install xcodegen" >&2; exit 1; }
xcodegen generate --quiet

SIGN_ARGS=(CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual)
if [[ -n "${DEVELOPER_ID_IDENTITY:-}" ]]; then
  SIGN_ARGS=(CODE_SIGN_IDENTITY="$DEVELOPER_ID_IDENTITY" DEVELOPMENT_TEAM="${APPLE_TEAM_ID:?}" CODE_SIGN_STYLE=Manual OTHER_CODE_SIGN_FLAGS=--timestamp)
fi

echo "Archiving Vardis ${VERSION}..."
xcodebuild -project Vardis.xcodeproj -scheme Vardis -configuration Release \
  -archivePath "$ARCHIVE" -destination 'generic/platform=macOS' \
  "${SIGN_ARGS[@]}" archive | grep -E "error:|warning: .*Vardis|ARCHIVE (SUCCEEDED|FAILED)" || true
APP="$ARCHIVE/Products/Applications/Vardis.app"
[[ -d "$APP" ]] || { echo "Archive failed: $APP missing" >&2; exit 1; }
cp -R "$APP" "$DIST/Vardis.app"
codesign --verify --deep --strict "$DIST/Vardis.app"

if [[ -n "${DEVELOPER_ID_IDENTITY:-}" && -n "${NOTARY_APPLE_ID:-}" && -n "${NOTARY_APP_PASSWORD:-}" ]]; then
  echo "Notarizing..."
  ditto -c -k --keepParent "$DIST/Vardis.app" "$DIST/notarize.zip"
  xcrun notarytool submit "$DIST/notarize.zip" --apple-id "$NOTARY_APPLE_ID" \
    --password "$NOTARY_APP_PASSWORD" --team-id "$APPLE_TEAM_ID" --wait
  xcrun stapler staple "$DIST/Vardis.app"
  rm "$DIST/notarize.zip"
fi

echo "Packaging..."
ditto -c -k --keepParent "$DIST/Vardis.app" "$DIST/Vardis-$VERSION.zip"
STAGE=$DIST/dmg && mkdir -p "$STAGE"
cp -R "$DIST/Vardis.app" "$STAGE/" && ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Vardis" -srcfolder "$STAGE" -ov -format UDZO "$DIST/Vardis-$VERSION.dmg" >/dev/null
rm -rf "$STAGE"
if [[ -n "${DEVELOPER_ID_IDENTITY:-}" ]]; then
  codesign --sign "$DEVELOPER_ID_IDENTITY" --timestamp "$DIST/Vardis-$VERSION.dmg"
fi
(cd "$DIST" && shasum -a 256 "Vardis-$VERSION.dmg" "Vardis-$VERSION.zip" > SHA256SUMS.txt)
echo "Done: $DIST"
ls -lh "$DIST" | grep -E "dmg|zip|SHA"
