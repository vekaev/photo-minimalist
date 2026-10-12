#!/usr/bin/env bash
# Builds the Mac app, installs it to ~/Applications and restarts it so the newest version is always running.
# The running copy is asked to quit normally first, so its decisions are saved.
set -euo pipefail
cd "$(dirname "$0")/.."

xcodegen generate --quiet
xcodebuild -project HorizonLeveler.xcodeproj -scheme HorizonLeveler -configuration Release \
  -destination "generic/platform=macOS" -derivedDataPath build -quiet build

APP="$HOME/Applications/Photo Minimalist.app"
# Matches the app under its current and its old name (Horizon Leveler).
RUNNING='(Photo Minimalist|Horizon Leveler)\.app/Contents/MacOS/'
if pgrep -f "$RUNNING" >/dev/null; then
  osascript -e 'tell application id "app.horizonleveler.HorizonLeveler" to quit' || true
  # Saving a big folder can take a while; wait until it has really exited (up to 2 minutes).
  for _ in $(seq 1 480); do pgrep -f "$RUNNING" >/dev/null || break; sleep 0.25; done
  if pgrep -f "$RUNNING" >/dev/null; then echo "The running copy didn't quit; not replacing it."; exit 1; fi
fi

mkdir -p "$HOME/Applications"
rm -rf "$HOME/Applications/Horizon Leveler.app"    # the same app under its old name
rm -rf "$APP"
cp -R "build/Build/Products/Release/Photo Minimalist.app" "$APP"
open "$APP"
for _ in $(seq 1 40); do pgrep -f "$RUNNING" >/dev/null && break; sleep 0.25; done
pgrep -f "$RUNNING" >/dev/null || { echo "Failed to start"; exit 1; }
echo "Photo Minimalist restarted with the new build"
