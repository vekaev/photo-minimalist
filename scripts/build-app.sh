#!/usr/bin/env bash
# Builds Photo Minimalist (universal: Apple Silicon + Intel) and packages dist/PhotoMinimalist-mac.dmg.
#   scripts/build-app.sh            build the app and the .dmg
#   scripts/build-app.sh --install  also copy the app to ~/Applications and launch it
# Extra build settings (e.g. a version for scripts/release.sh) come in BUILD_SETTINGS="KEY=value KEY=value".
set -euo pipefail
cd "$(dirname "$0")/.."

command -v xcodegen >/dev/null || { echo "Install XcodeGen first: brew install xcodegen"; exit 1; }
xcodegen generate --quiet

xcodebuild -project HorizonLeveler.xcodeproj -scheme HorizonLeveler -configuration Release \
  -destination "generic/platform=macOS" -derivedDataPath build ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO ${BUILD_SETTINGS:-} -quiet build
xcodebuild -project HorizonLeveler.xcodeproj -scheme leveler-cli -configuration Release \
  -destination "generic/platform=macOS" -derivedDataPath build ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO -quiet build

APP="build/Build/Products/Release/Photo Minimalist.app"
rm -rf dist && mkdir -p dist
# The DMG opens on a window: app → Applications with an arrow, and the first-launch hint (Support/DMG).
# dmgbuild writes Finder's window layout without scripting Finder; it lives in a venv under build/.
[[ -x build/dmgvenv/bin/dmgbuild ]] || { python3 -m venv build/dmgvenv && build/dmgvenv/bin/pip install -q dmgbuild; }
build/dmgvenv/bin/dmgbuild -s Support/DMG/dmg-settings.py -D app="$APP" "Photo Minimalist" dist/PhotoMinimalist-mac.dmg >/dev/null
cp build/Build/Products/Release/leveler-cli dist/leveler-cli
echo "Built dist/PhotoMinimalist-mac.dmg and dist/leveler-cli"

if [[ "${1:-}" == "--install" ]]; then
  scripts/install-mac.sh
fi
