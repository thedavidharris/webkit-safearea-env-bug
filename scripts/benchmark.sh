#!/bin/bash
# Cold-launches the app once per run for each load strategy and prints the page's
# safe-area-inset measurements with time since the web view was requested.
#
# Usage: scripts/benchmark.sh <simulator-udid> [runs-per-strategy]
# Requires the page server: python3 -m http.server 8000
set -euo pipefail

cd "$(dirname "$0")/.."
DEVICE="${1:?Pass a booted simulator UDID (xcrun simctl list devices booted)}"
RUNS="${2:-5}"
APP_ID=Chet-Corcos.WebViewBug
WORK="$(mktemp -d)"

if ! curl -sf -o /dev/null http://localhost:8000; then
  echo "Start the page server first: python3 -m http.server 8000" >&2
  exit 1
fi

xcodebuild -project WebViewBug.xcodeproj -scheme WebViewBug \
  -destination "id=$DEVICE" -derivedDataPath "$WORK/DerivedData" build -quiet
xcrun simctl install "$DEVICE" "$WORK/DerivedData/Build/Products/Debug-iphonesimulator/WebViewBug.app"

for strategy in none inject prewarm both; do
  for run in $(seq "$RUNS"); do
    xcrun simctl terminate "$DEVICE" "$APP_ID" 2>/dev/null || true
    xcrun simctl launch --console-pty "$DEVICE" "$APP_ID" -strategy "$strategy" -autoPush YES \
      > "$WORK/$strategy-$run.txt" 2>&1 &
    launcher=$!
    sleep 7
    if [ "$run" = 1 ]; then
      xcrun simctl io "$DEVICE" screenshot "$WORK/$strategy.png" > /dev/null 2>&1
    fi
    kill "$launcher" 2>/dev/null || true
  done
done
xcrun simctl terminate "$DEVICE" "$APP_ID" 2>/dev/null || true

for strategy in none inject prewarm both; do
  cat "$WORK/$strategy"-*.txt | tr -d '\r' | grep '^PROBE' | grep ' initial ' || true
done
echo "Logs and screenshots: $WORK"
