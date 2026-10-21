#!/usr/bin/env bash
# Builds a Release copy of OpenLily, ad-hoc signed (no Apple Developer account needed),
# and packages it as a drag-to-Applications .dmg and a .zip in dist/.
set -euo pipefail
cd "$(dirname "$0")/.."

DERIVED=build/release
DIST=dist
VERSION=$(xcodebuild -project OpenLily.xcodeproj -scheme OpenLily -configuration Release -showBuildSettings 2>/dev/null \
  | awk '$1 == "MARKETING_VERSION" { print $3; exit }')

rm -rf "$DERIVED" "$DIST"
mkdir -p "$DIST"

echo "Building OpenLily $VERSION…"
xcodebuild -project OpenLily.xcodeproj -scheme OpenLily -configuration Release \
  -derivedDataPath "$DERIVED" -destination "generic/platform=macOS" \
  CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= \
  ONLY_ACTIVE_ARCH=NO \
  -quiet clean build

APP="$DERIVED/Build/Products/Release/OpenLily.app"
codesign --verify --deep --strict "$APP"

echo "Packaging…"
ditto -c -k --keepParent "$APP" "$DIST/OpenLily-$VERSION.zip"

STAGE=$(mktemp -d)
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -quiet -volname "OpenLily $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$DIST/OpenLily-$VERSION.dmg"
rm -rf "$STAGE"

(cd "$DIST" && shasum -a 256 OpenLily-* > SHA256SUMS.txt)
echo "Done:"
ls -lh "$DIST"
