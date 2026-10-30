#!/bin/bash
# Cold app launches; OS/WebKit process caches are not necessarily cold.
# Usage: scripts/benchmark.sh <booted-simulator-udid> [runs-per-strategy] [output-directory]
set -euo pipefail
cd "$(dirname "$0")/.."
DEVICE="${1:?Pass a booted simulator UDID (xcrun simctl list devices booted)}"
RUNS="${2:-5}"
WORK="${3:-$(mktemp -d "${TMPDIR:-/tmp}/safearea.XXXXXX")}"
PAGE_URL="${PAGE_URL:-http://localhost:8000}"
AUTO_PUSH_DELAY="${AUTO_PUSH_DELAY:-1}"
RUN_SECONDS="${RUN_SECONDS:-10}"
PRIME_TIMEOUT="${PRIME_TIMEOUT:-3}"
STRATEGIES="${STRATEGIES:-none inject prewarm both prime preprime}"
RECORD_VIDEO="${RECORD_VIDEO:-0}"
PERTURB="${PERTURB:-}"
PERTURB_DELAY="${PERTURB_DELAY:-0}"
APP_ID=Chet-Corcos.WebViewBug
case "$RUNS" in ''|*[!0-9]*|0) echo 'Runs must be a positive integer' >&2; exit 1;; esac
python3 - "$AUTO_PUSH_DELAY" "$RUN_SECONDS" "$PRIME_TIMEOUT" <<'PY'
import math, sys
values=list(map(float, sys.argv[1:]))
assert all(math.isfinite(x) for x in values), 'Timing values must be finite'
delay, duration, timeout=values
assert delay >= 0 and 0 < timeout <= 30, 'Invalid delay or prime timeout'
assert duration > delay + timeout + 2, 'RUN_SECONDS must leave at least 2s after push + priming timeout'
PY
for strategy in $STRATEGIES; do
  case "$strategy" in none|inject|prewarm|both|prime|preprime|preprime-inject) ;; *) echo "Unknown strategy: $strategy" >&2; exit 1;; esac
done
if ! curl -fsS -o /dev/null "$PAGE_URL"; then
  echo "Start the page server: python3 -m http.server 8000" >&2
  exit 1
fi
mkdir -p "$WORK"
WORK="$(cd "$WORK" && pwd)"
launcher=""
recorder=""
cleanup() {
  if [ -n "$recorder" ]; then kill -INT "$recorder" 2>/dev/null || true; wait "$recorder" 2>/dev/null || true; fi
  xcrun simctl terminate "$DEVICE" "$APP_ID" 2>/dev/null || true
  if [ -n "$launcher" ]; then kill "$launcher" 2>/dev/null || true; wait "$launcher" 2>/dev/null || true; fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
{
  date -u '+Recorded UTC: %Y-%m-%dT%H:%M:%SZ'
  git rev-parse HEAD
  git status --short
  xcodebuild -version
  xcrun simctl list devices booted
  echo "Device=$DEVICE Runs=$RUNS Strategies=$STRATEGIES"
  echo "Page=$PAGE_URL AutoPushDelay=$AUTO_PUSH_DELAY RunSeconds=$RUN_SECONDS PrimeTimeout=$PRIME_TIMEOUT Video=$RECORD_VIDEO"
  echo "Perturb=${PERTURB:-none} PerturbDelay=$PERTURB_DELAY"
} > "$WORK/environment.txt"
git diff > "$WORK/working-tree.diff"
xcodebuild -project WebViewBug.xcodeproj -scheme WebViewBug \
  -destination "id=$DEVICE" -derivedDataPath "$WORK/DerivedData" \
  CODE_SIGNING_ALLOWED=NO build > "$WORK/build.log" 2>&1 || {
    echo "Build failed; inspect $WORK/build.log" >&2; exit 1;
  }
xcrun simctl install "$DEVICE" "$WORK/DerivedData/Build/Products/Debug-iphonesimulator/WebViewBug.app"
# Interleave strategies, rather than completing all runs of one strategy first.
for run in $(seq "$RUNS"); do
  for strategy in $STRATEGIES; do
    xcrun simctl terminate "$DEVICE" "$APP_ID" 2>/dev/null || true
    prefix="$WORK/run-$run-$strategy"
    if [ "$RECORD_VIDEO" = 1 ]; then
      xcrun simctl io "$DEVICE" recordVideo "$prefix.mp4" > "$prefix-video.txt" 2>&1 &
      recorder=$!
    fi
    perturb_args=()
    if [ -n "$PERTURB" ]; then perturb_args=(-perturb "$PERTURB" -perturbDelay "$PERTURB_DELAY"); fi
    xcrun simctl launch --console-pty "$DEVICE" "$APP_ID" \
      -strategy "$strategy" -autoPush YES -autoPushDelay "$AUTO_PUSH_DELAY" \
      -primeTimeout "$PRIME_TIMEOUT" -pageURL "$PAGE_URL" "${perturb_args[@]+"${perturb_args[@]}"}" > "$prefix.log" 2>&1 &
    launcher=$!
    sleep "$RUN_SECONDS"
    xcrun simctl io "$DEVICE" screenshot "$prefix.png" > /dev/null 2>&1
    cleanup
    launcher=""
    recorder=""
  done
done
python3 scripts/summarize.py "$WORK" | tee "$WORK/summary.md"
echo "Logs, environment, screenshots and optional video: $WORK"
