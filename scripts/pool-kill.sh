#!/bin/bash
# Kill the pooled web view's WebContent process before the push, then check the fallback.
# Usage: scripts/pool-kill.sh <booted-simulator-udid> [runs-per-strategy] [output-directory]
# Requires the app to be installed on the simulator (scripts/benchmark.sh installs it).
set -euo pipefail
cd "$(dirname "$0")/.."
DEVICE="${1:?Pass a booted simulator UDID}"
RUNS="${2:-3}"
WORK="${3:-$(mktemp -d "${TMPDIR:-/tmp}/poolkill.XXXXXX")}"
STRATEGIES="${STRATEGIES:-preprime preprime-inject}"
PAGE_URL="${PAGE_URL:-http://localhost:8000}"
APP_ID=Chet-Corcos.WebViewBug
mkdir -p "$WORK"
webcontent_pids() { pgrep -f 'com.apple.WebKit.WebContent' | sort || true; }
for run in $(seq "$RUNS"); do
  for strategy in $STRATEGIES; do
    xcrun simctl terminate "$DEVICE" "$APP_ID" 2>/dev/null || true
    sleep 1
    before="$(webcontent_pids)"
    prefix="$WORK/run-$run-$strategy"
    xcrun simctl launch --console-pty "$DEVICE" "$APP_ID" -strategy "$strategy" \
      -autoPush YES -autoPushDelay 4 -pageURL "$PAGE_URL" > "$prefix.log" 2>&1 &
    launcher=$!
    sleep 2.5
    added="$(comm -13 <(echo "$before") <(webcontent_pids))"
    if [ "$(printf '%s\n' "$added" | grep -c . || true)" != 1 ]; then
      echo "run $run $strategy: expected one new WebContent process, found: ${added:-none}" | tee "$prefix-kill.txt"
    else
      kill -9 "$added"
      echo "run $run $strategy: killed $added" | tee "$prefix-kill.txt"
    fi
    sleep 8
    xcrun simctl io "$DEVICE" screenshot "$prefix.png" > /dev/null 2>&1 || echo "screenshot failed" > "$prefix-screenshot.txt"
    xcrun simctl terminate "$DEVICE" "$APP_ID" 2>/dev/null || true
    kill "$launcher" 2>/dev/null || true
    wait "$launcher" 2>/dev/null || true
  done
done
python3 scripts/summarize.py "$WORK" | tee "$WORK/summary.md"
