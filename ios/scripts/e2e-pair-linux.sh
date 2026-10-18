#!/usr/bin/env bash
# Pairs a throwaway Linux container ("linux-box") through the Add Machine flow on a Simulator, to test several
# machines at once. Uses a local alpine image (no pull) and the static linux hands binary from hands/dist.
#   scripts/e2e-pair-linux.sh SIMULATOR_UDID [IMAGE]
set -euo pipefail
cd "$(dirname "$0")/.."
UDID="$1"; IMAGE="${2:-postgres:17-alpine}"; NAME=linux-box; PORT=47001
case "$(uname -m)" in arm64|aarch64) BIN=hands-linux-aarch64 ;; *) BIN=hands-linux-x86_64 ;; esac

docker rm -f "$NAME" >/dev/null 2>&1 || true
docker run -d --name "$NAME" --hostname "$NAME" -p "$PORT:$PORT" --entrypoint sleep "$IMAGE" infinity >/dev/null
docker cp "../hands/dist/$BIN" "$NAME:/usr/local/bin/hands"
docker exec "$NAME" sh -c "mkdir -p /root/.local/state/hands && echo '{\"port\": $PORT}' > /root/.local/state/hands/listener.json"
echo "container $NAME is up ($(docker exec "$NAME" uname -sm))"

xcrun simctl pbcopy "$UDID" <<< "" 2>/dev/null || true
TEST_RUNNER_MYCROFT_LIVE=1 xcodebuild -project Mycroft.xcodeproj -scheme Mycroft -destination "platform=iOS Simulator,id=$UDID" \
  -derivedDataPath build/DerivedData -resultBundlePath "build/e2e-linux-$(date +%s).xcresult" test \
  -only-testing:MycroftUITests/ConversationUITests/testPairMachine > build/e2e-linux.log 2>&1 &
TEST=$!
for _ in $(seq 1 120); do
  sleep 2
  CMD="$(xcrun simctl pbpaste "$UDID" 2>/dev/null || true)"
  if [[ "$CMD" == curl\ * ]]; then
    [[ "$CMD" =~ sha256//([^[:space:]]+)[[:space:]]+(https://[^[:space:]]+) ]] || { echo "unexpected command: $CMD"; exit 1; }
    PIN="${BASH_REMATCH[1]}"; BASE="${BASH_REMATCH[2]}"
    echo "pairing $NAME with $BASE"
    docker exec "$NAME" hands install --pair "$BASE" --pin "$PIN" --no-service
    break
  fi
done
wait $TEST && echo "UI test passed" || { echo "UI test failed"; grep -E "error:|XCTAssert|failed" build/e2e-linux.log | head; exit 1; }
