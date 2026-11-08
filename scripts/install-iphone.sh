#!/usr/bin/env bash
# Puts the iPhone app on your own iPhone, signed with a free Apple account (Xcode's "Personal Team").
# No paid membership needed, but such an install stops opening after 7 days, so this can also refresh it in the
# background before that happens. Your photos and settings stay: a reinstall keeps the app's data.
#
#   scripts/install-iphone.sh               build + install now (iPhone on the same Wi-Fi or on a cable)
#   scripts/install-iphone.sh --if-due      only when the installed copy has under 2 days left (used by the job)
#   scripts/install-iphone.sh --schedule    background job: checks every 6 hours, reinstalls when due
#   scripts/install-iphone.sh --unschedule  turns the job off
#
# First time on the iPhone: Settings ▸ Privacy & Security ▸ Developer Mode (restart), then
# Settings ▸ General ▸ VPN & Device Management ▸ your Apple ID ▸ Trust.
# IPHONE_TEAM=<team id> / IPHONE_DEVICE=<udid> / IPHONE_BUNDLE_ID=<id> override the automatic choice. Log: ~/Library/Logs/photo-minimalist-iphone.log
set -euo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:${PATH:-}"
LABEL="app.horizonleveler.iphone-refresh"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
HOME_DIR="$HOME/Library/Application Support/HorizonLeveler/iphone"
STAMP="$HOME_DIR/expires"   # expiry date of the installed copy (ISO 8601)
TEAM_FILE="$HOME_DIR/team"  # the team chosen once (IPHONE_TEAM=… saves it)
# The phone's copy has its own app ID: a free team can't reuse one another team registered (the project's
# app.horizonleveler.ios stays for the simulator).
BUNDLE_ID="${IPHONE_BUNDLE_ID:-app.horizonleveler.iphone}"
mkdir -p "$HOME_DIR"

# macOS keeps background jobs out of ~/Documents, so the job works from its own copy of the source in
# Application Support: run from the repo, this script refreshes that copy (and itself); the job later
# rebuilds and re-signs exactly the version you installed last.
SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
if [[ -f "$SELF_DIR/../project.yml" ]]; then
  rsync -a --delete --exclude build --exclude dist --exclude .git --exclude '*.xcodeproj' "$SELF_DIR/../" "$HOME_DIR/src/"
  cp "$0" "$HOME_DIR/install-iphone.sh"
fi
LOG="$HOME/Library/Logs/photo-minimalist-iphone.log"
MODE="${1:-now}"

log() { echo "$(date '+%F %T') $*" | tee -a "$LOG"; }
notify() { log "$1"; osascript -e "display notification \"$1\" with title \"Photo Minimalist on iPhone\"" >/dev/null 2>&1 || true; }

case "$MODE" in
  --schedule)
    mkdir -p "$HOME/Library/LaunchAgents" "$HOME/Library/Logs"
    launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
    cat > "$PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key><string>$LABEL</string>
	<key>ProgramArguments</key><array><string>/bin/bash</string><string>$HOME_DIR/install-iphone.sh</string><string>--if-due</string></array>
	<key>StartInterval</key><integer>21600</integer>
	<key>RunAtLoad</key><true/>
	<key>ProcessType</key><string>Background</string>
	<key>StandardOutPath</key><string>/dev/null</string>
	<key>StandardErrorPath</key><string>$LOG</string>
</dict>
</plist>
PLIST
    launchctl bootstrap "gui/$(id -u)" "$PLIST"
    echo "On: every 6 hours the Mac reinstalls the iPhone app when it has under 2 days left. Log: $LOG"
    exit 0 ;;
  --unschedule)
    launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
    rm -f "$PLIST"; echo "Off: the iPhone app is no longer refreshed in the background."; exit 0 ;;
  --if-due|now) ;;
  *) sed -n '2,15p' "$0"; exit 1 ;;
esac

# Due? (Only in --if-due: a manual run always installs.)
if [[ "$MODE" == "--if-due" && -f "$STAMP" ]]; then
  left=$(python3 -c 'import sys,datetime as d; e=d.datetime.fromisoformat(open(sys.argv[1]).read().strip().replace("Z","+00:00")); print(int((e-d.datetime.now(d.timezone.utc)).total_seconds()))' "$STAMP")
  (( left > 2 * 86400 )) && exit 0
fi

