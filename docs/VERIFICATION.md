# Verification

## Environment

- Date: 2026-10-30
- Xcode 27.2 RC (27B48), iOS 27.2 SDK and simulator runtime
- iPhone 18 Pro Max simulator: portrait insets 116/0/34/0, landscape 78/62/20/62
- Page served from `http://localhost:8000` with `python3 -m http.server`
- Build: no Swift compiler warnings
- Portable checks: 5/5 Node tests, 2/2 Python tests, `bash -n`, `git diff --check`

## Benchmark results

77 cold app launches across four sets: baseline (5 runs per strategy, 1 s push delay), immediate (5 runs, 0 s delay), video (2 runs) and focused (5 runs of `inject` and `prime`, 15 s each). Priming timeout 3 s. No missing probes and no bridge or navigation errors.

Times are the native milliseconds from destination coordinator creation to the page's `initial` checkpoint. They are not time to visible content. "Late correction" is the delay until effective CSS insets became nonzero after an initial zero.

| Strategy | Runs | Initial `env()` | Initial effective | Initial checkpoint ms, median (min-max) | Late correction | Priming |
|---|---:|---|---|---|---|---|
| none | 12 | top 0 in 12/12 | 0 in 12/12 | 790 (589-3505) | 12/12, median +96 ms | n/a |
| inject | 17 | top 0 in 17/17 | equals native in 17/17 | 689 (588-3094) | none | n/a |
| prewarm | 12 | top 0 in 12/12 | 0 in 12/12 | 486 (71-1142) | 12/12, median +73 ms | n/a |
| both | 12 | top 0 in 12/12 | equals native in 12/12 | 462 (72-860) | none | n/a |
| prime | 17 | correct in 17/17 | correct in 17/17 | 1057 (943-3528), includes bootstrap | none | 17/17 `prime-ready` |

### Pre-priming

A separate set of 30 cold launches compared `both`, `prime` and `preprime`, 5 runs each at 1 s and 0 s push delays.

| Strategy | Push delay | Initial `env()` | Initial checkpoint ms, median (min-max) | Priming |
|---|---:|---|---|---|
| both | 1 s | top 0 in 5/5 (effective correct) | 82 (61-2491) | n/a |
| prime | 1 s | correct in 5/5 | 988 (897-2150) | 5/5 `prime-ready` |
| preprime | 1 s | correct in 5/5 | 110 (96-171) | 5/5 `prime-ready`, preloaded |
| both | 0 s | top 0 in 5/5 (effective correct) | 471 (449-539) | n/a |
| prime | 0 s | correct in 5/5 | 904 (883-1053) | 5/5 `prime-ready` |
| preprime | 0 s | correct in 5/5 | 819 (765-839) | 5/5 `prime-ready`, preloaded |

With a 1 s delay `preprime` reached `prime-ready` 86-124 ms after coordinator creation (52-69 ms after priming began), and `env()` top stayed 116 at every later checkpoint (`dom`, `load`, `pageshow`, `frame`). With no delay the bootstrap had not loaded, so `prime-ready` took 754-826 ms, including process startup. No video was recorded for this set.

In `none` and `prewarm` the correction lands after the first animation frame, which is the visible jump. Videos were recorded but not reviewed frame by frame.

## Interactive results (`inject`)

Effective insets equalled native insets at all 50 probe checkpoints in one session covering:

| Case | Result |
|---|---|
| Initial presentation | Content cleared the navigation bar. `env()` was 0 at the initial checkpoint; the bridge supplied 116/34. |
| Navigation bar hide/show | Effective top followed native 116 → 62 → 116, including the decrease. |
| Rotation | Portrait, both landscapes and back. All four edges updated. `env()` lagged native by 20-58 ms; effective did not. |
| Navigation race | Next document followed immediately by rotation. `env()` lagged by about 666 ms; effective did not. |
| History | Web back produced `pageshow-restored` with correct values. Native pop and reopen created a fresh document with `env()` 0 and effective 116 at the initial checkpoint. |
| Background | Home and resume kept the same process and layout. |

## Priming edge cases

- `-primeTimeout 0.001`: 3/3 runs logged `prime-timeout` and fell back to an ordinary load, with `env()` 0 on the real page.
- Server unavailable: priming completed from the bundled HTML, then the real load logged `navigation-error`. No hang.

## Not tested

- Physical iPhone, minimum supported OS (iOS 17)
- Keyboard and hardware-keyboard viewport behavior
- iPad rotation and resizing
- WebContent process termination and recovery
- Early consumer and unrelated user scripts alongside the bootstrap script
- `prime` or `preprime` during rotation or bar transitions
- `preprime` after WebContent termination in the pool
- Frame-by-frame video review

## Reproduce

```sh
SIMULATOR_ID=<booted iPhone simulator UDID>
python3 -m http.server 8000   # separate terminal, repository root

scripts/benchmark.sh "$SIMULATOR_ID" 5 benchmark-results/baseline
AUTO_PUSH_DELAY=0 scripts/benchmark.sh "$SIMULATOR_ID" 5 benchmark-results/immediate
RECORD_VIDEO=1 scripts/benchmark.sh "$SIMULATOR_ID" 2 benchmark-results/video
STRATEGIES='inject prime' RUN_SECONDS=15 RECORD_VIDEO=1 \
  scripts/benchmark.sh "$SIMULATOR_ID" 5 benchmark-results/focused
STRATEGIES='both prime preprime' scripts/benchmark.sh "$SIMULATOR_ID" 5 benchmark-results/preprime-baseline
AUTO_PUSH_DELAY=0 STRATEGIES='both prime preprime' scripts/benchmark.sh "$SIMULATOR_ID" 5 benchmark-results/preprime-immediate
```

Each result folder holds `environment.txt`, `working-tree.diff`, `build.log`, full JSON `PROBE` logs, end-of-run screenshots, optional video and `summary.md`. `scripts/summarize.py <folder>` regenerates the summary. Override `STRATEGIES`, `AUTO_PUSH_DELAY`, `RUN_SECONDS`, `PRIME_TIMEOUT`, `PAGE_URL` or `RECORD_VIDEO` as needed; `RUN_SECONDS` must exceed push delay plus priming timeout plus 2.

For interactive checks, launch a single strategy:

```sh
xcrun simctl launch --console-pty "$SIMULATOR_ID" Chet-Corcos.WebViewBug -strategy inject
```

Compare the page's `native` and `effective` values at the same checkpoint. `nativeAtReceipt` is sampled later and can differ during transitions. `bridge-stale-document` is a rejected stale update, not a failure by itself.

On a physical device, `localhost` is the phone. Pass `-pageURL http://<mac-hostname>.local:8000` and allow the local-network prompt.
