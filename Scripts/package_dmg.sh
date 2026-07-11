#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
APP="$ROOT/dist/OpenMime.app"
DMG="$ROOT/dist/OpenMime.dmg"
STAGING="$ROOT/dist/dmg-root"

[[ -d "$APP" ]] || { print -u2 "Build OpenMime.app first"; exit 1; }
rm -rf "$STAGING" "$DMG" "$DMG.sha256"
mkdir -p "$STAGING"
ditto "$APP" "$STAGING/OpenMime.app"
ln -s /Applications "$STAGING/Applications"
hdiutil create -quiet -volname OpenMime -srcfolder "$STAGING" -ov -format UDZO "$DMG"
rm -rf "$STAGING"
hdiutil verify "$DMG"
(cd "$ROOT/dist" && shasum -a 256 OpenMime.dmg > OpenMime.dmg.sha256)
print "Packaged $DMG ($(du -sh "$DMG" | awk '{print $1}'))"
