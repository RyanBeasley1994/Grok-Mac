#!/bin/bash
# Create a stable self-signed "Grok Local" identity so TCC (mic / speech)
# survives rebuilds. Ad-hoc (`codesign --sign -`) uses a new cdhash every
# time, and macOS treats that as a brand-new app.
set -euo pipefail

IDENTITY="${GROK_CODESIGN_IDENTITY:-Grok Local}"
DIR="${GROK_CODESIGN_DIR:-$HOME/.grok/local-codesign}"
KEYCHAIN="$DIR/grok-local.keychain-db"
PASS_FILE="$DIR/keychain.pass"

mkdir -p "$DIR"
chmod 700 "$DIR"

if [[ ! -f "$PASS_FILE" ]]; then
  /usr/bin/openssl rand -base64 24 > "$PASS_FILE"
  chmod 600 "$PASS_FILE"
fi
PASS="$(cat "$PASS_FILE")"

if [[ ! -f "$KEYCHAIN" ]]; then
  security create-keychain -p "$PASS" "$KEYCHAIN"
  security set-keychain-settings -lut 21600 "$KEYCHAIN"
fi

security unlock-keychain -p "$PASS" "$KEYCHAIN"

# Keep it on the search list so `find-identity` and codesign can see it,
# without replacing the login keychain.
EXISTING="$(security list-keychains -d user | tr -d '"')"
if ! printf '%s\n' "$EXISTING" | grep -Fq "$KEYCHAIN"; then
  # shellcheck disable=SC2086
  security list-keychains -d user -s "$KEYCHAIN" $EXISTING
fi

# find-identity -p codesigning stays empty for a self-signed cert that is
# not in the system trust store. codesign still accepts it, and TCC keys
# off the stable designated requirement (certificate root + bundle id).
identity_can_sign() {
  local probe
  probe="$(mktemp)"
  echo probe > "$probe"
  if codesign --force --sign "$IDENTITY" --keychain "$KEYCHAIN" --timestamp=none "$probe" >/dev/null 2>&1; then
    rm -f "$probe"
    return 0
  fi
  rm -f "$probe"
  return 1
}

if identity_can_sign; then
  echo "$IDENTITY"
  exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/openssl.cnf" <<EOF
[ req ]
distinguished_name = req_distinguished_name
prompt = no
x509_extensions = v3_codesign

[ req_distinguished_name ]
CN = $IDENTITY
O = Grok Local

[ v3_codesign ]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
subjectKeyIdentifier = hash
EOF

/usr/bin/openssl req -new -x509 -days 3650 -nodes \
  -newkey rsa:2048 \
  -keyout "$TMP/key.pem" \
  -out "$TMP/cert.pem" \
  -config "$TMP/openssl.cnf"

/usr/bin/openssl pkcs12 -export \
  -inkey "$TMP/key.pem" \
  -in "$TMP/cert.pem" \
  -out "$TMP/identity.p12" \
  -passout pass:tmp \
  -name "$IDENTITY"

security import "$TMP/identity.p12" \
  -k "$KEYCHAIN" \
  -P tmp \
  -A \
  -T /usr/bin/codesign \
  -T /usr/bin/security

security set-key-partition-list \
  -S apple-tool:,apple:,codesign: \
  -s -k "$PASS" "$KEYCHAIN" >/dev/null

if ! identity_can_sign; then
  echo "error: imported $IDENTITY but codesign cannot use it" >&2
  security find-identity -v "$KEYCHAIN" >&2 || true
  exit 1
fi

echo "$IDENTITY"
