#!/bin/bash
# 构建 App 并打成 DMG(用于 GitHub Releases 分发)
set -euo pipefail
cd "$(dirname "$0")"

./build_app.sh

VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Resources/Info.plist)
DMG="dist/SpeedLane-${VERSION}.dmg"

STAGE=$(mktemp -d)
cp -R dist/SpeedLane.app "$STAGE/"
ln -s /Applications "$STAGE/Applications"

rm -f "$DMG"
hdiutil create -volname "SpeedLane" -srcfolder "$STAGE" -ov -format UDZO "$DMG"
rm -rf "$STAGE"

echo "生成: $DMG"
