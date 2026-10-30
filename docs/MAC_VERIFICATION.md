# Mac verification and follow-up plan

Status: compiled and run on one iOS 27.2 simulator (2026-10-30). Physical-device, minimum-OS, keyboard, iPad and process-loss cases are still NOT RUN. See [Results](#results-ios-272-simulator-2026-10-30).

## 1. Get the changes and check the tools

Check out the branch/PR containing this file in your usual clone. From the repository root:

```sh
xcode-select -p
xcodebuild -version
xcrun simctl list devices available
python3 --version
node --version
node --test tests/bridge.test.cjs
python3 -m unittest discover -s tests
bash -n scripts/benchmark.sh
git diff --check
```

Node 18+ is needed only for the JavaScript tests. Python 3 is needed by the server and summarizer. Install/select an appropriate Xcode and simulator runtime if missing. Do not assume the reported historical runtime is the one installed on your Mac.

## 2. Compile before measuring

Choose an available iPhone simulator UDID from the listing. Replace the placeholder:

```sh
SIMULATOR_ID='REPLACE_WITH_UDID'
xcrun simctl boot "$SIMULATOR_ID"
xcrun simctl bootstatus "$SIMULATOR_ID" -b
open -a Simulator
xcodebuild -project WebViewBug.xcodeproj -scheme WebViewBug \
  -destination "id=$SIMULATOR_ID" \
  -derivedDataPath DerivedData CODE_SIGNING_ALLOWED=NO build
```

Skip `boot` if it is already booted. Resolve compiler errors before continuing. Pay particular attention to Swift actor isolation in the delegates/representables, the two bundled resources (`NativeSafeArea.js`, `priming.html`), and navigation callback ordering. Do not work around a build error by silently removing reconciliation or the priming timeout.

The project still uses its existing Swift 5 language mode and iOS 17 deployment target. Inspect compiler warnings too. Record the Xcode version, SDK, simulator runtime/build, device model, and commit under test.

## 3. Start the page server and establish a baseline

In a separate Terminal, from the repository root:

```sh
python3 -m http.server 8000
```

Then:

```sh
scripts/benchmark.sh "$SIMULATOR_ID" 5 benchmark-results/baseline
AUTO_PUSH_DELAY=0 scripts/benchmark.sh "$SIMULATOR_ID" 5 benchmark-results/immediate
RECORD_VIDEO=1 scripts/benchmark.sh "$SIMULATOR_ID" 2 benchmark-results/video
```

Defaults are five strategies, one second before push, ten seconds per run, and a three-second priming timeout. Override `STRATEGIES`, `AUTO_PUSH_DELAY`, `RUN_SECONDS`, `PRIME_TIMEOUT`, `PAGE_URL`, or `RECORD_VIDEO` as needed. Increase `RUN_SECONDS` for a slow runtime; keep it greater than push delay + priming timeout + two seconds.

```sh
STRATEGIES='inject prime' RUN_SECONDS=15 RECORD_VIDEO=1 \
  scripts/benchmark.sh "$SIMULATOR_ID" 5 benchmark-results/focused
python3 scripts/summarize.py benchmark-results/focused
```

Keep environment.txt, working-tree.diff, build.log, all run logs, and videos together. Ignored result directories are intentionally not committed by default. End-of-run screenshots cannot establish initial correctness. Review the videos, including the navigation transition. Videos can miss short frame-level artifacts; corroborate on a physical device when needed.

## 4. Verify the bridge separately from prewarming

Use Xcode's Run scheme arguments `-strategy inject`, or install the built app and launch it manually:

```sh
xcrun simctl install "$SIMULATOR_ID" DerivedData/Build/Products/Debug-iphonesimulator/WebViewBug.app
xcrun simctl launch --console-pty "$SIMULATOR_ID" Chet-Corcos.WebViewBug -strategy inject
```

Stop an already-running instance first when changing arguments. Repeat with `none`, `prewarm`, `both`, and `prime` as appropriate.

| Case | Action | Required observation |
|---|---|---|
| Initial presentation | Open from home repeatedly, including immediate push | First visible content clears the native UI; bridge values exist at initial script; no later jump merely because env catches up. |
| Insets decrease/increase | Swipe up/down to hide/show navigation bar | Effective CSS follows current native values, including decreases. It must not stick to the older larger env value. |
| Rotation | Portrait → both landscapes → portrait, with bar shown and hidden | All four edges update; legitimate zeros are retained. |
| Navigation race | Tap Next document/reload while changing bar state or rotating | Fresh document receives values even if native geometry is numerically unchanged. Stale replies do not overwrite newer geometry. |
| History | Next document, Web back; also native pop and reopen | Values reconcile for restored documents and new destinations. Inspect pageshow-restored where supported. |
| Background | Suspend/resume, including after rotation if possible | Content and native geometry converge without permanent stale values. |
| Keyboard | Add a temporary text input, focus/dismiss, test hardware keyboard mode too | Identify keyboard-specific viewport behavior separately; do not redefine the safe-area bridge as keyboard height. |
| Larger layouts | iPad rotation/resizing where supported | No device-specific constants; web-view-relative geometry remains correct. |
| Web-content process loss | Use Xcode/developer tooling to terminate the app's identified WebContent process | process-terminated logs; demo reload recovers. Do not use private APIs in production. If you cannot target it reliably, mark this test NOT RUN. |
| Integration scripts | Add an early consumer script and unrelated scripts | Bootstrap runs first; unrelated scripts keep their relative ordering and are not lost after inset changes. |

For numerical checks, compare page `native`/`effective` at the same JS checkpoint. `nativeAtReceipt` is a later native sample and may differ legitimately during transitions. `bridge-stale-document` is a rejected update, not automatically a failure. Persistent bridge-error/navigation-error or missing probes require investigation.

The subclass is a focused sample, not a drop-in delegate replacement for an app. Integrate with the app's existing navigation delegates, script manager, permitted pages, data store, and process-recovery policy.

## 5. Test priming's actual claim

With `-strategy prime`:

1. Confirm the sequence `prime-start` → `prime-match` → `prime-ready` → the real page's `initial` checkpoint.
2. Check that `prime-match` reflects two samples against unchanged native geometry on every edge. Zero values are allowed.
3. Check the **real page's** initial env values and visible presentation. A primed bootstrap does not prove that the next document inherited the state.
4. Repeat during rotation and bar transitions. Compare matching native geometry before and after the real navigation.
5. Set a very short `-primeTimeout 0.001` to exercise timeout handling (whether it times out is timing-dependent). Confirm a `prime-timeout` loads the target and is reported as a fallback, never a priming success.
6. Test navigation failure/server unavailability separately. Verify no indefinite wait and inspect the resulting navigation-error logs.
7. If prime works, measure total destination-to-content latency including the bootstrap. Only then consider a separate pre-priming experiment in representative destination geometry before the tap.

No claim is made that loadHTMLString's baseURL guarantees process reuse. If process identity is needed to explain a run, use Xcode/WebKit debugging tools and record what you actually observed. Do not infer a process swap merely from a zero inset.

## 6. Physical-device and supported-OS checks

Run `inject`, `none`, and `prime` on a physical iPhone, your minimum supported OS where available, and your current release OS. Simulator results alone are insufficient for final acceptance.

For a phone, localhost points to the phone. Use the Mac's reachable local hostname, e.g. `-pageURL http://Your-Mac.local:8000`, while both devices are on the same network. The sample declares local-network usage and allows local networking; grant the prompt and allow the server through the Mac firewall if required. Verify connection errors before diagnosing safe areas. Avoid broad ATS exceptions for unrelated domains.

If testing zoom is relevant to the app, remove the sample's maximum-scale/user-scalable restriction in a separate experiment and record that change. This sample's baseline viewport intentionally remains unchanged for comparability.

## 7. Decide what to ship

- Prefer `inject` only after native compilation, first-presentation checks, navigation reconciliation, inset-decrease tests, and the actual app's layout contract pass.
- Add prewarming only if tap-to-visible-content improves enough to justify memory/lifecycle complexity. Include zero-delay taps; the one-second benchmark head start is excluded from destination timing.
- Keep `prime` experimental unless the real document consistently passes and the latency is acceptable. Report fallback frequency, not just successful runs.
- If testing unmodifiable content, design a measured-readiness reveal gate separately. Never use load/didFinish/fixed delay as the readiness criterion.
- An upstream patch needs early geometry **and** viewport-policy coordination. Do not implement only the earlier proposed computed-inset creation parameter and assume it fixes the bug.

## 8. Update this repository with evidence

Replace NOT RUN only for tests actually performed. Leave unsupported cases explicit. Preserve historical results as historical; write a separate table for this revision. Attach or link raw logs and representative recordings. Describe any failures and follow-up code changes before updating the recommended default.

### Results: iOS 27.2 simulator, 2026-10-30

- Tested commit and working changes: `cd56d29` plus this patch (uncommitted at test time; `working-tree.diff` in each result folder)
- Date: 2026-10-30
- Xcode/SDK: Xcode 27.2 RC (27B48), iOS 27.2 SDK
- OS/runtime version and build: iOS 27.2 simulator runtime
- Device/simulator: iPhone 18 Pro Max simulator (portrait insets 116/0/34/0, landscape 78/62/20/62)
- Page URL/configuration: `http://localhost:8000` from `python3 -m http.server`, viewport unchanged
- Runs per strategy / warm-up delay / priming timeout: baseline 5 × 5 strategies (1 s push delay), immediate 5 × 5 (0 s), video 2 × 5, focused 5 × inject/prime (15 s runs); priming timeout 3 s
- Build status and relevant warnings: build succeeded; no Swift compiler warnings (only the AppIntents metadata notice)
- Portable checks: 5/5 Node tests, 2/2 Python tests, `bash -n`, `git diff --check` all pass on macOS
- First visible presentation evidence: probe checkpoints only. `none`/`prewarm` had effective top 0 at the initial checkpoint in 24/24 runs and corrected a median 73-96 ms later, after the first frame. `inject`/`both` had effective = injected native at the initial checkpoint in 29/29 runs while `env` was still 0. Videos were recorded but not reviewed frame by frame.
- Navigation/rotation/bar-transition findings: interactive `inject` session (bar hide/show, portrait → both landscapes → portrait, Next document, Next document + immediate rotation, Web back). Effective matched injected native at all 50 checkpoints. `env` lagged native by 20-58 ms on rotation and about 666 ms on a rotation immediately after navigation; the bridge covered both.
- Background/history/process-recovery findings: Web back produced `pageshow-restored` with correct values. Native pop and reopen created a fresh document with env 0 and effective 116 at the initial checkpoint. Home and resume kept the same process and layout. Process loss NOT RUN.
- Missing probes / JavaScript or navigation errors: none missing; 0 `bridge-error`, 0 `bridge-stale-document`, 0 unexpected `navigation-error` across 77 benchmark runs and the interactive session
- Priming ready / timeout / failed counts: 17/17 `prime-ready` at the default timeout. With `-primeTimeout 0.001`, 3/3 `prime-timeout`, which fell back to an ordinary load with env 0 and is reported as a fallback. With the server unavailable, priming completed (local HTML), then the real load logged `navigation-error` with no hang.
- Log/video locations: `benchmark-results/{baseline,immediate,video,focused,manual}` (git-ignored, local only)
- Cases still NOT RUN: physical iPhone, minimum supported OS, keyboard, iPad/resizing, WebContent process termination, early consumer/unrelated user scripts, prime during rotation/bar transitions, frame-by-frame video review
- Recommendation and remaining blockers: `inject` passes every simulator check above and is the recommended default pending physical-device and minimum-OS runs. `prime` reliably fixes `env` itself in this runtime but adds about 400 ms of median time to the destination over `inject`; keep it experimental. `prewarm` reduces time to the destination but does not fix insets on its own.

Initial-checkpoint timing is measured from destination coordinator creation and is not visible-content timing.

| Strategy | Initial env observations | Initial effective vs injected | Initial checkpoint ms (median, min-max) | Late inset correction (probe) | Priming outcomes | Notes |
|---|---|---|---|---|---|---|
| none | top 0 in 12/12 | n/a | 790 (589-3505) | 12/12, median +96 ms | n/a | bug reproduces |
| inject | top 0 in 17/17 | equal in 17/17 | 689 (588-3094) | 0/17 | n/a | interactive checks pass |
| prewarm | top 0 in 12/12 | n/a | 486 (71-1142) | 12/12, median +73 ms | n/a | faster, insets still wrong |
| both | top 0 in 12/12 | equal in 12/12 | 462 (72-860) | 0/12 | n/a | fastest correct |
| prime | correct in 17/17 | n/a | 1057 (943-3528) | 0/17 | 17 ready; forced timeout 3/3 fallback | includes bootstrap |
