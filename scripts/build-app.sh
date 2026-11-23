#!/bin/bash
# Build Tauge.app for Apple silicon with SwiftPM only.
#
#   ./scripts/build-app.sh [debug|release]
#
# Environment:
#   TAUGE_SIGN_IDENTITY  Code-signing identity (default: "Tauge Local Signing").
#                        Use "-" to force an ad-hoc signature for distribution.
#   TAUGE_SIGN_KEYCHAIN  Keychain holding the identity (default: local dev keychain).
#   TAUGE_BUILD_NUMBER   Override CFBundleVersion in the assembled bundle.
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
APP="dist/Tauge.app"
if [ "$(uname -m)" != arm64 ]; then
  echo "error: Build Tauge from a native arm64 shell on an Apple silicon Mac." >&2
  exit 1
fi
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"

export TMPDIR="$PWD/.build/tmp"
export CLANG_MODULE_CACHE_PATH="$PWD/.build/modulecache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/modulecache"
mkdir -p "$TMPDIR" "$CLANG_MODULE_CACHE_PATH"

SPM_FLAGS=(--disable-sandbox --cache-path .swiftpm/cache --config-path .swiftpm/config --security-path .swiftpm/security)

echo "==> building Tauge $VERSION ($CONFIG) for arm64"
swift build -c "$CONFIG" --product Tauge "${SPM_FLAGS[@]}"
swift build -c "$CONFIG" --product TaugeCLI "${SPM_FLAGS[@]}"
BIN_DIR="$(swift build -c "$CONFIG" "${SPM_FLAGS[@]}" --show-bin-path)"
for EXECUTABLE in Tauge TaugeCLI; do
  if [ "$(lipo -archs "$BIN_DIR/$EXECUTABLE")" != arm64 ]; then
    echo "error: Expected an arm64-only $EXECUTABLE executable." >&2
    exit 1
  fi
done

echo "==> assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN_DIR/Tauge" "$BIN_DIR/TaugeCLI" "$APP/Contents/MacOS/"

cp Resources/Info.plist "$APP/Contents/Info.plist"
if [ -n "${TAUGE_BUILD_NUMBER:-}" ]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $TAUGE_BUILD_NUMBER" "$APP/Contents/Info.plist"
fi
if [ -f Resources/AppIcon.icns ]; then
  cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
fi
if [ -d Sources/TaugeApp/Assets ]; then
  mkdir -p "$APP/Contents/Resources/Assets"
  cp Sources/TaugeApp/Assets/*.png "$APP/Contents/Resources/Assets/"
fi

# SwiftPM resource bundles (English localisation) must live in
# Contents/Resources so they are sealed by the app signature. The localisation
# loader looks inside the bundle directly instead of using the generated
# Bundle.module accessor, whose search path differs between SwiftPM toolchains.
for BUNDLE in "$BIN_DIR"/*.bundle; do
  [ -d "$BUNDLE" ] || continue
  NAME="$(basename "$BUNDLE")"
  cp -R "$BUNDLE" "$APP/Contents/Resources/"
  echo "    resource bundle: $NAME"
done

printf 'APPL????' > "$APP/Contents/PkgInfo"

echo "==> codesign"
SIGN_IDENTITY="${TAUGE_SIGN_IDENTITY:-${TAUGE_SIGN_IDENTITY:-Tauge Local Signing}}"
SIGN_KEYCHAIN="${TAUGE_SIGN_KEYCHAIN:-${TAUGE_SIGN_KEYCHAIN:-$HOME/Library/Keychains/tauge-signing.keychain-db}}"
SIGN_PASS="${TAUGE_SIGN_PASSWORD:-${TAUGE_SIGN_PASSWORD:-tauge-local}}"

IDENTITY_ARGS=()
FIND_ARGS=(-v -p codesigning)
if [ -f "$SIGN_KEYCHAIN" ]; then
  security unlock-keychain -p "$SIGN_PASS" "$SIGN_KEYCHAIN" >/dev/null 2>&1 || true
  IDENTITY_ARGS+=(--keychain "$SIGN_KEYCHAIN")
  FIND_ARGS+=("$SIGN_KEYCHAIN")
fi

if [ "$SIGN_IDENTITY" = "-" ]; then
  echo "    (ad-hoc signature requested)"
  codesign --force --deep --identifier com.shellx.app --sign - "$APP"
elif security find-identity "${FIND_ARGS[@]}" 2>/dev/null | grep -qF "$SIGN_IDENTITY"; then
  SIGN_ARGS=(--force --deep --identifier com.shellx.app --sign "$SIGN_IDENTITY" "${IDENTITY_ARGS[@]}")
  case "$SIGN_IDENTITY" in
    "Developer ID Application"*)
      SIGN_ARGS+=(--options runtime --timestamp)
      if [ -f Resources/Tauge.entitlements ]; then
        SIGN_ARGS+=(--entitlements Resources/Tauge.entitlements)
      fi
      ;;
  esac
  codesign "${SIGN_ARGS[@]}" "$APP"
else
  echo "    (identity '$SIGN_IDENTITY' unavailable; signing ad-hoc)"
  echo "    Run scripts/setup-signing.sh for a stable local signature,"
  echo "    or provide a Developer ID Application identity for distribution."
  codesign --force --deep --identifier com.shellx.app --sign - "$APP"
fi
codesign --verify --verbose=1 "$APP" 2>&1 | sed 's/^/    /'

# Load the localisation table from inside the assembled bundle. This catches a
# missing or unreadable resource bundle without launching AppKit, which is how
# the flat SwiftPM layout broke the first 1.0.0 release.
echo "==> verify localization"
"$APP/Contents/MacOS/Tauge" --verify-localization 2>&1 | sed 's/^/    /'

echo "==> done: $APP"
echo "    version: $VERSION"
echo "    arch:    arm64"
