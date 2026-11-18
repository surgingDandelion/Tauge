#!/bin/bash
# Build Tauge.app with SwiftPM only.
#
#   ./scripts/build-app.sh [debug|release]
#
# Environment:
#   TAUGE_ARCHS          Space-separated architectures (default: host arch).
#                        Use "arm64 x86_64" for a universal build.
#   TAUGE_SIGN_IDENTITY  Code-signing identity (default: "Tauge Local Signing").
#                        Use "-" to force an ad-hoc signature for distribution.
#   TAUGE_SIGN_KEYCHAIN  Keychain holding the identity (default: local dev keychain).
#   TAUGE_BUILD_NUMBER   Override CFBundleVersion in the assembled bundle.
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
APP="dist/Tauge.app"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"
ARCHS="${TAUGE_ARCHS:-$(uname -m)}"

export TMPDIR="$PWD/.build/tmp"
export CLANG_MODULE_CACHE_PATH="$PWD/.build/modulecache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/modulecache"
mkdir -p "$TMPDIR" "$CLANG_MODULE_CACHE_PATH"

SPM_FLAGS=(--disable-sandbox --cache-path .swiftpm/cache --config-path .swiftpm/config --security-path .swiftpm/security)

echo "==> building Tauge $VERSION ($CONFIG) for: $ARCHS"
BIN_DIRS=()
for ARCH in $ARCHS; do
  if [ "$(uname -m)" = "$ARCH" ] && [ "$ARCHS" = "$(uname -m)" ]; then
    swift build -c "$CONFIG" "${SPM_FLAGS[@]}"
    BIN_DIRS+=("$(swift build -c "$CONFIG" "${SPM_FLAGS[@]}" --show-bin-path)")
  else
    TRIPLE="$ARCH-apple-macosx13.0"
    SCRATCH=".build/$ARCH"
    swift build -c "$CONFIG" "${SPM_FLAGS[@]}" --triple "$TRIPLE" --scratch-path "$SCRATCH"
    BIN_DIRS+=("$(swift build -c "$CONFIG" "${SPM_FLAGS[@]}" --triple "$TRIPLE" --scratch-path "$SCRATCH" --show-bin-path)")
  fi
done

echo "==> assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

if [ "${#BIN_DIRS[@]}" -gt 1 ]; then
  lipo -create "${BIN_DIRS[@]/%//ShellX}" -output "$APP/Contents/MacOS/Tauge"
else
  cp "${BIN_DIRS[0]}/ShellX" "$APP/Contents/MacOS/Tauge"
fi

cp Resources/Info.plist "$APP/Contents/Info.plist"
if [ -n "${TAUGE_BUILD_NUMBER:-}" ]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $TAUGE_BUILD_NUMBER" "$APP/Contents/Info.plist"
fi
if [ -f Resources/AppIcon.icns ]; then
  cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
fi
if [ -d Sources/ShellXApp/Assets ]; then
  mkdir -p "$APP/Contents/Resources/Assets"
  cp Sources/ShellXApp/Assets/*.png "$APP/Contents/Resources/Assets/"
fi

# SwiftPM resource bundles (English localisation) must live beside the app's
# resources so Bundle.module resolves inside the .app.
for BUNDLE in "${BIN_DIRS[0]}"/*.bundle; do
  [ -d "$BUNDLE" ] || continue
  cp -R "$BUNDLE" "$APP/Contents/Resources/"
done

printf 'APPL????' > "$APP/Contents/PkgInfo"

echo "==> codesign"
SIGN_IDENTITY="${TAUGE_SIGN_IDENTITY:-${SHELLX_SIGN_IDENTITY:-Tauge Local Signing}}"
SIGN_KEYCHAIN="${TAUGE_SIGN_KEYCHAIN:-${SHELLX_SIGN_KEYCHAIN:-$HOME/Library/Keychains/tauge-signing.keychain-db}}"
SIGN_PASS="${TAUGE_SIGN_PASSWORD:-${SHELLX_SIGN_PASSWORD:-tauge-local}}"

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

echo "==> done: $APP"
echo "    version: $VERSION"
echo "    archs:   $(lipo -archs "$APP/Contents/MacOS/Tauge" 2>/dev/null || echo unknown)"
