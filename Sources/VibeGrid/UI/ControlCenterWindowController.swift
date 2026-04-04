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
        if !Self.restoreSavedFrame(window, settings: appState.config.settings) {
            Self.positionWindowAtTop(window)
        }
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

    func openWindowEditor(forKey key: String) {
        bridge.sendOpenWindowEditor(key: key)
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

    private static func restoreSavedFrame(_ window: NSWindow, settings: Settings) -> Bool {
        guard let x = settings.controlCenterFrameX,
              let y = settings.controlCenterFrameY,
              let w = settings.controlCenterFrameWidth,
              let h = settings.controlCenterFrameHeight,
              w > 0, h > 0 else {
            return false
        }
        let frame = NSRect(x: x, y: y, width: w, height: h)
        // Only restore if the frame intersects a connected screen
        let intersectsScreen = NSScreen.screens.contains { $0.frame.intersects(frame) }
        guard intersectsScreen else {
            return false
        }
        window.setFrame(frame, display: false)
        return true
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

    /// Position (and optionally resize) the window near the given cursor point.
    /// If `contentSize` is provided the window is resized to exactly that content area.
    func placeWindowNearCursor(at cursor: NSPoint, contentSize: NSSize? = nil) {
        guard let window else { return }
        let targetScreen = NSScreen.screens.first(where: { NSMouseInRect(cursor, $0.frame, false) })
            ?? NSScreen.main
            ?? NSScreen.screens.first
        guard let screen = targetScreen else { return }
        let visible = screen.visibleFrame
        // Compute the full frame size, incorporating a new content size if given
        let frameSize: NSSize
        if let cs = contentSize {
            let contentRect = NSRect(origin: .zero, size: cs)
            frameSize = window.frameRect(forContentRect: contentRect).size
        } else {
            frameSize = window.frame.size
        }
        // Center horizontally on cursor, bottom of window sits at cursor
        var x = cursor.x - frameSize.width / 2
        var y = cursor.y - frameSize.height
        x = max(visible.minX, min(x, visible.maxX - frameSize.width))
        y = max(visible.minY, min(y, visible.maxY - frameSize.height))
        window.setFrame(NSRect(origin: NSPoint(x: x, y: y), size: frameSize), display: false, animate: false)
    }

    func shrinkQuickViewToFitContent(maxHeight: CGFloat) {
        // Delay to let the web view render the window list, then retry a few times
        // as items may still be loading
        shrinkQuickViewAttempt(maxHeight: maxHeight, attempts: 5, previousHeight: 0)
    }

    private func shrinkQuickViewAttempt(maxHeight: CGFloat, attempts: Int, previousHeight: CGFloat) {
        guard attempts > 0 else { return }
        // Measure the workspace content + header, not the full page
        let script = """
            (function() {
                var ws = document.getElementById('moveEverythingWorkspace');
                var header = document.querySelector('header');
                if (!ws) return document.body.scrollHeight;
                var h = ws.scrollHeight;
                if (header) h += header.offsetHeight;
                return h + 16;
            })()
            """
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self else { return }
            self.webView.evaluateJavaScript(script) { [weak self] value, _ in
                guard let self, let window = self.window,
                      let contentHeight = (value as? NSNumber)?.doubleValue else { return }
                let idealHeight = min(CGFloat(contentHeight), maxHeight)
                let frame = window.frame
                if idealHeight < frame.height {
                    let newFrame = NSRect(
                        x: frame.origin.x,
                        y: frame.origin.y + (frame.height - idealHeight),
                        width: frame.width,
                        height: idealHeight
                    )
                    window.setFrame(newFrame, display: true, animate: false)
                }
                // Retry if content is still loading (height changed)
                if CGFloat(contentHeight) != previousHeight && attempts > 1 {
                    self.shrinkQuickViewAttempt(maxHeight: maxHeight, attempts: attempts - 1, previousHeight: CGFloat(contentHeight))
                }
            }
        }
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

    func webView(
        _ webView: WKWebView,
        runJavaScriptTextInputPanelWithPrompt prompt: String,
        defaultText: String?,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping (String?) -> Void
    ) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = prompt.isEmpty ? "Enter text" : prompt
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")

        let textField = NSTextField(string: defaultText ?? "")
        textField.frame = NSRect(x: 0, y: 0, width: 360, height: 24)
        alert.accessoryView = textField

        // Position the dialog near the current cursor, not attached to the VibeGrid window
        let mouseLocation = NSEvent.mouseLocation
        let alertWindow = alert.window
        let windowSize = alertWindow.frame.size
        alertWindow.setFrameOrigin(NSPoint(
            x: mouseLocation.x - windowSize.width / 2,
            y: mouseLocation.y - windowSize.height / 2
        ))

        let response = alert.runModal()
        completionHandler(response == .alertFirstButtonReturn ? textField.stringValue : nil)
    }
}

#endif
