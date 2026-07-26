#!/bin/bash
# Assembles Teainate.app from `swift build` output.
# The CLI is bundled inside so the installed skill can reference an absolute path
# that survives the app being moved to /Applications.
set -euo pipefail

CONFIG="${1:-release}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$ROOT/.build/$CONFIG"
APP="$ROOT/Teainate.app"

swift build -c "$CONFIG" --product TeainateApp
swift build -c "$CONFIG" --product teainate

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"

cp "$BUILD_DIR/TeainateApp" "$APP/Contents/MacOS/TeainateApp"
cp "$BUILD_DIR/teainate"    "$APP/Contents/MacOS/teainate"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"

echo "Built $APP"
