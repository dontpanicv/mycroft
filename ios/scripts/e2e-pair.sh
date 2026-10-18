#!/usr/bin/env bash
# End-to-end pairing on a Simulator: runs the Add Machine UI test and, as soon as the app has copied the install
# command, runs that command on this Mac — what a user does by pasting into Terminal. Installs hands for real.
#   scripts/e2e-pair.sh SIMULATOR_UDID
set -euo pipefail
cd "$(dirname "$0")/.."
UDID="$1"
xcrun simctl pbcopy "$UDID" <<< "" 2>/dev/null || true
TEST_RUNNER_MYCROFT_LIVE=1 xcodebuild -project Mycroft.xcodeproj -scheme Mycroft -destination "platform=iOS Simulator,id=$UDID" \
  -derivedDataPath build/DerivedData -resultBundlePath "build/e2e-pair-$(date +%s).xcresult" test \
  -only-testing:MycroftUITests/ConversationUITests/testPairMachine > build/e2e-pair.log 2>&1 &
TEST=$!
for _ in $(seq 1 120); do
  sleep 2
  CMD="$(xcrun simctl pbpaste "$UDID" 2>/dev/null || true)"
  if [[ "$CMD" == curl\ * ]]; then
    echo "running the copied command on this Mac:"
    echo "  ${CMD:0:60}…"
    sh -c "$CMD"
    break
  fi
done
wait $TEST && echo "UI test passed" || { echo "UI test failed"; grep -E "error:|XCTAssert|failed" build/e2e-pair.log | head; exit 1; }
