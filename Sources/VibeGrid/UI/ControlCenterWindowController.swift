#if os(macOS)
import AppKit
import WebKit

private final class FirstClickWKWebView: WKWebView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }
}

final class ControlCenterWindowController: NSWindowController, NSWindowDelegate, WKNavigationDelegate, WKUIDelegate {
    private static let resourceBundleName = "VibeGrid_VibeGrid.bundle"

    private weak var appState: AppState?
    private let webView: WKWebView
    private let bridge: UIBridge
    private var allowedOriginDirectory: URL?

    init(appState: AppState) {
        self.appState = appState
        let configuration = WKWebViewConfiguration()
        let userContentController = WKUserContentController()
        configuration.userContentController = userContentController
        configuration.defaultWebpagePreferences.preferredContentMode = .desktop

        webView = FirstClickWKWebView(frame: .zero, configuration: configuration)
        bridge = UIBridge(webView: webView, appState: appState)

        userContentController.add(bridge, name: "vibeGridBridge")

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1450, height: 860),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "VibeGrid Control Center"
        window.titleVisibility = .visible
        Self.positionWindowAtTop(window)
        window.isReleasedWhenClosed = false

        super.init(window: window)
        window.delegate = self
        webView.navigationDelegate = self
        webView.uiDelegate = self

        setupWindowContent()
        loadWebApp()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    deinit {
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "vibeGridBridge")
    }

    func refresh(
        forceMoveEverythingWindowRefresh: Bool = false,
        allowMoveEverythingWindowRefresh: Bool = true
    ) {
        bridge.pushStateToWeb(
            forceMoveEverythingWindowRefresh: forceMoveEverythingWindowRefresh,
            allowMoveEverythingWindowRefresh: allowMoveEverythingWindowRefresh
        )
    }

    func setMoveEverythingAlwaysOnTop(_ enabled: Bool) {
        guard let window else {
            return
        }
        window.level = enabled ? .statusBar : .normal
    }

    func openSettingsModal() {
        attemptOpenSettingsModal(remainingAttempts: 20)
    }

    func windowWillClose(_ notification: Notification) {
        appState?.handleControlCenterClosed()
    }

    func windowDidBecomeKey(_ notification: Notification) {
        bridge.pushStateToWeb(allowMoveEverythingWindowRefresh: false)
    }

    func windowDidResignKey(_ notification: Notification) {
        bridge.pushStateToWeb(allowMoveEverythingWindowRefresh: false)
    }

    private func setupWindowContent() {
        guard let window else { return }
        window.contentView = webView
    }

    private func loadWebApp() {
        let candidates = Self.webAppIndexCandidates()

        guard let indexURL = candidates.compactMap({ $0 }).first else {
            let html = """
            <html><body style=\"font-family:-apple-system;padding:40px\">
            <h2>VibeGrid UI Missing</h2>
            <p>Could not load bundled web UI resources.</p>
            </body></html>
            """
            webView.loadHTMLString(html, baseURL: nil)
            return
        }

        let readAccess = indexURL.deletingLastPathComponent()
        allowedOriginDirectory = readAccess
        webView.loadFileURL(indexURL, allowingReadAccessTo: readAccess)
    }

    private static func webAppIndexCandidates() -> [URL?] {
        candidateResourceBundles().flatMap { bundle in
            [
                bundle.url(forResource: "index", withExtension: "html", subdirectory: "web"),
                bundle.url(forResource: "index", withExtension: "html", subdirectory: "Resources/web"),
                bundle.url(forResource: "index", withExtension: "html")
            ]
        }
    }

    private static func candidateResourceBundles() -> [Bundle] {
        var bundles: [Bundle] = []
        var seenPaths = Set<String>()

        func appendBundle(at url: URL?) {
            guard let url, let bundle = Bundle(url: url) else {
                return
            }
            let path = bundle.bundleURL.path
            guard seenPaths.insert(path).inserted else {
                return
            }
            bundles.append(bundle)
        }

        if let resourceURL = Bundle.main.resourceURL {
            appendBundle(at: resourceURL.appendingPathComponent(resourceBundleName, isDirectory: true))
        }

        if let executableDir = Bundle.main.executableURL?.deletingLastPathComponent() {
            appendBundle(at: executableDir.appendingPathComponent(resourceBundleName, isDirectory: true))
        }

        return bundles
    }

    private static func positionWindowAtTop(_ window: NSWindow) {
        let frame = window.frame
        let targetScreen = NSScreen.main ?? NSScreen.screens.first
        guard let targetScreen else {
            return
        }

        let visible = targetScreen.visibleFrame
        let x = visible.midX - (frame.width / 2)
        let y = visible.maxY - frame.height
        window.setFrameOrigin(NSPoint(x: x, y: y))
    }

    private func attemptOpenSettingsModal(remainingAttempts: Int) {
        let script = "(function(){ if (window.vibeGridOpenSettingsModal) { window.vibeGridOpenSettingsModal(); return true; } return false; })();"
        webView.evaluateJavaScript(script) { [weak self] value, _ in
            let opened = value as? Bool ?? false
            guard !opened, remainingAttempts > 0 else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                self?.attemptOpenSettingsModal(remainingAttempts: remainingAttempts - 1)
            }
        }
    }

    // MARK: - WKNavigationDelegate

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.cancel)
            return
        }
        // Allow file:// URLs within the bundled resource directory.
        if url.isFileURL, let allowed = allowedOriginDirectory {
            if url.standardized.path.hasPrefix(allowed.standardized.path) {
                decisionHandler(.allow)
                return
            }
        }
        // Allow about:blank (used internally by WebKit).
        if url.absoluteString == "about:blank" {
            decisionHandler(.allow)
            return
        }
        decisionHandler(.cancel)
    }

    // MARK: - WKUIDelegate

    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        nil
    }
}

#endif
