#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release
APP_PATH="$PWD/build/MoneyApp.app"
mkdir -p "$APP_PATH/Contents/MacOS" "$APP_PATH/Contents/Resources"
cp .build/release/MoneyApp "$APP_PATH/Contents/MacOS/MoneyApp"
cp Resources/Info.plist "$APP_PATH/Contents/Info.plist"
swift scripts/make-icon.swift build/MoneyApp.iconset
iconutil -c icns build/MoneyApp.iconset -o "$APP_PATH/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$APP_PATH"
printf 'Aplikace: %s\n' "$APP_PATH"
