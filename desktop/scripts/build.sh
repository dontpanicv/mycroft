#!/usr/bin/env bash
# Builds Mycroft Hands.app, the macOS desktop helper of hands, into desktop/dist:
#
#   dist/Mycroft Hands.app   bundle id dev.mycroft.hands-desktop, LSUIElement (no Dock icon), with the universal
#                            (arm64 + x86_64) hands-desktop binary in Contents/MacOS
#   dist/MycroftHands.zip    the app, zipped with ditto -c -k --keepParent (what hands install and the phone take)
#
# Signing. macOS keys the Accessibility and Screen Recording grants to the bundle id and the signing team, so an app
# signed with a real identity keeps them across rebuilds and updates; an ad-hoc signature is keyed to the exact build
# and needs both grants again after every build.
#   - CODESIGN_IDENTITY set: that identity (a name or SHA-1 hash), with the hardened runtime and a secure timestamp.
#     CODESIGN_IDENTITY=- forces ad hoc.
#   - otherwise the first "Apple Development" identity in the keychain whose certificate is not revoked (by SHA-1
#     hash, so identically named certificates are not ambiguous), with the hardened runtime;
#   - otherwise ad hoc.
set -euo pipefail

cd "$(dirname "$0")/.."

BUNDLE_ID="dev.mycroft.hands-desktop"
APP="dist/Mycroft Hands.app"
ZIP="dist/MycroftHands.zip"
PLIST="Sources/hands-desktop/Info.plist"

VERSION=$(sed -n 's/^public let handsDesktopVersion = "\(.*\)"$/\1/p' Sources/DesktopCore/Contract.swift)
PLIST_VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST")
if [[ -z "$VERSION" || "$VERSION" != "$PLIST_VERSION" ]]; then
    echo "build.sh: handsDesktopVersion ($VERSION) and $PLIST ($PLIST_VERSION) differ" >&2
    exit 1
fi

ARCHS=(--arch arm64 --arch x86_64)
swift build -c release "${ARCHS[@]}"
BIN_DIR="$(swift build -c release "${ARCHS[@]}" --show-bin-path)"

rm -rf "$APP" "$ZIP" dist/hands-desktop
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/hands-desktop" "$APP/Contents/MacOS/hands-desktop"
cp "$PLIST" "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"
plutil -lint "$APP/Contents/Info.plist" >/dev/null

sign() {
    codesign --force --sign "$1" --identifier "$BUNDLE_ID" "${@:2}" "$APP" 2>/dev/null
}

SIGNED_WITH=""
if [[ -n "${CODESIGN_IDENTITY:-}" && "$CODESIGN_IDENTITY" != "-" ]]; then
    sign "$CODESIGN_IDENTITY" --options runtime --timestamp
    SIGNED_WITH="$CODESIGN_IDENTITY (CODESIGN_IDENTITY, hardened runtime)"
elif [[ "${CODESIGN_IDENTITY:-}" != "-" ]]; then
    # Two certificates may share a name, and a revoked one is still listed as valid: try each by hash, and skip
    # one that Gatekeeper reports as revoked.
    CANDIDATES=$(security find-identity -v -p codesigning 2>/dev/null | awk '/"Apple Development: / { print $2 }')
    for HASH in $CANDIDATES; do
        sign "$HASH" --options runtime || continue
        ASSESSMENT=$(spctl --assess -vv "$APP" 2>&1 || true)
        if [[ "$ASSESSMENT" == *REVOKED* ]]; then
            echo "build.sh: skipping identity $HASH: its certificate is revoked" >&2
            continue
        fi
        NAME=$(security find-identity -v -p codesigning | awk -v id="$HASH" '$2 == id { sub(/^[^"]*/, ""); print; exit }')
        SIGNED_WITH="$NAME [$HASH] (hardened runtime)"
        break
    done
fi
if [[ -z "$SIGNED_WITH" ]]; then
    sign -
    SIGNED_WITH="ad hoc (both grants are needed again after each build)"
fi
codesign --verify --strict "$APP"

# No extended attributes (com.apple.provenance) in the zip: plain unzip would turn them into ._ files.
ditto -c -k --norsrc --noextattr --keepParent "$APP" "$ZIP"

echo "Built $APP $VERSION"
echo "Signed: $SIGNED_WITH"
codesign -dvv "$APP" 2>&1 | grep -E '^(Identifier|TeamIdentifier)=' | sed 's/^/  /'
lipo -info "$APP/Contents/MacOS/hands-desktop"
echo "Zipped $ZIP: $(stat -f %z "$ZIP") bytes, sha256 $(shasum -a 256 "$ZIP" | cut -d' ' -f1)"
