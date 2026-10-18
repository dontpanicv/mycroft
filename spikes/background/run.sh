#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
spike_device=${1:?Usage: bash run.sh SIMULATOR_UDID}
spike_stamp=$(date +%Y%m%d-%H%M%S)
spike_started=$(date +%s)
spike_results="results/$spike_stamp"
mkdir -p "$spike_results"
xcodegen generate
xcrun simctl bootstatus "$spike_device" -b
xcodebuild -project BackgroundSpike.xcodeproj -scheme BackgroundSpike \
  -configuration Release -destination "platform=iOS Simulator,id=$spike_device" \
  -derivedDataPath build -resultBundlePath "$spike_results/tests.xcresult" \
  -parallel-testing-enabled NO test > "$spike_results/xcodebuild.log" 2>&1
spike_container=$(xcrun simctl get_app_container "$spike_device" dev.local.agent.BackgroundSpike data)
cp "$spike_container/Documents/events.jsonl" "$spike_results/events.jsonl"
cp "$spike_container/Documents/agent.js" "$spike_results/agent.js"
cp "$spike_container/Documents/checkpoint.json" "$spike_results/checkpoint.json"
python3 analyze.py "$spike_results/events.jsonl" "$spike_started" > "$spike_results/summary.json"
python3 verify-recovery.py "$spike_results/events.jsonl" > "$spike_results/recovery.json"
cat "$spike_results/summary.json"
