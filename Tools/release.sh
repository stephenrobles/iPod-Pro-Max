#!/bin/zsh
# Builds a Release app, signs it (Developer ID when available), optionally notarizes, and packages a DMG.
#
# Usage:  Tools/release.sh [--notarize]
#   --notarize   requires a keychain profile named "ipodpromax-notary" created with:
#                xcrun notarytool store-credentials ipodpromax-notary --apple-id you@example.com --team-id J9228F689B
#
# Output: dist/iPod Pro Max <version>.dmg
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
NOTARIZE=0
[[ "${1:-}" == "--notarize" ]] && NOTARIZE=1

BUILD="$ROOT/build/release"
DIST="$ROOT/dist"
rm -rf "$BUILD"
mkdir -p "$BUILD" "$DIST"

echo "▶ Building Release…"
xcodebuild -project "iPod Pro Max.xcodeproj" -scheme "iPod Pro Max" -configuration Release \
  -destination 'platform=macOS' -derivedDataPath "$BUILD/DerivedData" build \
  CODE_SIGN_IDENTITY="-" CODE_SIGNING_ALLOWED=YES 2>&1 | grep -E "error:|warning: .*deprecated|BUILD" | grep -v "^warning" || true

APP="$BUILD/DerivedData/Build/Products/Release/iPod Pro Max.app"
[[ -d "$APP" ]] || { echo "Build failed: app not found"; exit 1; }
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$APP/Contents/Info.plist")
BUILDNUM=$(/usr/libexec/PlistBuddy -c "Print CFBundleVersion" "$APP/Contents/Info.plist")
echo "▶ Version $VERSION ($BUILDNUM)"

# Pick the best signing identity available.
DEVID=$(security find-identity -v -p codesigning | grep -o '"Developer ID Application: [^"]*"' | head -1 | tr -d '"' || true)
if [[ -n "$DEVID" ]]; then
  IDENTITY="$DEVID"
  echo "▶ Signing with $IDENTITY"
else
  IDENTITY=$(security find-identity -v -p codesigning | grep -o '"Apple Development: [^"]*"' | head -1 | tr -d '"' || true)
  echo "⚠︎ No Developer ID Application certificate found. Signing with ${IDENTITY:-ad-hoc} — Gatekeeper will warn other users."
  echo "  Get one at developer.apple.com › Certificates (type: Developer ID Application), install it in Keychain, and rerun."
  [[ -z "$IDENTITY" ]] && IDENTITY="-"
fi
codesign --force --deep --options runtime --timestamp \
  --entitlements "iPod Pro Max/iPod Pro Max.entitlements" \
  --sign "$IDENTITY" "$APP"
codesign --verify --strict --verbose=2 "$APP"

if [[ $NOTARIZE -eq 1 ]]; then
  [[ -n "$DEVID" ]] || { echo "Notarization needs a Developer ID Application certificate."; exit 1; }
  echo "▶ Notarizing app…"
  ZIP="$BUILD/app.zip"
  ditto -c -k --keepParent "$APP" "$ZIP"
  xcrun notarytool submit "$ZIP" --keychain-profile ipodpromax-notary --wait
  xcrun stapler staple "$APP"
fi

echo "▶ Packaging DMG…"
STAGE="$BUILD/dmg"
rm -rf "$STAGE"; mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
DMG="$DIST/iPod Pro Max $VERSION.dmg"
rm -f "$DMG"
hdiutil create -volname "iPod Pro Max" -srcfolder "$STAGE" -ov -format UDZO -imagekey zlib-level=9 "$DMG" > /dev/null
if [[ -n "$DEVID" ]]; then
  codesign --force --timestamp --sign "$DEVID" "$DMG"
  if [[ $NOTARIZE -eq 1 ]]; then
    echo "▶ Notarizing DMG…"
    xcrun notarytool submit "$DMG" --keychain-profile ipodpromax-notary --wait
    xcrun stapler staple "$DMG"
  fi
fi
ls -la "$DMG"
echo "✔ Done: $DMG"
