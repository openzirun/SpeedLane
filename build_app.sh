#!/bin/bash
# 编译并打包成 SpeedLane.app
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release

APP="dist/SpeedLane.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/SpeedLane "$APP/Contents/MacOS/"
cp Resources/Info.plist "$APP/Contents/"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"
codesign --force --sign - "$APP"

echo "打包完成: $APP"
