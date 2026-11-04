#!/usr/bin/env bash
# Publishes a Mac release that every installed copy updates to through Sparkle ("Check for Updates…").
#
#   scripts/release.sh 0.3.0                 bump the version, build the DMG, sign it, write appcast.xml,
#                                            commit + tag v0.3.0, push, and create the GitHub release
#   scripts/release.sh 0.3.0 notes.md        the same with your own release notes (Markdown-ish text);
#                                            default: the commit subjects since the last tag
#   scripts/release.sh 0.3.0 --local URL     test only: build + sign into dist/ with the feed and download at
#                                            URL (e.g. http://127.0.0.1:8765); no project.yml change, no git, no GitHub
#
# The update signature uses the EdDSA key in your login keychain (account "photo-minimalist", made once with
# build/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_keys --account photo-minimalist). Its public half is
# SUPublicEDKey in project.yml. Lose the private key and installed copies can't update any more: back it up with
#   generate_keys --account photo-minimalist -x ~/somewhere-safe/photo-minimalist-sparkle.key
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:-}"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "Usage: scripts/release.sh 0.3.0 [notes.md | --local URL]"; exit 1; }
LOCAL=""; NOTES_FILE=""
if [[ "${2:-}" == "--local" ]]; then LOCAL="${3:?--local needs a base URL, e.g. http://127.0.0.1:8765}"; else NOTES_FILE="${2:-}"; fi

REPO="vekaev/photo-minimalist"
TAG="v$VERSION"
BIN="build/SourcePackages/artifacts/sparkle/Sparkle/bin"
CURRENT_BUILD=$(grep -m1 'CURRENT_PROJECT_VERSION:' project.yml | grep -o '[0-9]\+')
BUILD=$((CURRENT_BUILD + 1))

if [[ -z "$LOCAL" ]]; then
  [[ -z "$(git status --porcelain)" ]] || { echo "Commit or stash your changes first."; exit 1; }
  [[ "$(git branch --show-current)" == "main" ]] || { echo "Release from main."; exit 1; }
  git rev-parse -q --verify "refs/tags/$TAG" >/dev/null && { echo "$TAG already exists."; exit 1; }
  gh auth status >/dev/null 2>&1 || { echo "Sign in to GitHub first: gh auth login"; exit 1; }
  # Both apps share the version (the iPhone app just keeps in step).
  sed -i '' -E "s/MARKETING_VERSION: \"[^\"]*\"/MARKETING_VERSION: \"$VERSION\"/; s/CURRENT_PROJECT_VERSION: \"[^\"]*\"/CURRENT_PROJECT_VERSION: \"$BUILD\"/" project.yml
  BASE="https://github.com/$REPO/releases/download/$TAG"
  export BUILD_SETTINGS=""
else
  BASE="$LOCAL"
  export BUILD_SETTINGS="MARKETING_VERSION=$VERSION CURRENT_PROJECT_VERSION=$BUILD SPARKLE_FEED_URL=$LOCAL/appcast.xml ${EXTRA_SETTINGS:-}"
fi

scripts/build-app.sh
DMG="dist/PhotoMinimalist-mac.dmg"
[[ -x "$BIN/sign_update" ]] || { echo "Sparkle tools missing in $BIN (build once with Xcode first)."; exit 1; }
SIGNATURE=$("$BIN/sign_update" --account photo-minimalist "$DMG")   # sparkle:edSignature="…" length="…"

# Release notes: the given file, else the commit subjects since the last tag.
NOTES="dist/notes.md"
if [[ -n "$NOTES_FILE" ]]; then cp "$NOTES_FILE" "$NOTES"
else
  LAST=$(git describe --tags --abbrev=0 2>/dev/null || true)
  git log --no-merges --format='- %s' ${LAST:+$LAST..HEAD} | grep -v '^- Release ' > "$NOTES" || true
fi
HTML=$(sed -E 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g; s/^- (.*)$/<li>\1<\/li>/' "$NOTES")

cat > dist/appcast.xml <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Photo Minimalist</title>
    <item>
      <title>Version $VERSION</title>
      <pubDate>$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')</pubDate>
      <sparkle:version>$BUILD</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
      <description><![CDATA[<ul>
$HTML
</ul>]]></description>
      <enclosure url="$BASE/PhotoMinimalist-mac.dmg" type="application/octet-stream" $SIGNATURE />
    </item>
  </channel>
</rss>
XML

if [[ -n "$LOCAL" ]]; then
  echo "Built $DMG and dist/appcast.xml for $VERSION ($BUILD), served from $LOCAL"
  exit 0
fi

git add project.yml
git commit -q -m "Release $VERSION"
git tag "$TAG"
git push -q origin main "$TAG"
gh release create "$TAG" "$DMG" dist/appcast.xml dist/leveler-cli --repo "$REPO" --latest \
  --title "Photo Minimalist $VERSION" --notes-file "$NOTES"
echo "Released $VERSION ($BUILD). Installed copies will offer it within a day, or now via Check for Updates…"
