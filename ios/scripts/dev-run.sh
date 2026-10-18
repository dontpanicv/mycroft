#!/usr/bin/env bash
# Build, install and launch Mycroft on a Simulator, handing over credentials from this Mac (development only).
#
#   scripts/dev-run.sh [SIMULATOR_UDID]
#
# - ~/.codex/auth.json (your ChatGPT sign-in from Codex) is copied into the app and moved into its keychain on launch.
#   Both apps then hold the same refresh token; whichever refreshes first logs the other out. Fine for a Simulator,
#   use the in-app device-code sign-in on your iPhone.
# - The Jev key is read from the macOS keychain (service mycroft.jev, account jev) and moved into the app's keychain.
set -euo pipefail
cd "$(dirname "$0")/.."

UDID="${1:-$(xcrun simctl list devices available | sed -n '/-- iOS 27/,/--/p' | grep -m1 'iPhone 17 Pro (' | grep -oE '[0-9A-F-]{36}')}"
BUNDLE_ID="$(sed -n 's/^MYCROFT_BUNDLE_ID = //p' Config/Local.xcconfig 2>/dev/null || true)"
BUNDLE_ID="${BUNDLE_ID:-dev.mycroft.app}"

xcodegen generate --quiet
xcrun simctl boot "$UDID" 2>/dev/null || true
open "$(xcode-select -p)/Applications/Simulator.app" --args -CurrentDeviceUDID "$UDID" || true
xcodebuild -project Mycroft.xcodeproj -scheme Mycroft -destination "platform=iOS Simulator,id=$UDID" \
  -derivedDataPath build/DerivedData build -quiet
xcrun simctl install "$UDID" build/DerivedData/Build/Products/Debug-iphonesimulator/Mycroft.app

DATA="$(xcrun simctl get_app_container "$UDID" "$BUNDLE_ID" data)"
mkdir -p "$DATA/Documents/import"
if [[ -f "$HOME/.codex/auth.json" && "${SKIP_CODEX_AUTH:-0}" != 1 ]]; then
  install -m 600 "$HOME/.codex/auth.json" "$DATA/Documents/import/codex-auth.json"
  echo "handed over ~/.codex/auth.json"
fi
if security find-generic-password -s mycroft.jev -a jev >/dev/null 2>&1; then
  (umask 077; security find-generic-password -s mycroft.jev -a jev -w > "$DATA/Documents/import/jev.key")
  echo "handed over the Jev key"
fi

xcrun simctl terminate "$UDID" "$BUNDLE_ID" 2>/dev/null || true
xcrun simctl launch "$UDID" "$BUNDLE_ID"
echo "launched $BUNDLE_ID on $UDID"
