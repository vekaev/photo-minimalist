#!/bin/sh
# Installs (or updates) Photo Minimalist from the latest GitHub release, with no "Open Anyway" step:
#
#   curl -fsSL https://raw.githubusercontent.com/vekaev/photo-minimalist/main/scripts/install.sh | sh
#
# macOS only asks to confirm apps that a browser downloaded (they carry a "downloaded from the internet" mark);
# a download by curl has no such mark, so the app opens right away. After this it updates itself (Sparkle).
# Installs into /Applications, or ~/Applications when it's already there or /Applications isn't writable.
# PM_DEST=<folder> installs elsewhere; PM_NO_OPEN=1 doesn't quit or open the app (for testing).
set -eu

URL="https://github.com/vekaev/photo-minimalist/releases/latest/download/PhotoMinimalist-mac.dmg"
APP="Photo Minimalist.app"
BUNDLE_ID="app.horizonleveler.HorizonLeveler"

if [ -n "${PM_DEST:-}" ]; then DEST="$PM_DEST"
elif [ -d "$HOME/Applications/$APP" ]; then DEST="$HOME/Applications"
elif [ -w /Applications ]; then DEST="/Applications"
else DEST="$HOME/Applications"
fi

TMP=$(mktemp -d)
cleanup() { hdiutil detach -quiet "$TMP/mnt" 2>/dev/null || true; rm -rf "$TMP"; }
trap cleanup EXIT

echo "Downloading Photo Minimalist…"
curl -fL --progress-bar "$URL" -o "$TMP/app.dmg"
hdiutil attach -quiet -nobrowse -noautoopen -mountpoint "$TMP/mnt" "$TMP/app.dmg"

if [ -z "${PM_NO_OPEN:-}" ]; then
  # An older copy that's running quits normally first (its decisions are saved).
  osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
  sleep 1
fi
mkdir -p "$DEST"
rm -rf "$DEST/$APP"
ditto "$TMP/mnt/$APP" "$DEST/$APP"

version=$(defaults read "$DEST/$APP/Contents/Info" CFBundleShortVersionString 2>/dev/null || echo "?")
echo "Installed Photo Minimalist $version in $DEST. It updates itself from now on."
[ -n "${PM_NO_OPEN:-}" ] || open "$DEST/$APP"
