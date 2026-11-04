#!/bin/sh
# Photo Minimalist's card watcher: a LaunchAgent (registered by the app through SMAppService, see
# App/CardWatcher.swift) that runs whenever /Volumes changes. When a volume with a DCIM folder appears
# that wasn't there on the last run, it opens the app, which then shows that card first, also when the
# app wasn't running. The app does nothing else in the background.
BUNDLE_ID="app.horizonleveler.HorizonLeveler"
STATE_DIR="$HOME/Library/Application Support/HorizonLeveler"
STATE="$STATE_DIR/cards-present"
mkdir -p "$STATE_DIR"
touch "$STATE"

cards() { for v in /Volumes/*; do [ -d "$v/DCIM" ] && echo "$v"; done; }

# A mounting card's folder can appear a moment before its files do: look a few times (fast path first).
now=$(cards)
for _ in 1 2 3 4 5 6 7 8; do
  new=$(printf '%s\n' "$now" | grep -vxF -f "$STATE" | grep -v '^$')
  [ -n "$new" ] && break
  sleep 0.25
  now=$(cards)
done

remember() {
  # An ejecting card's folder lingers for a moment: write the list once things have settled, so a card
  # that was just taken out never stays remembered as "in" (the next insert wouldn't count).
  sleep 2
  cards > "$STATE"
}

if [ -z "$new" ]; then remember; exit 0; fi

# Only with Settings ▸ General ▸ "When a memory card is inserted: Open and show it" (the default).
action=$(defaults read "$BUNDLE_ID" cardAction 2>/dev/null || echo open)
if [ "$action" = "open" ]; then
  # Launches the app (it then opens the card in front), or brings the running app forward.
  open -b "$BUNDLE_ID" --args -launchedForCard YES
fi
remember
