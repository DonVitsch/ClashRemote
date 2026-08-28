#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="Clash Remote"
APP_PATH="dist/${APP_NAME}.app"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Info.plist 2>/dev/null || echo '1.0')"
DMG_NAME="Clash-Remote-${VERSION}"
STAGE="dist/dmg-stage"
DMG_PATH="dist/${DMG_NAME}.dmg"

if [[ ! -d "$APP_PATH" ]]; then
  echo "Missing $APP_PATH — run ./build.sh first." >&2
  exit 1
fi

rm -rf "$STAGE" "$DMG_PATH"
mkdir -p "$STAGE"
ditto "$APP_PATH" "$STAGE/${APP_NAME}.app"
ln -s /Applications "$STAGE/Applications"

# UDZO compressed read-only image; Applications symlink for drag-install UX
hdiutil create \
  -volname "$APP_NAME" \
  -srcfolder "$STAGE" \
  -ov \
  -format UDZO \
  "$DMG_PATH"

rm -rf "$STAGE"
echo "Created $DMG_PATH"
ls -lh "$DMG_PATH"
