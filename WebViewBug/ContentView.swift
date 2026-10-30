import SwiftUI

private var pageURL: URL {
    URL(string: UserDefaults.standard.string(forKey: "pageURL") ?? "http://localhost:8000")!
}

@MainActor
struct ContentView: View {
    @State private var path: [URL] = []
    @State private var pool = WebViewPool()
    @State private var didAutoPush = false
    private let strategy = LoadStrategy.current

    var body: some View {
        NavigationStack(path: $path) {
            VStack(spacing: 24) {
                Text("WebViewBug").font(.largeTitle.bold())
                Text("Strategy: \(strategy.rawValue)").foregroundStyle(.secondary)
                NavigationLink("Open WebView", value: pageURL).buttonStyle(.borderedProminent)
            }
            .background(WindowReader { window in
                if strategy.prewarms { pool.warm(origin: pageURL, in: window, priming: strategy == .preprime) }
            })
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: URL.self) { url in
                WebViewScreen(url: url, strategy: strategy, pool: pool)
            }
            .task {
                guard UserDefaults.standard.bool(forKey: "autoPush"), !didAutoPush else { return }
                didAutoPush = true
                let defaults = UserDefaults.standard
                let configured = defaults.object(forKey: "autoPushDelay") == nil ? 1 : defaults.double(forKey: "autoPushDelay")
                let delay = configured.isFinite ? max(0, configured) : 1
                do { try await Task.sleep(for: .seconds(delay)) } catch { return }
                path = [pageURL]
            }
        }
    }
}

@MainActor
struct WebViewScreen: View {
    let url: URL
    let strategy: LoadStrategy
    let pool: WebViewPool
    @State private var isNavigationBarHidden = false

    var body: some View {
        WebView(url: url, strategy: strategy, pool: pool, isNavigationBarHidden: $isNavigationBarHidden)
            .ignoresSafeArea()
            .navigationTitle("WebView")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar(isNavigationBarHidden ? .hidden : .visible, for: .navigationBar)
            .animation(.default, value: isNavigationBarHidden)
    }
}

// Resolve the window that actually hosts this scene, rather than choosing a global key window.
@MainActor
private struct WindowReader: UIViewRepresentable {
    let onWindow: (UIWindow) -> Void
    func makeUIView(context: Context) -> ReaderView { ReaderView(onWindow: onWindow) }
    func updateUIView(_ uiView: ReaderView, context: Context) { uiView.onWindow = onWindow }

    final class ReaderView: UIView {
        var onWindow: (UIWindow) -> Void
        init(onWindow: @escaping (UIWindow) -> Void) {
            self.onWindow = onWindow
            super.init(frame: .zero)
            isUserInteractionEnabled = false
        }
        required init?(coder: NSCoder) { fatalError("Use init(onWindow:)") }
        override func didMoveToWindow() {
            super.didMoveToWindow()
            DispatchQueue.main.async { [weak self] in
                guard let self, let window = self.window else { return }
                self.onWindow(window)
            }
        }
    }
}
