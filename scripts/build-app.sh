#!/usr/bin/env bash
# Builds Horizon Leveler (universal: Apple Silicon + Intel) and packages dist/HorizonLeveler-mac.dmg.
#   scripts/build-app.sh            build the app and the .dmg
#   scripts/build-app.sh --install  also copy the app to ~/Applications and launch it
set -euo pipefail
cd "$(dirname "$0")/.."

command -v xcodegen >/dev/null || { echo "Install XcodeGen first: brew install xcodegen"; exit 1; }
xcodegen generate --quiet

xcodebuild -project HorizonLeveler.xcodeproj -scheme HorizonLeveler -configuration Release \
  -destination "generic/platform=macOS" -derivedDataPath build ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO -quiet build
xcodebuild -project HorizonLeveler.xcodeproj -scheme leveler-cli -configuration Release \
  -destination "generic/platform=macOS" -derivedDataPath build ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO -quiet build

APP="build/Build/Products/Release/HorizonLeveler.app"
rm -rf dist && mkdir -p dist/dmg
cp -R "$APP" "dist/dmg/Horizon Leveler.app"
ln -s /Applications dist/dmg/Applications
hdiutil create -quiet -volname "Horizon Leveler" -srcfolder dist/dmg -ov -format UDZO dist/HorizonLeveler-mac.dmg
cp build/Build/Products/Release/leveler-cli dist/leveler-cli
rm -rf dist/dmg
echo "Built dist/HorizonLeveler-mac.dmg and dist/leveler-cli"

if [[ "${1:-}" == "--install" ]]; then
  mkdir -p ~/Applications
  rm -rf ~/Applications/"Horizon Leveler.app"
  cp -R "$APP" ~/Applications/"Horizon Leveler.app"
  open ~/Applications/"Horizon Leveler.app"
fi
