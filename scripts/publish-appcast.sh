#!/bin/bash
# Publishes build/release/appcast.xml, the signed Sparkle update feed, to GitHub Pages
# (https://roeehrl.github.io/ldmanager/appcast.xml). Run after scripts/release.sh and
# after the GitHub release for this version is published: the feed only goes live once
# its DMG downloads with the exact size, so no app is offered an update it can't fetch.
#
#   scripts/publish-appcast.sh                 the public feed
#   FEED=staging/appcast.xml scripts/publish-appcast.sh
#                                              a test feed (apps opt in with
#                                              defaults write io.github.roeehrl.ldmanager LDMStagingFeedURL …)
#
# GitHub Pages must be enabled once for the repository, serving the gh-pages branch.
set -euo pipefail

cd "$(dirname "$0")/.."
OUT="build/release"
FEED="${FEED:-appcast.xml}"
[ -f "$OUT/appcast.xml" ] || { echo "No $OUT/appcast.xml; run scripts/release.sh first" >&2; exit 1; }

URL=$(sed -n 's/.*<enclosure url="\([^"]*\)".*/\1/p' "$OUT/appcast.xml" | head -1)
WANT=$(sed -n 's/.*length="\([0-9]*\)".*/\1/p' "$OUT/appcast.xml" | head -1)
echo "▸ Checking $URL"
HAVE=$(curl -sIL "$URL" | awk 'tolower($1)=="content-length:" {v=$2} END {print v}' | tr -d '\r')
[ "$HAVE" = "$WANT" ] || { echo "The release asset is $HAVE bytes, the feed says $WANT. Publish the GitHub release first." >&2; exit 1; }

PAGES="build/gh-pages"
git worktree prune
if [ ! -e "$PAGES/.git" ]; then
  if git ls-remote --exit-code --heads origin gh-pages >/dev/null; then
    git fetch -q origin gh-pages
    git worktree add -q -B gh-pages "$PAGES" origin/gh-pages
  else
    # First release: start the branch with nothing but the feed.
    git worktree add -q --orphan -b gh-pages "$PAGES"
    touch "$PAGES/.nojekyll"
    git -C "$PAGES" add .nojekyll
  fi
elif git ls-remote --exit-code --heads origin gh-pages >/dev/null; then
  git -C "$PAGES" pull -q --ff-only origin gh-pages
fi
mkdir -p "$(dirname "$PAGES/$FEED")"
cp "$OUT/appcast.xml" "$PAGES/$FEED"
BUILD=$(sed -n 's/.*<sparkle:version>\([0-9]*\)<.*/\1/p' "$OUT/appcast.xml" | head -1)
git -C "$PAGES" add "$FEED"
git -C "$PAGES" diff --cached --quiet || git -C "$PAGES" commit -q -m "Update feed: build $BUILD ($FEED)"
git -C "$PAGES" push -q origin gh-pages
echo "✓ https://roeehrl.github.io/ldmanager/$FEED (live within a minute)"
