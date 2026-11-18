#!/bin/bash
# Build Tauge.app (ad-hoc signed) using SwiftPM only.
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
export TMPDIR="$PWD/.build/tmp"
export CLANG_MODULE_CACHE_PATH="$PWD/.build/modulecache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/modulecache"
mkdir -p "$TMPDIR" "$CLANG_MODULE_CACHE_PATH"

SPM_FLAGS=(--disable-sandbox --cache-path .swiftpm/cache --config-path .swiftpm/config --security-path .swiftpm/security)

echo "==> swift build -c $CONFIG"
swift build -c "$CONFIG" "${SPM_FLAGS[@]}"

BIN_DIR="$(swift build -c "$CONFIG" "${SPM_FLAGS[@]}" --show-bin-path)"
APP="dist/Tauge.app"

echo "==> assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/ShellX" "$APP/Contents/MacOS/Tauge"
cp Resources/Info.plist "$APP/Contents/Info.plist"
if [ -f Resources/AppIcon.icns ]; then
  cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
fi
if [ -d Sources/ShellXApp/Assets ]; then
  mkdir -p "$APP/Contents/Resources/Assets"
  cp Sources/ShellXApp/Assets/*.png "$APP/Contents/Resources/Assets/"
fi
printf 'APPL????' > "$APP/Contents/PkgInfo"

echo "==> codesign"
# A stable identity keeps the designated requirement (and therefore the Keychain
# ACL grant) valid across rebuilds. See scripts/setup-signing.sh.
SIGN_IDENTITY="${SHELLX_SIGN_IDENTITY:-Tauge Local Signing}"
SIGN_KEYCHAIN="${SHELLX_SIGN_KEYCHAIN:-$HOME/Library/Keychains/tauge-signing.keychain-db}"
SIGN_PASS="${SHELLX_SIGN_PASSWORD:-tauge-local}"
if security find-identity -v -p codesigning "$SIGN_KEYCHAIN" 2>/dev/null | grep -qF "$SIGN_IDENTITY"; then
  security unlock-keychain -p "$SIGN_PASS" "$SIGN_KEYCHAIN" >/dev/null 2>&1 || true
fi
if ! codesign --force --deep --keychain "$SIGN_KEYCHAIN" --identifier com.shellx.app \
     --sign "$SIGN_IDENTITY" "$APP" 2>/dev/null; then
  echo "    (stable signing unavailable; run scripts/setup-signing.sh — falling back to ad-hoc)"
  codesign --force --deep --sign - "$APP"
fi
codesign --verify --verbose "$APP" || true

echo "==> done: $APP"
