#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
CONFIGURATION="${1:-debug}"
SIGNING_DIR="$ROOT/Config/LocalSigning"
KEYCHAIN="$SIGNING_DIR/OpenMimeDev.keychain-db"
PASSWORD_FILE="$SIGNING_DIR/keychain-password"
IDENTITY="OpenMime Local Development"

if [[ "$CONFIGURATION" != "debug" && "$CONFIGURATION" != "release" ]]; then
  print -u2 "usage: $0 [debug|release]"
  exit 2
fi

cd "$ROOT"
swift build -c "$CONFIGURATION"

BIN_DIR="$(swift build -c "$CONFIGURATION" --show-bin-path)"
APP="$ROOT/dist/OpenMime.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/OpenMime" "$APP/Contents/MacOS/OpenMime"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/Resources/OpenMime.icns" "$APP/Contents/Resources/OpenMime.icns"
cp "$ROOT/Resources/OpenMimeIcon.png" "$APP/Contents/Resources/OpenMimeIcon.png"

"$ROOT/Scripts/setup_local_signing.sh" >/dev/null
PASSWORD="$(<"$PASSWORD_FILE")"

# codesign only resolves identities from the active search list even when
# --keychain is supplied. Add the build-only keychain briefly and always put
# the user's original list back before this script exits.
ORIGINAL_KEYCHAINS=("${(@f)$(security list-keychains -d user | tr -d '"' | sed 's/^[[:space:]]*//')}")
restore_keychain_search_list() {
  security list-keychains -d user -s "${ORIGINAL_KEYCHAINS[@]}"
}
trap restore_keychain_search_list EXIT
security list-keychains -d user -s "${ORIGINAL_KEYCHAINS[@]}" "$KEYCHAIN"
security unlock-keychain -p "$PASSWORD" "$KEYCHAIN"
codesign --force --sign "$IDENTITY" --keychain "$KEYCHAIN" --timestamp=none "$APP"
codesign --verify --deep --strict "$APP"
restore_keychain_search_list
trap - EXIT

SIZE="$(du -sh "$APP" | awk '{print $1}')"
print "Built $APP ($SIZE)"
