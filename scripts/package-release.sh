#!/bin/bash
# Build a distributable Tauge release: DMG + ZIP + SHA-256 checksums.
#
#   ./scripts/package-release.sh
#
# Signing and notarisation are optional and driven by the environment:
#   TAUGE_SIGN_IDENTITY        "Developer ID Application: Name (TEAMID)"
#   TAUGE_SIGN_KEYCHAIN        Keychain that holds the identity
#   TAUGE_NOTARY_APPLE_ID      Apple ID e-mail
#   TAUGE_NOTARY_TEAM_ID       Apple Developer team identifier
#   TAUGE_NOTARY_PASSWORD      App-specific password for the Apple ID
# or an App Store Connect API key:
#   TAUGE_NOTARY_KEY_PATH      path to AuthKey_XXX.p8
#   TAUGE_NOTARY_KEY_ID        key identifier
#   TAUGE_NOTARY_KEY_ISSUER    issuer UUID
#
# Without a Developer ID identity the app is ad-hoc signed and the DMG/ZIP
# still build. Release artifacts always default to ad-hoc unless
# TAUGE_SIGN_IDENTITY names a Developer ID Application identity.
set -euo pipefail
cd "$(dirname "$0")/.."

APP="dist/Tauge.app"
OUT="dist/release"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"
ARCHS="${TAUGE_ARCHS:-arm64 x86_64}"
DMG="$OUT/Tauge-$VERSION.dmg"
ZIP="$OUT/Tauge-$VERSION.zip"

SIGN_IDENTITY="${TAUGE_SIGN_IDENTITY:-${SHELLX_SIGN_IDENTITY:-}}"
SIGN_KEYCHAIN="${TAUGE_SIGN_KEYCHAIN:-${SHELLX_SIGN_KEYCHAIN:-}}"
DISTRIBUTION_SIGNING=0

if [[ "$SIGN_IDENTITY" == "Developer ID Application"* ]]; then
  FIND_ARGS=(-v -p codesigning)
  if [ -n "$SIGN_KEYCHAIN" ]; then
    FIND_ARGS+=("$SIGN_KEYCHAIN")
  fi
  if security find-identity "${FIND_ARGS[@]}" 2>/dev/null | grep -qF "$SIGN_IDENTITY"; then
    DISTRIBUTION_SIGNING=1
  else
    echo "error: TAUGE_SIGN_IDENTITY names a Developer ID identity that is not available:" >&2
    echo "       $SIGN_IDENTITY" >&2
    exit 1
  fi
elif [ -z "$SIGN_IDENTITY" ]; then
  echo "==> no signing identity: release will be ad-hoc signed"
  export TAUGE_SIGN_IDENTITY="-"
fi

notary_args() {
  if [ -n "${TAUGE_NOTARY_KEY_PATH:-}" ] && [ -n "${TAUGE_NOTARY_KEY_ID:-}" ] && [ -n "${TAUGE_NOTARY_KEY_ISSUER:-}" ]; then
    echo "--key $TAUGE_NOTARY_KEY_PATH --key-id $TAUGE_NOTARY_KEY_ID --issuer $TAUGE_NOTARY_KEY_ISSUER"
  elif [ -n "${TAUGE_NOTARY_APPLE_ID:-}" ] && [ -n "${TAUGE_NOTARY_TEAM_ID:-}" ] && [ -n "${TAUGE_NOTARY_PASSWORD:-}" ]; then
    echo "--apple-id $TAUGE_NOTARY_APPLE_ID --team-id $TAUGE_NOTARY_TEAM_ID --password $TAUGE_NOTARY_PASSWORD"
  fi
}

notarize_submit() {
  local path="$1"
  local args
  args="$(notary_args)"
  echo "==> notarising $path (this can take a few minutes)"
  # shellcheck disable=SC2086
  xcrun notarytool submit "$path" $args --wait
}

rm -rf "$OUT"
mkdir -p "$OUT"

TAUGE_ARCHS="$ARCHS" ./scripts/build-app.sh release

if [ "$DISTRIBUTION_SIGNING" = 1 ] && [ -n "$(notary_args)" ]; then
  # Notarise the app inside a zip first, then staple the ticket to the bundle
  # so the app validates even when the DMG is not present.
  TMP_ZIP="$OUT/.notarize.zip"
  ditto -c -k --sequesterRsrc --keepParent "$APP" "$TMP_ZIP"
  notarize_submit "$TMP_ZIP"
  rm -f "$TMP_ZIP"
  # The ticket belongs to the app bundle; a zip cannot be stapled.
  xcrun stapler staple "$APP"
  xcrun stapler validate "$APP"
elif [ -n "$(notary_args)" ]; then
  echo "==> notarisation credentials present but no Developer ID identity; skipping notarisation"
  echo "    (an ad-hoc/self-signed app cannot be notarised)"
else
  echo "==> no notarisation credentials: skipping notarisation"
  echo "    (set TAUGE_NOTARY_APPLE_ID / TAUGE_NOTARY_TEAM_ID / TAUGE_NOTARY_PASSWORD)"
fi

echo "==> creating $ZIP"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"

echo "==> creating $DMG"
STAGE="$OUT/dmg"
rm -rf "$STAGE"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/Tauge.app"
ln -s /Applications "$STAGE/Applications"
hdiutil create -quiet -volname "Tauge $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$DMG"
rm -rf "$STAGE"

if [ "$DISTRIBUTION_SIGNING" = 1 ]; then
  echo "==> signing disk image"
  DMG_SIGN_ARGS=(--force --timestamp --sign "$TAUGE_SIGN_IDENTITY")
  if [ -n "$SIGN_KEYCHAIN" ]; then
    DMG_SIGN_ARGS+=(--keychain "$SIGN_KEYCHAIN")
  fi
  codesign "${DMG_SIGN_ARGS[@]}" "$DMG"

  if [ -n "$(notary_args)" ]; then
    notarize_submit "$DMG"
    xcrun stapler staple "$DMG"
    xcrun stapler validate "$DMG"
  fi
fi

echo "==> checksums"
(cd "$OUT" && shasum -a 256 "$(basename "$ZIP")" "$(basename "$DMG")" > SHA256SUMS.txt && cat SHA256SUMS.txt)

echo "==> verifying gatekeeper assessment"
spctl --assess --type execute --verbose=2 "$APP" 2>&1 | sed 's/^/    /' || true

echo "==> done"
ls -lh "$OUT"