# Your iPhone: the first paired physical one that's reachable now.
DEVICE="${IPHONE_DEVICE:-}"
if [[ -z "$DEVICE" ]]; then
  JSON=$(mktemp); trap 'rm -f "$JSON"' EXIT
  xcrun devicectl list devices --json-output "$JSON" >/dev/null 2>&1 || true
  DEVICE=$(python3 - "$JSON" <<'PY'
import json, sys
try: devices = json.load(open(sys.argv[1]))["result"]["devices"]
except Exception: devices = []
for d in devices:
    hw, cp = d.get("hardwareProperties", {}), d.get("connectionProperties", {})
    if hw.get("reality") == "physical" and hw.get("deviceType") == "iPhone" \
       and cp.get("pairingState") == "paired" and cp.get("tunnelState") != "unavailable":
        print(hw.get("udid", "")); break
PY
)
fi
if [[ -z "$DEVICE" ]]; then
  [[ "$MODE" == "--if-due" ]] && { log "iPhone not nearby, will try again in 6 hours"; exit 0; }
  echo "No paired iPhone nearby. Unlock it on the same Wi-Fi as this Mac, or connect a cable."; exit 1
fi

# The team: IPHONE_TEAM (saved for next time), else the saved one, else the first free "Personal Team" in Xcode.
[[ -n "${IPHONE_TEAM:-}" ]] && echo "$IPHONE_TEAM" > "$TEAM_FILE"
[[ -z "${IPHONE_TEAM:-}" && -s "$TEAM_FILE" ]] && IPHONE_TEAM="$(cat "$TEAM_FILE")"
TEAM="${IPHONE_TEAM:-$(defaults export com.apple.dt.Xcode - 2>/dev/null | python3 -c '
import plistlib, sys
teams = plistlib.loads(sys.stdin.buffer.read()).get("IDEProvisioningTeamByIdentifier", {})
print(next((t["teamID"] for ts in teams.values() for t in ts if t.get("isFreeProvisioningTeam")), ""))' || true)}"
[[ -n "$TEAM" ]] || { notify "No Personal Team in Xcode: sign in under Xcode ▸ Settings ▸ Accounts."; exit 1; }

# A free profile lasts 7 days and Xcode reuses it while it's valid: drop ours when it has under 2 days left,
# so the build below gets a fresh one (that's what actually extends the app's life).
for dir in "$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles" "$HOME/Library/MobileDevice/Provisioning Profiles"; do
  for f in "$dir"/*.mobileprovision; do
    [[ -f "$f" ]] || continue
    python3 - "$f" "$TEAM" "$BUNDLE_ID" <<'PY' && { rm -f "$f"; log "dropped an expiring profile, Xcode makes a new one"; } || true
import plistlib, subprocess, sys, datetime as d
p = plistlib.loads(subprocess.run(["security", "cms", "-D", "-i", sys.argv[1]], capture_output=True).stdout)
ok = p.get("TeamIdentifier", [""])[0] == sys.argv[2] and p.get("Name", "").endswith(sys.argv[3]) \
     and p["ExpirationDate"].replace(tzinfo=d.timezone.utc) - d.datetime.now(d.timezone.utc) < d.timedelta(days=2)
sys.exit(0 if ok else 1)
PY
  done
done

log "building for $DEVICE (team $TEAM)"
cd "$HOME_DIR/src"
xcodegen generate --quiet
if ! xcodebuild -project HorizonLeveler.xcodeproj -scheme HorizonLeveler-iOS -configuration Release \
    -destination "id=$DEVICE" -derivedDataPath "$HOME_DIR/build" -allowProvisioningUpdates -allowProvisioningDeviceRegistration \
    DEVELOPMENT_TEAM="$TEAM" CODE_SIGN_STYLE=Automatic PRODUCT_BUNDLE_IDENTIFIER="$BUNDLE_ID" -quiet build >> "$LOG" 2>&1; then
  notify "Couldn't build the iPhone app (see $LOG)."; exit 1
fi
APP="$HOME_DIR/build/Build/Products/Release-iphoneos/Minimalist.app"
if ! xcrun devicectl device install app --device "$DEVICE" "$APP" >> "$LOG" 2>&1; then
  [[ "$MODE" == "--if-due" ]] && { log "install failed (iPhone locked or out of reach?), will try again"; exit 0; }
  echo "Install failed: unlock the iPhone and try again (details in $LOG)."; exit 1
fi
security cms -D -i "$APP/embedded.mobileprovision" 2>/dev/null | plutil -extract ExpirationDate raw - > "$STAMP"
log "installed on the iPhone, works until $(cat "$STAMP")"
