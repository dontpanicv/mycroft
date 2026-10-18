#!/usr/bin/env bash
# Builds a universal (arm64 + x86_64) release binary of hands-desktop into desktop/dist/hands-desktop.
#
# The binary is signed ad hoc with the identifier dev.mycroft.hands-desktop. Set CODESIGN_IDENTITY to a Developer ID
# identity to sign it for distribution: macOS ties the Accessibility grant to the signature, so a stable identity keeps
# the grant across rebuilds, while an ad-hoc signature needs the grant again after each build.
set -euo pipefail

cd "$(dirname "$0")/.."

ARCHS=(--arch arm64 --arch x86_64)
swift build -c release "${ARCHS[@]}"
BIN_DIR="$(swift build -c release "${ARCHS[@]}" --show-bin-path)"

mkdir -p dist
cp "$BIN_DIR/hands-desktop" dist/hands-desktop

IDENTITY="${CODESIGN_IDENTITY:--}"
if [[ "$IDENTITY" == "-" ]]; then
    codesign --force --sign - --identifier dev.mycroft.hands-desktop dist/hands-desktop
else
    codesign --force --sign "$IDENTITY" --identifier dev.mycroft.hands-desktop --options runtime --timestamp dist/hands-desktop
fi

echo "Built dist/hands-desktop"
lipo -info dist/hands-desktop
SIZE_BYTES=$(stat -f %z dist/hands-desktop)
echo "Size: ${SIZE_BYTES} bytes ($(du -h dist/hands-desktop | cut -f1))"
