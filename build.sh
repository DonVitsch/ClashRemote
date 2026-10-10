#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release --product ClashRemote

APP="dist/Clash Remote.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/ClashRemote "$APP/Contents/MacOS/ClashRemote"
cp Info.plist "$APP/Contents/Info.plist"
cp -R .build/release/ClashRemote_ClashRemote.bundle "$APP/Contents/Resources/"
touch "$APP/Contents/PkgInfo"
printf 'APPL????' > "$APP/Contents/PkgInfo"

if [[ -f AppIcon.icns ]]; then
  cp AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
fi

codesign --force --sign - --timestamp=none "$APP" >/dev/null
echo "Built $APP"
open -R "$APP"
