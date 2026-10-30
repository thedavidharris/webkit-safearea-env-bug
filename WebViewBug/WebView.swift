import SwiftUI
import WebKit

// Priming is an experiment, not an initial-layout guarantee.
enum LoadStrategy: String {
    case none, inject, prewarm, both, prime

    static var current: LoadStrategy {
        UserDefaults.standard.string(forKey: "strategy").flatMap(LoadStrategy.init) ?? .inject
    }

    var injectsSafeAreaInsets: Bool { self == .inject || self == .both }
    var prewarms: Bool { self == .prewarm || self == .both }
}

@MainActor
struct WebView: UIViewRepresentable {
    let url: URL
    let strategy: LoadStrategy
    let pool: WebViewPool
    @Binding var isNavigationBarHidden: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(isNavigationBarHidden: $isNavigationBarHidden, probe: LoadProbe(strategy: strategy))
    }

    func makeUIView(context: Context) -> InsetAwareWebView {
        let webView = strategy.prewarms ? pool.dequeue() : WebViewPool.makeWebView()
        webView.probe = context.coordinator.probe
        webView.scrollView.delegate = context.coordinator
        webView.publishesSafeAreaInsets = strategy.injectsSafeAreaInsets
        webView.loadWhenAttached(URLRequest(url: url), prime: strategy == .prime)
        return webView
    }

    func updateUIView(_ webView: InsetAwareWebView, context: Context) {
        context.coordinator.isNavigationBarHidden = $isNavigationBarHidden
    }

    static func dismantleUIView(_ webView: InsetAwareWebView, coordinator: Coordinator) {
        webView.cancelPendingWork()
        webView.scrollView.delegate = nil
        webView.probe = nil
    }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        var isNavigationBarHidden: Binding<Bool>
        let probe: LoadProbe

        init(isNavigationBarHidden: Binding<Bool>, probe: LoadProbe) {
            self.isNavigationBarHidden = isNavigationBarHidden
            self.probe = probe
        }

        func scrollViewWillEndDragging(_ scrollView: UIScrollView, withVelocity velocity: CGPoint,
                                       targetContentOffset: UnsafeMutablePointer<CGPoint>) {
            guard velocity.y != 0 else { return }
            isNavigationBarHidden.wrappedValue = velocity.y > 0 && targetContentOffset.pointee.y > 0
        }

        func scrollViewDidScrollToTop(_ scrollView: UIScrollView) {
            isNavigationBarHidden.wrappedValue = false
        }
    }
}

@MainActor
final class LoadProbe {
    private let strategy: LoadStrategy
    private let start = ProcessInfo.processInfo.systemUptime
    private let runID = UUID().uuidString

    init(strategy: LoadStrategy) { self.strategy = strategy }

    func record(_ event: String, fields: [String: Any] = [:]) {
        var record = fields
        record["event"] = event
        record["strategy"] = strategy.rawValue
        record["runID"] = runID
        record["nativeMs"] = (ProcessInfo.processInfo.systemUptime - start) * 1000
        guard JSONSerialization.isValidJSONObject(record) else {
            print("PROBE " + json(["event": "invalid-probe", "strategy": strategy.rawValue, "runID": runID]))
            return
        }
        print("PROBE " + json(record))
    }
}

private func json(_ value: Any) -> String {
    // Values here are numeric geometry, UUIDs and probe dictionaries, never executable source.
    let data = try! JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed])
    return String(decoding: data, as: UTF8.self)
}

private extension UIEdgeInsets {
    var values: [String: Double] {
        ["top": Double(top), "right": Double(right), "bottom": Double(bottom), "left": Double(left)]
    }
}

// WKUserContentController retains handlers. Keep the reference back to the view weak.
@MainActor
private final class WeakScriptHandler: NSObject, WKScriptMessageHandler {
    weak var target: InsetAwareWebView?
    init(_ target: InsetAwareWebView) { self.target = target }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.receive(message)
    }
}

