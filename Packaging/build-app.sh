#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."
CONFIG="${1:-release}"
APP="build/Soundboard.app"
ARCHS=(--arch arm64 --arch x86_64)

swift build -c "$CONFIG" "${ARCHS[@]}" --product SoundboardApp
BIN_DIR="$(swift build -c "$CONFIG" "${ARCHS[@]}" --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN_DIR/SoundboardApp" "$APP/Contents/MacOS/SoundboardApp"
cp Packaging/Info.plist "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

IDENTITY="${CODESIGN_IDENTITY:--}"
codesign --force --options runtime --sign "$IDENTITY" "$APP"
codesign --verify --verbose=2 "$APP"
echo "Oluşturuldu: $APP"
