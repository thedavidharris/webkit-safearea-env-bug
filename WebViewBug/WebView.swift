import SwiftUI
import WebKit

/// Selected with `-strategy none|inject|prewarm|both` so the workarounds can be compared.
enum LoadStrategy: String {
    case none, inject, prewarm, both

    static var current: LoadStrategy {
        UserDefaults.standard.string(forKey: "strategy").flatMap(LoadStrategy.init) ?? .both
    }

    var injectsSafeAreaInsets: Bool { self == .inject || self == .both }
    var prewarms: Bool { self == .prewarm || self == .both }
}

struct WebView: UIViewRepresentable {
    let url: URL
    let strategy: LoadStrategy
    @Binding var isNavigationBarHidden: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(isNavigationBarHidden: $isNavigationBarHidden, probe: LoadProbe(strategy: strategy))
    }

    func makeUIView(context: Context) -> InsetAwareWebView {
        let webView = strategy.prewarms ? WebViewPool.shared.dequeue() : WebViewPool.makeWebView()
        webView.scrollView.delegate = context.coordinator
        webView.publishesSafeAreaInsets = strategy.injectsSafeAreaInsets
        webView.configuration.userContentController.add(context.coordinator.probe, name: LoadProbe.messageName)
        webView.loadWhenInWindow(URLRequest(url: url))
        return webView
    }

    func updateUIView(_ webView: InsetAwareWebView, context: Context) {
        context.coordinator.isNavigationBarHidden = $isNavigationBarHidden
    }

    static func dismantleUIView(_ webView: InsetAwareWebView, coordinator: Coordinator) {
        webView.configuration.userContentController.removeScriptMessageHandler(forName: LoadProbe.messageName)
    }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        var isNavigationBarHidden: Binding<Bool>
        let probe: LoadProbe

        init(isNavigationBarHidden: Binding<Bool>, probe: LoadProbe) {
            self.isNavigationBarHidden = isNavigationBarHidden
            self.probe = probe
        }

        func scrollViewWillEndDragging(
            _ scrollView: UIScrollView,
            withVelocity velocity: CGPoint,
            targetContentOffset: UnsafeMutablePointer<CGPoint>
        ) {
            guard velocity.y != 0 else { return }
            isNavigationBarHidden.wrappedValue = velocity.y > 0 && targetContentOffset.pointee.y > 0
        }

        func scrollViewDidScrollToTop(_ scrollView: UIScrollView) {
            isNavigationBarHidden.wrappedValue = false
        }
    }
}

/// Logs the page's inset measurements with the time since the web view was requested.
final class LoadProbe: NSObject, WKScriptMessageHandler {
    static let messageName = "probe"
    private let strategy: LoadStrategy
    private let start = ContinuousClock.now

    init(strategy: LoadStrategy) {
        self.strategy = strategy
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: String] else { return }
        let elapsed = (ContinuousClock.now - start).formatted(.units(allowed: [.milliseconds]))
        print("PROBE \(strategy) \(body["event"] ?? "?") +\(elapsed) env[\(body["env"] ?? "")] native[\(body["native"] ?? "")]")
    }
}

/// Loads only once it is in a window, so `safeAreaInsets` is final before the first request.
/// Optionally mirrors the insets into `--native-safe-area-inset-*`, because WebKit delivers
/// `env(safe-area-inset-*)` to a new web process only after it has parsed and laid out the page.
final class InsetAwareWebView: WKWebView {
    var publishesSafeAreaInsets = false
    private var pendingRequest: URLRequest?
    private var insetScript: WKUserScript?
    private var publishedInsets: UIEdgeInsets?

    func loadWhenInWindow(_ request: URLRequest) {
        pendingRequest = request
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard window != nil, let request = pendingRequest else { return }
        pendingRequest = nil
        publishSafeAreaInsetsIfNeeded()
        load(request)
    }

    override func safeAreaInsetsDidChange() {
        super.safeAreaInsetsDidChange()
        guard window != nil else { return }
        publishSafeAreaInsetsIfNeeded()
    }

    private func publishSafeAreaInsetsIfNeeded() {
        guard publishesSafeAreaInsets, safeAreaInsets != publishedInsets else { return }
        publishedInsets = safeAreaInsets

        let source = Self.insetScriptSource(for: safeAreaInsets)
        let script = WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: true)
        let controller = configuration.userContentController
        let otherScripts = controller.userScripts.filter { $0 !== insetScript }
        controller.removeAllUserScripts()
        (otherScripts + [script]).forEach(controller.addUserScript)
        insetScript = script

        evaluateJavaScript(source)
    }

    private static func insetScriptSource(for insets: UIEdgeInsets) -> String {
        """
        (() => {
            const sheet = window.__nativeSafeAreaInsetSheet ??= new CSSStyleSheet();
            sheet.replaceSync(`:root {
                --native-safe-area-inset-top: \(insets.top)px;
                --native-safe-area-inset-right: \(insets.right)px;
                --native-safe-area-inset-bottom: \(insets.bottom)px;
                --native-safe-area-inset-left: \(insets.left)px;
            }`);
            if (!document.adoptedStyleSheets.includes(sheet)) {
                document.adoptedStyleSheets = [...document.adoptedStyleSheets, sheet];
            }
        })();
        """
    }
}

/// Keeps one web view with a running web process ready, so a push skips process launch.
/// While warming it sits invisibly in the key window so its process also receives safe area updates.
@MainActor
final class WebViewPool {
    static let shared = WebViewPool()
    private var warmWebView: InsetAwareWebView?

    func warm(origin: URL) {
        guard warmWebView == nil, let window = Self.keyWindow else { return }
        let webView = Self.makeWebView()
        webView.frame = window.bounds
        webView.alpha = 0
        webView.isUserInteractionEnabled = false
        window.insertSubview(webView, at: 0)
        webView.loadHTMLString("", baseURL: origin)
        warmWebView = webView
    }

    func dequeue() -> InsetAwareWebView {
        guard let webView = warmWebView else { return Self.makeWebView() }
        warmWebView = nil
        webView.removeFromSuperview()
        webView.alpha = 1
        webView.isUserInteractionEnabled = true
        return webView
    }

    static func makeWebView() -> InsetAwareWebView {
        let webView = InsetAwareWebView()
        // Don't adjust insets so content runs under the nav bar.
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        return webView
    }

    private static var keyWindow: UIWindow? {
        UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.keyWindow }
            .first
    }
}
