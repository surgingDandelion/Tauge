#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

APP_PATH="${TAUGE_APP_PATH:-/Applications/Tauge.app}"
DEST_DIR="${TAUGE_CLI_DIR:-/usr/local/bin}"
DEST="$DEST_DIR/tauge"

CLI_SOURCE=""
for candidate in "$PWD/.build/debug/TaugeCLI" "$PWD/.build/release/TaugeCLI" "$APP_PATH/Contents/MacOS/TaugeCLI"; do
  if [ -x "$candidate" ]; then
    CLI_SOURCE="$candidate"
    break
  fi
done
if [ -z "$CLI_SOURCE" ]; then
  echo "Tauge.app was not found at $APP_PATH. Building the CLI from this checkout."
  swift build --disable-sandbox --product TaugeCLI >/dev/null
  CLI_SOURCE="$(swift build --disable-sandbox --product TaugeCLI --show-bin-path)/TaugeCLI"
fi
if [ ! -x "$CLI_SOURCE" ]; then
  echo "Tauge CLI could not be built." >&2
  exit 1
fi

if [ "$DEST_DIR" = "/usr/local/bin" ] && { [ ! -d "$DEST_DIR" ] || [ ! -w "$DEST_DIR" ]; }; then
  DEST_DIR="$HOME/.local/bin"
  DEST="$DEST_DIR/tauge"
fi
mkdir -p "$DEST_DIR"

if [[ "$CLI_SOURCE" == "$PWD/.build/"* ]]; then
  install -m 755 "$CLI_SOURCE" "$DEST"
else
  ln -sfn "$CLI_SOURCE" "$DEST"
fi
echo "Installed $DEST"
echo "Run: tauge machine list"
