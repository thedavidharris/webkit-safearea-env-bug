# WKWebView `env(safe-area-inset-*)` is 0 on first load

[WebKit bug 191872](https://bugs.webkit.org/show_bug.cgi?id=191872) (rdar://46193462), open since iOS 12 and still reproducible on iOS 27.

A `WKWebView` that ignores the safe area (full-bleed content under a transparent nav bar) loads a page that uses `env(safe-area-inset-*)`. The page's first parse, first layout, `DOMContentLoaded`, `load`, and first animation frame all read 0. The real values arrive some time later, so anything positioned with them jumps.

This repo reproduces it in a SwiftUI app, measures it, and compares workarounds.

## Running

```sh
python3 -m http.server 8000   # serves index.html
open WebViewBug.xcodeproj     # run on an iPhone simulator
```

Tap "Open WebView". The page has a full-bleed hero that starts behind the transparent nav bar. Its text should start at the dashed line, which marks the bottom of the nav bar. A fixed panel at the bottom shows `env()` and the injected `--native-safe-area-inset-*` values: live, and at first script, `DOMContentLoaded`, `load`, and first frame. Swipe up to hide the nav bar and watch the top inset change.

Launch arguments (Xcode scheme or `simctl launch`):

| Argument | Effect |
|---|---|
| `-strategy none\|inject\|prewarm\|both` | Workaround to use, see below. Default `both`. |
| `-autoPush YES` | Pushes the web view without a tap, for scripted runs. |

Each measurement is also printed to the console as a `PROBE` line, with the time since the web view was created.

```sh
scripts/benchmark.sh <booted-simulator-udid> [runs-per-strategy]
```

The benchmark cold-launches each strategy N times and prints the first-script measurements.

## Root cause

This comes from reading WebKit source (`Source/WebKit/UIProcess/API/ios/WKWebViewIOS.mm` and related files) and has not been confirmed with a debugger.

- The safe-area insets reach the web process only inside a `VisibleContentRectUpdateInfo`. `-[WKWebView _createVisibleContentRectUpdate]` builds it from `_computedUnobscuredSafeAreaInset`, and WebKit sends it from a CATransaction pre-commit handler. `WebPageCreationParameters` carries `obscuredContentInsets` but no safe-area insets, so a new page starts with zero.
- `WebPageProxy::updateVisibleContentRects` only caches the update when no web process is running (`hasRunningProcess()` is false). After the first layer tree commit for a new load, `WebPageProxyCocoa.mm` clears that cache (`lastVisibleContentRectUpdate = { }`).
- `_updateVisibleContentRects` also returns early in several "unstable" states (`_shouldDeferGeometryUpdates`, a pending `resetViewStateAfterTransactionID` after a main-frame commit, keyboard inset adjustment, and others). Those states are common during the first navigation.
- On the web-process side, `WebPage::updateVisibleContentRects` calls `Page::setUnobscuredSafeAreaInsets`. That updates the CSS environment variables and forces a style recalc on every document.

So the first page is parsed and laid out before any update reaches its process, and `env()` is 0 until a later update gets through. Safari doesn't show the bug in practice because its view is already on screen and laid out by the time a page loads.

## Measurements

iPhone 18 Pro Max simulator, iOS 27.0. 5 cold launches per strategy, web view pushed under an inline nav bar. Native insets: top 116 (status bar plus nav bar), bottom 34.

| Strategy | Time to first script | `env()` at first script, `DOMContentLoaded`, `load`, first frame | `--native-*` |
|---|---|---|---|
| `none` | 706 to 1,614 ms | all 0 | n/a |
| `inject` | 693 to 1,411 ms | all 0 | 116 / 34 |
| `prewarm` | 58 to 86 ms | all 0 | n/a |
| `both` | 56 to 73 ms | all 0 | 116 / 34 |

`env()` reached the correct values only after `load`, in every strategy.

## Routes to a fix

### 1. Inject the insets yourself (used here)

`InsetAwareWebView` in `WebViewBug/WebView.swift` waits until it is in a window, so `safeAreaInsets` is final. It then installs an `.atDocumentStart` user script that adopts a stylesheet defining `--native-safe-area-inset-{top,right,bottom,left}`, and updates it from `safeAreaInsetsDidChange`. Page CSS uses:

```css
padding-top: max(env(safe-area-inset-top), var(--native-safe-area-inset-top, 0px));
```

- Correct from the first layout, with no measurable load cost.
- Safari and other hosts fall back to `env()`.
- No jump when `env()` catches up, because both report the same values.
- Only CSS you control benefits. Third-party CSS still sees 0 on the first layout.
- It only swaps its own `WKUserScript`, so other user scripts are kept.

### 2. Pre-warm a web view (used here, for speed)

`WebViewPool` creates a web view early, parks it invisibly in the key window, and loads an empty document on the target origin. It hands that web view over on push, which moves process launch off the tap: about 10x faster to first script.

Pre-warming does not fix `env()`: the warm process still reads 0 for the real page's first layout. Why is unexplained. Likely suspects are a process swap on navigation, or per-page state being reset on the main-frame commit (`resetViewStateAfterTransactionID`).

### 3. Prime with a blank load, then load the real page (rejected)

Load a same-origin document that polls `env()` until it matches the native insets, then load the real URL. This made `env()` correct at first script in every run. It was rejected because it adds a full navigation plus at least one frame to the critical path of every first load.

### 4. Hide the UI until `load` (does not work)

An earlier idea was to keep the web UI hidden until `window.onload` / `document.readyState === "complete"`. The measurements show `env()` is still 0 at `load`, so this is not reliable.

### 5. Fix WebKit

The direct fix is to include the unobscured safe-area insets in `WebPageCreationParameters`, filled from `_computedUnobscuredSafeAreaInset`. They would be applied in the `WebPage` constructor next to `setObscuredContentInsets` (`WebPage.cpp`), including on process-swap reinitialization. A narrower option is to send the insets on their own when they change, independent of visible-rect deferral. Either needs a TestWebKitAPI test that reads `env(safe-area-inset-top)` from an inline script in a view with non-zero safe-area insets.

## Recommendation

For an app that needs fast, correct full-bleed web content today: pre-warm for speed, and inject the insets for correct initial layout (`-strategy both`).
