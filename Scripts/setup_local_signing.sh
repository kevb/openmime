#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
SIGNING_DIR="$ROOT/Config/LocalSigning"
KEYCHAIN="$SIGNING_DIR/OpenMimeDev.keychain-db"
PASSWORD_FILE="$SIGNING_DIR/keychain-password"
IDENTITY="OpenMime Local Development"

remove_from_search_list() {
  local current
  current="$(security list-keychains -d user | tr -d '"' | sed 's/^[[:space:]]*//')"
  local -a keychains
  keychains=("${(@f)current}")
  keychains=("${(@)keychains:#$KEYCHAIN}")
  security list-keychains -d user -s "${keychains[@]}"
}

mkdir -p "$SIGNING_DIR"
chmod 700 "$SIGNING_DIR"

if [[ -f "$KEYCHAIN" && -f "$PASSWORD_FILE" ]]; then
  # This keychain is only for codesign. Leaving it in the user's global search
  # list makes unrelated runtime Keychain queries try to unlock it.
  remove_from_search_list
  print "$KEYCHAIN"
  exit 0
fi

PASSWORD="$(openssl rand -hex 24)"
umask 077
print -n "$PASSWORD" > "$PASSWORD_FILE"

openssl req -new -newkey rsa:2048 -x509 -sha256 -days 3650 -nodes \
  -subj "/CN=$IDENTITY/O=OpenMime Local Development" \
  -addext "basicConstraints=critical,CA:false" \
  -addext "keyUsage=digitalSignature" \
  -addext "extendedKeyUsage=codeSigning" \
  -keyout "$SIGNING_DIR/signing-key.pem" \
  -out "$SIGNING_DIR/signing-cert.pem" >/dev/null 2>&1

openssl pkcs12 -export -legacy \
  -inkey "$SIGNING_DIR/signing-key.pem" \
  -in "$SIGNING_DIR/signing-cert.pem" \
  -name "$IDENTITY" \
  -passout "pass:$PASSWORD" \
  -out "$SIGNING_DIR/signing.p12"

security create-keychain -p "$PASSWORD" "$KEYCHAIN"
security set-keychain-settings -lut 21600 "$KEYCHAIN"
security unlock-keychain -p "$PASSWORD" "$KEYCHAIN"
security import "$SIGNING_DIR/signing.p12" -k "$KEYCHAIN" -P "$PASSWORD" -T /usr/bin/codesign >/dev/null
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$PASSWORD" "$KEYCHAIN" >/dev/null
security add-trusted-cert -d -r trustRoot -p codeSign -k "$KEYCHAIN" "$SIGNING_DIR/signing-cert.pem"
remove_from_search_list

print "$KEYCHAIN"