@MainActor
final class InsetAwareWebView: WKWebView, WKNavigationDelegate {
    var publishesSafeAreaInsets = false
    var probe: LoadProbe?
    private var pendingRequest: URLRequest?
    private var shouldPrime = false
    private var primingRequest: URLRequest?
    private var primingID: String?
    private var primingMatches = 0
    private var primingInsets: UIEdgeInsets?
    private var primingTimeout: Task<Void, Never>?
    private var insetScript: WKUserScript?
    private var publishedInsets: UIEdgeInsets?
    private var revision = 0
    private var documentID: String?
    private var navigationGeneration = 0

    private static let bridgeSource = resource("NativeSafeArea", extension: "js")
    private static let primingHTML = resource("priming", extension: "html")

    private static func resource(_ name: String, extension ext: String) -> String {
        guard let url = Bundle.main.url(forResource: name, withExtension: ext),
              let contents = try? String(contentsOf: url, encoding: .utf8) else {
            preconditionFailure("Missing bundled resource: \(name).\(ext)")
        }
        return contents
    }

    override init(frame: CGRect, configuration: WKWebViewConfiguration) {
        super.init(frame: frame, configuration: configuration)
        navigationDelegate = self
        configuration.userContentController.add(WeakScriptHandler(self), name: "probe")
        scrollView.contentInsetAdjustmentBehavior = .never
    }

    required init?(coder: NSCoder) { fatalError("Use init(frame:configuration:)") }

    func loadWhenAttached(_ request: URLRequest, prime: Bool) {
        pendingRequest = request
        shouldPrime = prime
        setNeedsLayout()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil { setNeedsLayout() }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // Attachment and a nonempty layout are prerequisites, not proof of final geometry.
        guard window != nil, !bounds.isEmpty else { return }
        publishSafeAreaInsetsIfNeeded()
        guard let request = pendingRequest else { return }
        pendingRequest = nil
        if shouldPrime { beginPriming(request) } else { load(request) }
    }

    override func safeAreaInsetsDidChange() {
        super.safeAreaInsetsDidChange()
        guard window != nil, !bounds.isEmpty else { return }
        probe?.record("native-insets", fields: ["insets": safeAreaInsets.values])
        publishSafeAreaInsetsIfNeeded()
    }

