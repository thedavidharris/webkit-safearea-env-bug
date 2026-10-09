import SwiftUI

private let pageURL = URL(string: "http://localhost:8000")!

struct ContentView: View {
    @State private var path: [URL] = []
    private let strategy = LoadStrategy.current

    var body: some View {
        NavigationStack(path: $path) {
            VStack(spacing: 24) {
                Text("WebViewBug")
                    .font(.largeTitle.bold())
                Text("Strategy: \(strategy.rawValue)")
                    .foregroundStyle(.secondary)
                NavigationLink("Open WebView", value: pageURL)
                    .buttonStyle(.borderedProminent)
            }
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: URL.self) { url in
                WebViewScreen(url: url, strategy: strategy)
            }
            .onAppear {
                if strategy.prewarms {
                    WebViewPool.shared.warm(origin: pageURL)
                }
            }
            .task {
                // `-autoPush YES` opens the web view without a tap, for scripted runs.
                guard UserDefaults.standard.bool(forKey: "autoPush") else { return }
                try? await Task.sleep(for: .seconds(1))
                path = [pageURL]
            }
        }
    }
}

struct WebViewScreen: View {
    let url: URL
    let strategy: LoadStrategy
    @State private var isNavigationBarHidden = false

    var body: some View {
        WebView(url: url, strategy: strategy, isNavigationBarHidden: $isNavigationBarHidden)
            .ignoresSafeArea()
            .navigationTitle("WebView")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar(isNavigationBarHidden ? .hidden : .visible, for: .navigationBar)
            .animation(.default, value: isNavigationBarHidden)
    }
}
