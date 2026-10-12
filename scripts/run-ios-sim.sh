#!/usr/bin/env bash
# Builds the iPhone app and (re)launches it in the "iPhone 17 Pro" simulator (or $SIMULATOR), booting it if needed.
#   scripts/run-ios-sim.sh [folder-inside-the-app-container]   e.g. Documents/Iceland
set -euo pipefail
cd "$(dirname "$0")/.."

# Always the same simulator (other projects may have their own booted ones).
NAME="${SIMULATOR:-iPhone 17 Pro}"
# Prefer one that's already running; several simulators can share a name.
DEVICE=$(xcrun simctl list devices booted | grep -F "    $NAME (" | grep -Eo '[0-9A-F-]{36}' | head -1 || true)
[[ -n "$DEVICE" ]] || DEVICE=$(xcrun simctl list devices available | grep -F "    $NAME (" | grep -Eo '[0-9A-F-]{36}' | head -1)
[[ -n "$DEVICE" ]] || { echo "No simulator named $NAME"; exit 1; }
xcrun simctl list devices booted | grep -q "$DEVICE" || xcrun simctl boot "$DEVICE"

xcodegen generate --quiet
xcodebuild -project HorizonLeveler.xcodeproj -scheme HorizonLeveler-iOS -configuration Debug \
  -destination "platform=iOS Simulator,id=$DEVICE" -derivedDataPath build -quiet build

xcrun simctl install "$DEVICE" build/Build/Products/Debug-iphonesimulator/Minimalist.app
xcrun simctl terminate "$DEVICE" app.horizonleveler.ios 2>/dev/null || true
if [[ -n "${1:-}" ]]; then
  CONTAINER=$(xcrun simctl get_app_container "$DEVICE" app.horizonleveler.ios data)
  xcrun simctl launch "$DEVICE" app.horizonleveler.ios -openFolder "$CONTAINER/$1" >/dev/null
else
  xcrun simctl launch "$DEVICE" app.horizonleveler.ios >/dev/null
fi
echo "Photo Minimalist relaunched in the simulator ($DEVICE)"