    private func publishSafeAreaInsetsIfNeeded() {
        guard publishesSafeAreaInsets, safeAreaInsets != publishedInsets else { return }
        publishedInsets = safeAreaInsets
        revision += 1
        let source = Self.bridgeSource + "\ninstallNativeSafeArea(\(json(safeAreaInsets.values)), \(revision));"
        let script = WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: true)
        let controller = configuration.userContentController
        let otherScripts = controller.userScripts.filter { $0 !== insetScript }
        controller.removeAllUserScripts()
        // Bootstrap before scripts that might consume these values. Preserve others' relative order.
        ([script] + otherScripts).forEach(controller.addUserScript)
        insetScript = script
        if let documentID { applyCurrentInsets(to: documentID) }
    }

    private func applyCurrentInsets(to id: String) {
        guard publishesSafeAreaInsets, window != nil, !bounds.isEmpty else { return }
        let source = "window.__nativeSafeAreaBridge?.apply(\(json(safeAreaInsets.values)), \(revision), \(json(id))) ?? false"
        evaluateJavaScript(source) { [weak self] result, error in
            if let error { self?.probe?.record("bridge-error", fields: ["message": error.localizedDescription]) }
            else if (result as? Bool) != true { self?.probe?.record("bridge-stale-document") }
        }
    }

    private func reconcileDocument() {
        guard publishesSafeAreaInsets else { return }
        let generation = navigationGeneration
        evaluateJavaScript("window.__nativeSafeAreaBridge?.documentID ?? null") { [weak self] result, error in
            guard let self, generation == self.navigationGeneration else { return }
            if let error { self.probe?.record("bridge-error", fields: ["message": error.localizedDescription]) }
            guard let id = result as? String else { return }
            self.documentID = id
            self.applyCurrentInsets(to: id)
        }
    }

    func receive(_ message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, let body = message.body as? [String: Any],
              let event = body["event"] as? String else { return }
        if event == "prime-sample" {
            handlePrimingSample(body)
            return
        }
        var fields = body
        // Native receipt and JS capture occur at different times; keep them clearly separate.
        fields["nativeAtReceipt"] = safeAreaInsets.values
        probe?.record(event, fields: fields)
        if event == "bridge-ready", let id = body["documentID"] as? String {
            documentID = id
            publishSafeAreaInsetsIfNeeded()
            applyCurrentInsets(to: id)
        }
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        navigationGeneration += 1
        documentID = nil
        probe?.record("navigation-start")
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        publishSafeAreaInsetsIfNeeded()
        reconcileDocument()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // Recovery only: didFinish does not establish inset readiness or first-paint correctness.
        reconcileDocument()
        probe?.record("navigation-finish")
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        navigationFailed(error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        navigationFailed(error)
    }

    private func navigationFailed(_ error: Error) {
        probe?.record("navigation-error", fields: ["message": error.localizedDescription])
        if primingRequest != nil { finishPriming("prime-failed") }
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        navigationGeneration += 1
        documentID = nil
        probe?.record("process-terminated")
        if primingRequest != nil { finishPriming("prime-process-terminated") }
        else { reload() } // Demo recovery policy; app integrations should choose their own.
    }

    private func beginPriming(_ request: URLRequest) {
        primingRequest = request
        let id = UUID().uuidString
        primingID = id
        primingMatches = 0
        primingInsets = nil
        probe?.record("prime-start")
        let html = Self.primingHTML.replacingOccurrences(of: "__PRIMING_ID_JSON__", with: json(id))
        loadHTMLString(html, baseURL: request.url)
        let configured = UserDefaults.standard.double(forKey: "primeTimeout")
        let timeout = configured > 0 && configured.isFinite ? min(configured, 30) : 3
        primingTimeout = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(timeout)) } catch { return }
            guard let self, self.primingID == id else { return }
            self.finishPriming("prime-timeout")
        }
    }

    private func handlePrimingSample(_ body: [String: Any]) {
        guard primingRequest != nil, body["primingID"] as? String == primingID,
              window != nil, !bounds.isEmpty, let measured = body["env"] as? [String: Double] else { return }
        let expected = safeAreaInsets
        if primingInsets != expected { primingMatches = 0; primingInsets = expected }
        let matches = expected.values.allSatisfy { edge, value in
            guard let actual = measured[edge] else { return false }
            return actual.isFinite && abs(actual - value) <= 0.5
        }
        primingMatches = matches ? primingMatches + 1 : 0
        // Zero is legitimate. Require two samples against unchanged native geometry, not top > 0.
        if primingMatches >= 2 {
            probe?.record("prime-match", fields: ["env": measured, "expected": expected.values])
            finishPriming("prime-ready")
        }
    }

    private func finishPriming(_ outcome: String) {
        guard let request = primingRequest else { return }
        primingRequest = nil
        primingID = nil
        primingTimeout?.cancel()
        primingTimeout = nil
        probe?.record(outcome)
        // Timeout/failure falls back to an ordinary load, never counts as successful priming.
        load(request)
    }

    func cancelPendingWork() {
        primingTimeout?.cancel()
        primingTimeout = nil
        primingRequest = nil
        primingID = nil
        pendingRequest = nil
        documentID = nil
        navigationGeneration += 1
        stopLoading()
    }
}

// Owned by one ContentView/scene. Empty HTML deliberately remains the process-only control.
@MainActor
final class WebViewPool {
    private var warmWebView: InsetAwareWebView?

    func warm(origin: URL, in window: UIWindow) {
        guard warmWebView == nil else { return }
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
        InsetAwareWebView(frame: .zero, configuration: WKWebViewConfiguration())
    }
}
