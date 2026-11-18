#!/bin/bash
# Creates a stable, self-signed code-signing identity for Tauge.
#
# Why: an ad-hoc signature has a designated requirement of "cdhash H"..."",
# and the cdhash changes on every build. The Keychain records that requirement
# when you click 始终允许, so every rebuild invalidates the grant and macOS asks
# for the login-keychain password again. Signing with a fixed certificate makes
# the requirement stable (identifier + certificate leaf), so the grant sticks.
#
# Idempotent. The private key lives in its own keychain with a local password;
# it only signs this app on this machine.
set -euo pipefail

IDENTITY="${SHELLX_SIGN_IDENTITY:-Tauge Local Signing}"
KEYCHAIN="${SHELLX_SIGN_KEYCHAIN:-$HOME/Library/Keychains/tauge-signing.keychain-db}"
PASS="${SHELLX_SIGN_PASSWORD:-tauge-local}"
LOGIN_KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if ! security find-identity -v -p codesigning "$KEYCHAIN" 2>/dev/null | grep -qF "$IDENTITY"; then
  WORK="$(mktemp -d)"
  trap 'rm -rf "$WORK"' EXIT

  cat > "$WORK/openssl.cnf" <<EOF
[req]
distinguished_name = dn
prompt = no
x509_extensions = ext

[dn]
CN = $IDENTITY

[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
subjectKeyIdentifier = hash
EOF

  echo "==> generating self-signed code-signing certificate"
  openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
    -keyout "$WORK/key.pem" -out "$WORK/cert.pem" -config "$WORK/openssl.cnf" >/dev/null 2>&1

  echo "==> importing into $KEYCHAIN"
  if [ ! -f "$KEYCHAIN" ]; then
    security create-keychain -p "$PASS" "$KEYCHAIN"
  fi
  security set-keychain-settings -lut 36000 "$KEYCHAIN"
  security unlock-keychain -p "$PASS" "$KEYCHAIN"
  # OpenSSL 3's default PKCS#12 ciphers are unreadable to macOS' Security framework.
  security import "$WORK/key.pem" -k "$KEYCHAIN" -T /usr/bin/codesign >/dev/null
  security add-certificates -k "$KEYCHAIN" "$WORK/cert.pem" >/dev/null
  security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$PASS" "$KEYCHAIN" >/dev/null

  # Trust the certificate for code signing only, in the user domain (no admin).
  security add-trusted-cert -r trustRoot -p codeSign -k "$LOGIN_KEYCHAIN" "$WORK/cert.pem"
fi

# codesign only searches the keychain search list, so keep ours at the end of it.
if ! security list-keychains -d user | grep -qF "tauge-signing"; then
  SEARCH=()
  while IFS= read -r line; do
    SEARCH+=("$(printf '%s' "$line" | sed 's/^[[:space:]]*"//; s/"$//')")
  done < <(security list-keychains -d user)
  security list-keychains -d user -s "${SEARCH[@]}" "$KEYCHAIN"
fi

security find-identity -v -p codesigning "$KEYCHAIN" | grep -F "$IDENTITY"
echo "==> signing identity ready"
