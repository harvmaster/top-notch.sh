#!/usr/bin/env bash
# Builds a Release "Top NotchSH.app" and packages it into a drag-to-Applications DMG.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="Top NotchSH"
DERIVED="$ROOT/build/release"
DIST="$ROOT/dist"
STAGING="$DIST/dmg"
APP="$DERIVED/Build/Products/Release/$APP_NAME.app"
DMG="$DIST/TopNotchSH.dmg"

if [[ "$(xcode-select -p 2>/dev/null)" == "/Library/Developer/CommandLineTools" ]]; then
  export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
fi

command -v xcodegen >/dev/null || { echo "error: xcodegen not found (brew install xcodegen)" >&2; exit 1; }

echo "Generating project…"
xcodegen generate --spec "$ROOT/project.yml" --project "$ROOT"

echo "Building…"
rm -rf "$DERIVED"
xcodebuild \
  -project "$ROOT/TopNotchSH.xcodeproj" \
  -scheme TopNotchSH \
  -configuration Release \
  -derivedDataPath "$DERIVED" \
  -skipPackagePluginValidation \
  build

echo "Packaging…"
rm -rf "$STAGING" "$DMG"
mkdir -p "$STAGING"
ditto "$APP" "$STAGING/$APP_NAME.app"
ln -s /Applications "$STAGING/Applications"
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGING" -ov -format UDZO "$DMG"
rm -rf "$STAGING"

echo "Done: $DMG"
