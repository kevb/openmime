#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
APP="$ROOT/dist/OpenMime.app"
SIGNING_DIR="$ROOT/Config/LocalSigning"
KEYCHAIN="$SIGNING_DIR/OpenMimeDev.keychain-db"
PASSWORD_FILE="$SIGNING_DIR/keychain-password"
IDENTITY="OpenMime Local Development"

cd "$ROOT"
swift build -c release --triple arm64-apple-macosx14.0
swift build -c release --triple x86_64-apple-macosx14.0
ARM_BIN="$(swift build -c release --triple arm64-apple-macosx14.0 --show-bin-path)/OpenMime"
INTEL_BIN="$(swift build -c release --triple x86_64-apple-macosx14.0 --show-bin-path)/OpenMime"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
lipo -create "$ARM_BIN" "$INTEL_BIN" -output "$APP/Contents/MacOS/OpenMime"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/Resources/OpenMime.icns" "$APP/Contents/Resources/OpenMime.icns"
cp "$ROOT/Resources/OpenMimeIcon.png" "$APP/Contents/Resources/OpenMimeIcon.png"

if [[ "${OPENMIME_SIGNING_MODE:-local}" == "adhoc" ]]; then
  # CI has no stable signing identity. Ad-hoc signing verifies bundle integrity
  # without creating a certificate or modifying the runner's trust settings.
  codesign --force --sign - --timestamp=none "$APP"
else
  "$ROOT/Scripts/setup_local_signing.sh" >/dev/null
  PASSWORD="$(<"$PASSWORD_FILE")"
  ORIGINAL_KEYCHAINS=("${(@f)$(security list-keychains -d user | tr -d '"' | sed 's/^[[:space:]]*//')}")
  restore_keychain_search_list() {
    security list-keychains -d user -s "${ORIGINAL_KEYCHAINS[@]}"
  }
  trap restore_keychain_search_list EXIT
  security list-keychains -d user -s "${ORIGINAL_KEYCHAINS[@]}" "$KEYCHAIN"
  security unlock-keychain -p "$PASSWORD" "$KEYCHAIN"
  codesign --force --sign "$IDENTITY" --keychain "$KEYCHAIN" --timestamp=none "$APP"
  restore_keychain_search_list
  trap - EXIT
fi
codesign --verify --deep --strict "$APP"

lipo -archs "$APP/Contents/MacOS/OpenMime"
print "Built universal $APP ($(du -sh "$APP" | awk '{print $1}'))"
