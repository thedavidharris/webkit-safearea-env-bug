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

### Pre-priming follow-up

Further cold launches on the same simulator unless noted. Settle times run from the last native inset change to the first page checkpoint that matches it, sampled at native receipt.

| Case | Runs | Result |
|---|---:|---|
| `preprime-inject`, 1 s delay, video | 5 | `env()` and effective correct at the first checkpoint in 5/5. Initial checkpoint median 137 ms (133-321). |
| `preprime`, 1 s delay, video | 5 | `env()` correct in 5/5. Median 1301 ms (116-1642): in 3 runs the pool's bootstrap navigation had not started by the push, so the destination waited for it. |
| Frame-by-frame video review, `both`/`preprime`/`preprime-inject` | 15 | No vertical shift of the hero in any run. 4 runs showed a blank white web view for 1.2-1.5 s after the push (the slow runs above); the rest drew content during the slide. `none` and `prewarm` were not in this set. |
| Bar hidden 0.1 s after the destination appears | 3 per strategy | All converged to 62/0/34/0. `env()` settled 8-48 ms after the native change in `preprime`/`preprime-inject`, 14-15 ms in `both`. The bridge settled 2-48 ms. `prime` had not loaded the page yet. |
| Bar hidden immediately | 3 per strategy | Hidden before the first checkpoint; every primed strategy read 62 there. |
| Rotation requested at 0 s and 0.3 s | 3 per strategy and delay | UIKit rejects `requestGeometryUpdate` during the push transition. The hook retries every 50 ms; it applied 250-550 ms after the request. All runs ended at 78/62/20/62. With the page loaded, `env()` settled 15-31 ms after the native change and the bridge 7-10 ms. When rotation landed during priming, priming re-waited and the first checkpoint was already landscape. |
| WebContent killed in the pool (`scripts/pool-kill.sh`), iPhone Duo | 4 of 6 killed | The destination saw no preloaded bootstrap, loaded a fresh one, reached `prime-ready`, and read correct `env()` (82/84/34/0) at the first checkpoint. Two runs could not attribute a single new process and were not killed. |
| `preprime` on iPhone Duo, no kill | 6 | `env()` correct at the first checkpoint (82/84/34/0). |
| `preprime` without the readiness wait (`-primeTimeout 0.001`) | 5 at 1 s, 3 at 0 s | `env()` 0 at the first checkpoint in 1/5 and 3/3. The wait is required. |

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

- Physical iPhone (skipped: signing would have used a corporate team), minimum supported OS (iOS 17: no simulator runtime installed)
- Keyboard and hardware-keyboard viewport behavior
- iPad rotation and resizing
- WebContent process termination after the destination is presented
- Early consumer and unrelated user scripts alongside the bootstrap script
- Frame-by-frame video review of `none`, `prewarm` and `prime`
- A second push after the pool has been drained (the demo does not re-warm)

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
RECORD_VIDEO=1 STRATEGIES='both preprime preprime-inject' scripts/benchmark.sh "$SIMULATOR_ID" 5 benchmark-results/r2-video
PERTURB=rotate PERTURB_DELAY=0 STRATEGIES='both prime preprime preprime-inject' scripts/benchmark.sh "$SIMULATOR_ID" 3 benchmark-results/r2-rotate-0
PERTURB=hideBar PERTURB_DELAY=0.1 STRATEGIES='both prime preprime preprime-inject' scripts/benchmark.sh "$SIMULATOR_ID" 3 benchmark-results/r2-hideBar-0.1
PRIME_TIMEOUT=0.001 STRATEGIES=preprime scripts/benchmark.sh "$SIMULATOR_ID" 5 benchmark-results/r2-nohandshake
scripts/pool-kill.sh "$SIMULATOR_ID" 3 benchmark-results/r2-kill   # after a benchmark run has installed the app
```

Each result folder holds `environment.txt`, `working-tree.diff`, `build.log`, full JSON `PROBE` logs, end-of-run screenshots, optional video and `summary.md`. `scripts/summarize.py <folder>` regenerates the summary. Override `STRATEGIES`, `AUTO_PUSH_DELAY`, `RUN_SECONDS`, `PRIME_TIMEOUT`, `PAGE_URL` or `RECORD_VIDEO` as needed; `RUN_SECONDS` must exceed push delay plus priming timeout plus 2.

For interactive checks, launch a single strategy:

```sh
xcrun simctl launch --console-pty "$SIMULATOR_ID" Chet-Corcos.WebViewBug -strategy inject
```

Compare the page's `native` and `effective` values at the same checkpoint. `nativeAtReceipt` is sampled later and can differ during transitions. `bridge-stale-document` is a rejected stale update, not a failure by itself.

On a physical device, `localhost` is the phone. Pass `-pageURL http://<mac-hostname>.local:8000` and allow the local-network prompt.
