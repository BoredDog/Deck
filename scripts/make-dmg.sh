#!/bin/zsh
# Builds dist/Deck-<version>.dmg for GitHub Releases: Deck.app, an Applications shortcut and a short read-me.
# VERSION=1.2 scripts/make-dmg.sh sets the version (default: the latest git tag, else 1.0).
set -euo pipefail
cd "$(dirname "$0")/.."
export VERSION=${VERSION:-$(git describe --tags --abbrev=0 2>/dev/null || echo 1.0)}
export VERSION=${VERSION#v}
INSTALL=0 scripts/bundle.sh

STAGE=$(mktemp -d)/Deck
mkdir -p "$STAGE" dist
ditto Deck.app "$STAGE/Deck.app"
ln -s /Applications "$STAGE/Applications"
cat > "$STAGE/Read me first.txt" <<'TXT'
Installing Deck

1. Drag Deck onto the Applications folder in this window.
2. Open Applications and right-click Deck, then choose Open, then Open again.
   (Deck isn't notarized by Apple, so macOS asks once. If it only offers "Done",
   go to System Settings > Privacy & Security, scroll down and click "Open Anyway".)
3. Deck lives in the menu bar at the top right of your screen. There's no Dock icon.

To update later, download the new Deck and drag it into Applications to replace the old one.
TXT

DMG="dist/Deck-$VERSION.dmg"
hdiutil create -volname Deck -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$(dirname "$STAGE")"
echo "Made $PWD/$DMG"
