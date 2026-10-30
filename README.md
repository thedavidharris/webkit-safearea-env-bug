# WKWebView safe-area values on initial navigation

A reproduction of delayed `env(safe-area-inset-*)` values in a full-bleed `WKWebView`, plus app-level workarounds and a measurement harness. Related: [WebKit bug 191872](https://bugs.webkit.org/show_bug.cgi?id=191872).

## Findings

On an iOS 27.2 iPhone simulator, `env(safe-area-inset-*)` reads 0 at the first script checkpoint of the first document in a newly created full-bleed `WKWebView`, and becomes correct only after the first frame, causing a visible jump. Later navigations in the same web view read correct values.

- `inject` (the default) fixes the layout. Native insets are installed as CSS custom properties at document start; effective insets matched native at every probe checkpoint across first load, bar hide/show, rotation, navigation, history and reopen.
- `prime` fixes `env()` itself by loading a `viewport-fit=cover` bootstrap first, but adds about 400 ms before the destination page's first script runs. Experimental.
- `preprime` loads that bootstrap in the prewarmed web view before the tap. `env()` was correct at the first checkpoint, with the first script about 100 ms after the push when the bootstrap had time to load. Experimental.
- `prewarm` shortens time to the destination's first script but does not fix the insets.

Full results and untested cases: [docs/VERIFICATION.md](docs/VERIFICATION.md).

## Run

Requires Xcode with an installed iOS simulator runtime, Python 3, and optionally Node 18+ for the portable checks. The project deployment target is iOS 17.

```sh
python3 -m http.server 8000
open WebViewBug.xcodeproj
```

Run on an iPhone simulator and tap Open WebView. The hero background extends behind the transparent navigation bar; its text uses the shared content-inset tokens. Swipe up/down to hide/show the navigation bar. The web buttons exercise reload and another same-origin document.

Launch arguments (Xcode scheme or `simctl launch`):

| Argument | Meaning |
|---|---|
| `-strategy none` | Browser `env()` only; no injection or warm-up. |
| `-strategy inject` | Native CSS values installed at document start. Default. |
| `-strategy prewarm` | Reuse a web view warmed with empty HTML; no injection. Process-startup control. |
| `-strategy both` | Empty-page prewarming plus injection. |
| `-strategy prime` | In the destination container, load a `viewport-fit=cover` bootstrap, wait for measured inset agreement, then navigate. Experimental; no injection. |
| `-strategy preprime` | Prewarm with the bootstrap instead of empty HTML; after attachment, wait for agreement with the destination's geometry, then navigate. Experimental; no injection. |
| `-autoPush YES` | Open the destination automatically. |
| `-autoPushDelay 1` | Seconds before automatic push; use `0` to test immediate navigation. |
| `-primeTimeout 3` | Priming deadline in seconds (maximum 30). Timeout/failure logs its outcome and loads the target normally. |
| `-pageURL http://localhost:8000` | Test page address; override for a physical device or alternate test server. |

`prime` accepts zero insets and requires two samples within 0.5 CSS px of unchanged native geometry on all four edges. This is a readiness observation, not a guarantee that the next navigation will preserve the state. Reparenting, policy changes and process replacement can invalidate it.

## What the source supports

Source review pinned to [WebKit dcff9aa](https://github.com/WebKit/WebKit/tree/dcff9aa18012198f30524b519deea1f398babbe7), October 30, 2026. Main-branch source is not proof of the implementation shipped in any particular iOS build.

1. [`WKWebView.mm`](https://github.com/WebKit/WebKit/blob/dcff9aa18012198f30524b519deea1f398babbe7/Source/WebKit/UIProcess/API/Cocoa/WKWebView.mm) initializes `_avoidsUnsafeArea = YES`.
2. In [`WKWebViewIOS.mm`](https://github.com/WebKit/WebKit/blob/dcff9aa18012198f30524b519deea1f398babbe7/Source/WebKit/UIProcess/API/ios/WKWebViewIOS.mm), `_computedUnobscuredSafeAreaInset` normally returns zero while that policy is active. `.never` scroll-inset adjustment does not directly change the policy.
3. [`ViewportConfiguration.cpp`](https://github.com/WebKit/WebKit/blob/dcff9aa18012198f30524b519deea1f398babbe7/Source/WebCore/page/ViewportConfiguration.cpp) derives `avoidsUnsafeArea` from `viewportFit != Cover`. The web process returns this policy in rendering-commit data; native applies it and schedules a visible-rectangle update.
4. Those updates carry the computed insets and can be deferred during navigation or unstable geometry. [`WebPageCocoa.mm`](https://github.com/WebKit/WebKit/blob/dcff9aa18012198f30524b519deea1f398babbe7/Source/WebKit/WebProcess/WebPage/Cocoa/WebPageCocoa.mm) can also reject updates older than the current navigation's commit boundary.
5. [`Page.cpp`](https://github.com/WebKit/WebKit/blob/dcff9aa18012198f30524b519deea1f398babbe7/Source/WebCore/page/Page.cpp) and [`StyleEnvironmentVariables.cpp`](https://github.com/WebKit/WebKit/blob/dcff9aa18012198f30524b519deea1f398babbe7/Source/WebCore/style/StyleEnvironmentVariables.cpp) propagate changed values into CSS and invalidate style.

This supports a viewport-policy/geometry round-trip explanation for initial zeros. It does not prove which branch caused a particular observed run without tracing that build.

- `WebPageProxy::updateVisibleContentRects` caches accepted updates before checking for a running process; without a process it skips sending. See [`WebPageProxyCocoa.mm`](https://github.com/WebKit/WebKit/blob/dcff9aa18012198f30524b519deea1f398babbe7/Source/WebKit/UIProcess/Cocoa/WebPageProxyCocoa.mm). Clearing that cache after a commit does not reset WebCore's safe-area values.
- Dynamic viewport-size updates also carry the insets, in [`WebPageIOS.mm`](https://github.com/WebKit/WebKit/blob/dcff9aa18012198f30524b519deea1f398babbe7/Source/WebKit/WebProcess/WebPage/ios/WebPageIOS.mm).
- An empty warm-up page has no `viewport-fit=cover`, so a warm process alone does not establish the target viewport policy.

## Approaches

### 1. Native inset bridge (preferred for content the app owns)

`InsetAwareWebView` captures the web view's native insets and installs `NativeSafeArea.js` as a main-frame `.atDocumentStart` user script before loading. Apple documents that the document element exists at that point, so the script sets custom properties directly on it.

```css
:root {
  --inset-top: var(--native-safe-area-inset-top, env(safe-area-inset-top, 0px));
  --inset-right: var(--native-safe-area-inset-right, env(safe-area-inset-right, 0px));
  --inset-bottom: var(--native-safe-area-inset-bottom, env(safe-area-inset-bottom, 0px));
  --inset-left: var(--native-safe-area-inset-left, env(safe-area-inset-left, 0px));
}
```

Native values take precedence, including zero. `max(env(...), native)` is avoided because it keeps a stale larger `env()` value after a bar hides. Browsers without the bridge use `env()`.

The initial values are installed synchronously; a document-ready message reconciles newer geometry without making initial CSS wait for a native reply. Document IDs and monotonic revisions reject stale updates. Commit/finish callbacks provide additional reconciliation, not an initial-paint guarantee. JavaScript errors are logged. The handler holds the view weakly.

The sample rebuilds its owned `WKUserScript` before the other scripts while preserving their relative order. It still uses `removeAllUserScripts` plus re-addition because the public API has no remove-one operation. An app integration should centralize registration, avoid sharing this content controller between web views, and test navigation concurrent with script updates.

Contract: these are app-owned content-clearance insets for a full-bleed page with `viewport-fit=cover` and `.never` scroll adjustment. They are not a universal polyfill for WebKit `env()`. Only migrated CSS benefits. Iframes and third-party CSS that directly read `env()` are unchanged. Avoid double-counting native content insets, treat keyboard avoidance separately, and validate zoom/viewport behavior for your actual pages. Native geometry changes can still arrive after the first render.

### 2. Prewarm (performance experiment)

The scene-owned pool warms empty HTML in the hosting window, isolating process startup from viewport policy. `both` adds the bridge.

The pool is a small demonstration, not a general production pool. Account for configuration/data-store compatibility, memory pressure, unused views, scene teardown, and process loss in an app integration. `baseURL` does not contractually guarantee process reuse.

### 3. Prime viewport policy and geometry

`prime` loads the bundled `priming.html` in the destination web view. It declares `viewport-fit=cover` and samples real CSS `env()` values on animation frames. Native checks agreement against the destination's current geometry, then loads the target. A three-second default deadline prevents an indefinite wait.

This pays a bootstrap navigation on the critical path. A `prime-ready` event only describes the bootstrap; inspect the real page's checkpoints and presentation separately. A timeout/failure falls back to ordinary navigation and must never be reported as successful priming.

### 4. Pre-prime in the warm pool

`preprime` warms the pooled web view with the same bootstrap. The pool's geometry is not the destination's, so the destination does not trust the warm state: it reuses the live bootstrap document, which keeps sampling, and navigates only after two samples agree with its own insets. The bootstrap navigation leaves the critical path; the geometry check stays on it. If the bootstrap has not loaded by the push, the wait includes process startup and the bootstrap load, so it degrades towards `prime`. Process termination in the pool discards the preloaded state and falls back to a fresh bootstrap.

The same pool caveats apply. Run inject alongside it if a late geometry change must never show up as a jump.

### 5. Delay presentation

`load`/`didFinish`/a fixed delay are not safe-area readiness signals. A measured-readiness gate could be a fallback for unmodifiable content, with a deadline and loading UI. It is not implemented here and would need to keep the web view participating in rendering. Valid zero insets must be allowed.

### 6. Upstream WebKit fix

[`WebPageCreationParameters.h`](https://github.com/WebKit/WebKit/blob/dcff9aa18012198f30524b519deea1f398babbe7/Source/WebKit/Shared/WebPageCreationParameters.h) lacks initial safe-area geometry. Adding it may help, but populating it from `_computedUnobscuredSafeAreaInset` alone can still copy zero under the initial policy.

A patch must coordinate early host geometry and the document's viewport policy without waiting for a rendering round trip, and handle later attachment, navigation and process replacement. Independent inset IPC might reduce deferral but does not alone guarantee ordering before first layout. Add TestWebKitAPI coverage for an early inline read after the viewport declaration, policy transitions, inset decreases and process changes. No upstream patch has been implemented or validated here. Private WebKit setters are not an app-level solution.

## Measurements and their limits

```sh
scripts/benchmark.sh <booted-simulator-udid> 5 benchmark-results/baseline
AUTO_PUSH_DELAY=0 scripts/benchmark.sh <booted-simulator-udid> 5 benchmark-results/immediate
RECORD_VIDEO=1 scripts/benchmark.sh <booted-simulator-udid> 2 benchmark-results/video
```

The harness interleaves strategies, stores the environment and working diff, retains complete JSON `PROBE` logs, captures end-of-run screenshots, optionally records video, and writes `summary.md`. `scripts/summarize.py` can regenerate the summary. Missing initial probes and priming timeouts are explicit.

Native milliseconds start at destination coordinator creation; prewarming before that is excluded. Page milliseconds use the document's `performance.now()`. Native-at-receipt is later than JS capture. Cold app launches are not necessarily cold OS/WebKit caches. The one-second automatic-push delay gives warm-up a head start; compare the zero-delay run too.

The page records `initial` (head script after viewport/style, before body), `dom`, `load`, `frame`, `pageshow`, and inset-change checkpoints, plus effective CSS values and available element rectangles. `frame` is an animation-frame callback, not evidence of a displayed frame. Instrumentation forces style resolution and can affect timing. Video and device observation are still required to evaluate visible jumps.

## Portable checks

```sh
node --test tests/bridge.test.cjs
python3 -m unittest discover -s tests
bash -n scripts/benchmark.sh
git diff --check
```

See [VERIFICATION.md](docs/VERIFICATION.md) for results and reproduction steps.
