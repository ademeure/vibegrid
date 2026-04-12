#if os(macOS)
import AppKit
import Foundation
import ITermActivityKit
import ServiceManagement
import UniformTypeIdentifiers
import CryptoKit

enum FileDialogResult {
    case success(String)
    case cancelled
    case failure(String)
}

extension Notification.Name {
    static let vibeGridAccessibilityStatusDidUpdate = Notification.Name("vibeGridAccessibilityStatusDidUpdate")
}

struct LaunchAtLoginState {
    let supported: Bool
    let enabled: Bool
    let requiresApproval: Bool
    let message: String
}

struct LaunchAtLoginUpdateResult {
    let state: LaunchAtLoginState
    let errorMessage: String?
}

struct RuntimeEnvironment {
    let sandboxed: Bool
    let message: String
}

final class AppState {
    private static let startupAccessibilityResetMarkerKey = "VibeGridStartupAccessibilityResetAttempted"
    private static let startupAccessibilityResetMarkerKeyPrefix = "VibeGridStartupAccessibilityResetAttempted."
    private static let startupAccessibilityKnownGrantedMarkerKey = "VibeGridStartupAccessibilityKnownGranted"
    private static let startupAccessibilityKnownFingerprintMarkerKey = "VibeGridStartupAccessibilityKnownFingerprint"
    private let configStore = ConfigStore()
    private let windowPositionSaveStore = WindowPositionSaveStore()
    private let windowListActivityConfigSync = WindowListActivityConfigSync()
    private var moveEverythingITermWindowOverridesByID: [String: WindowListActivityConfigSync.ITermWindowOverride] = [:]
    private var moveEverythingITermWindowOverridesByNumber: [Int: WindowListActivityConfigSync.ITermWindowOverride] = [:]
    private let launchAtLoginService = LaunchAtLoginService()
    private let placementPreviewOverlay = PlacementPreviewOverlayController()
    private let windowManager: WindowManagerEngineProtocol
    private var moveEverythingAlwaysOnTop = false
    private var moveEverythingMoveToBottom = false
    private var moveEverythingDontMoveVibeGrid = false
    private var moveEverythingShowOverlays = true
    private var moveEverythingModeWasActive = false
    private var windowEditorSavedFrame: NSRect?
    private var windowEditorWasVisible = false
    private var windowEditorCursorPosition: NSPoint?
    private var windowEditorRestorePending = false
    private var quickViewActive = false
    private var quickViewSavedFrame: NSRect?
    private var quickViewWasVisible = false
    private let iTermActivityWorkerClient = ITermActivityWorkerClient()
    private(set) var iTermActivityCache: [String: String] = [:]  // snapshot key → "active"/"idle"
    private(set) var iTermLastActiveAt: [String: Date] = [:]  // snapshot key → when last became active
    private(set) var iTermBadgeTextCache: [String: String] = [:]  // snapshot key → badge text
    private(set) var iTermSessionNameCache: [String: String] = [:]  // snapshot key → session/tmux name
    private(set) var iTermLastLineCache: [String: String] = [:]  // snapshot key → last non-empty screen line
    private(set) var iTermActivityProfileCache: [String: String] = [:]  // snapshot key → profile id (e.g. "claude-code", "codex")
    private(set) var iTermPaneCommandCache: [String: String] = [:]  // snapshot key → tmux pane foreground command
    private(set) var iTermPanePathCache: [String: String] = [:]  // snapshot key → tmux pane current path
    private(set) var iTermPaneTitleCache: [String: String] = [:]  // snapshot key → tmux pane title (e.g. Claude Code session name)
    private var iTermTmuxFallbackLastActiveAt: [String: Date] = [:]  // snapshot key → last time tmux fallback saw active
    private var iTermRuntimeWindowIDBySnapshotKey: [String: String] = [:]  // snapshot key → pty-... runtime id
    private let iTermActivityOverlayController = ITermActivityOverlayController()
    private struct OriginalBackground {
        let dark: (r: Int, g: Int, b: Int)
        let light: (r: Int, g: Int, b: Int)
        let useSeparateColors: Bool
    }
    private var iTermOriginalBackgroundByWindowID: [String: OriginalBackground] = [:]
    private var iTermCurrentBgTintStatus: [String: String] = [:]  // windowID → "active"/"idle"/""
    private var iTermCurrentTabColorStatus: [String: String] = [:]  // windowID → "active"/"idle"/""
    private var pendingITermColorCommands: [[String: Any]] = []
    private static let tintedWindowsFileURL: URL = {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/VibeGrid")
            .appendingPathComponent("tinted-windows.json")
    }()
    private var iTermInputTimestamps: [Int: Date] = [:]  // windowNumber → last interaction time
    private var lastGlobalInputAt: Date = .distantPast
    private var globalInputMonitor: Any?
    private var iTermActivityPollInFlight = false
    private var iTermActivityPollStartedAt: Date?
    private var iTermActivityPollLastCompletedAt: Date?
    private var iTermActivityPollGeneration = 0

    private let iTermActivityPollTimeout: TimeInterval = 1.5
    private let iTermActivityPollStaleAfter: TimeInterval = 3.0
    private let iTermActivityPollMinInterval: TimeInterval = 0.25

    private(set) var config: AppConfig
    private var cachedConfigYAML: String?
    private var cachedConfigJSONObject: Any?
    private var controlCenter: ControlCenterWindowController?

    init() {
        let initialConfig = configStore.loadOrCreate()
        config = initialConfig
        let loadedOverrides = windowListActivityConfigSync.loadOverrides()
        moveEverythingITermWindowOverridesByID = loadedOverrides.byID
        moveEverythingITermWindowOverridesByNumber = loadedOverrides.byNumber
        windowListActivityConfigSync.sync(
            settings: initialConfig.settings,
            iTermWindowOverridesByID: moveEverythingITermWindowOverridesByID,
            iTermWindowOverridesByNumber: moveEverythingITermWindowOverridesByNumber
        )
        ITermWindowInventoryResolver.ensurePythonVenv(debugContext: "startup")
        windowManager = Self.makeWindowManager(initialConfig: initialConfig)
        windowManager.seedMoveEverythingSavedWindowPositions(windowPositionSaveStore.loadSnapshots())
        windowManager.onMoveEverythingSavedWindowPositionsHistoryChanged = { [windowPositionSaveStore] snapshots in
            DispatchQueue.global(qos: .utility).async {
                _ = windowPositionSaveStore.saveSnapshots(snapshots)
            }
        }
        windowManager.isMoveEverythingAlwaysOnTopEnabledProvider = { [weak self] in
            self?.moveEverythingAlwaysOnTop ?? false
        }
        windowManager.onCloseWindowOverride = { [weak self] key in
            guard let self else {
                NSLog("VibeGrid: close override — self is nil for key=%@", key)
                return
            }
            guard self.config.settings.moveEverythingCloseMuxKill else {
                NSLog("VibeGrid: close override — moveEverythingCloseMuxKill disabled for key=%@", key)
                return
            }
            guard let sessionName = self.iTermSessionNameCache[key] else {
                NSLog("VibeGrid: close override — no session in cache for key=%@ (cache has %d entries: %@)",
                      key, self.iTermSessionNameCache.count,
                      self.iTermSessionNameCache.map { "\($0.key)=\($0.value)" }.joined(separator: ", "))
                return
            }
            NSLog("VibeGrid: close override — dispatching mux kill for key=%@ session=%@", key, sessionName)
            // Kill the mux session async — the caller AX-closes the window
            // immediately so the user gets instant visual feedback.
            DispatchQueue.global(qos: .utility).async {
                AppState.muxKill(sessionName: sessionName)
            }
        }
        windowManager.onMoveEverythingModeChanged = { [weak self] isActive in
            DispatchQueue.main.async {
                guard let self else {
                    return
                }
                if isActive != self.moveEverythingModeWasActive {
                    if isActive {
                        self.setMoveEverythingAlwaysOnTop(enabled: self.config.settings.moveEverythingStartAlwaysOnTop)
                        self.setMoveEverythingMoveToBottom(enabled: self.config.settings.moveEverythingStartMoveToBottom)
                        self.setMoveEverythingDontMoveVibeGrid(enabled: self.config.settings.moveEverythingStartDontMoveVibeGrid)
                    } else {
                        if self.moveEverythingAlwaysOnTop {
                            self.moveEverythingAlwaysOnTop = false
                            self.controlCenter?.setMoveEverythingAlwaysOnTop(false)
                        }
                        if self.moveEverythingMoveToBottom {
                            self.moveEverythingMoveToBottom = false
                            self.windowManager.setMoveEverythingMoveToBottom(false)
                        }
                        if self.moveEverythingDontMoveVibeGrid {
                            self.moveEverythingDontMoveVibeGrid = false
                            self.windowManager.setMoveEverythingDontMoveVibeGrid(false)
                        }
                        self.windowManager.setMoveEverythingPinMode(false)
                    }
                    self.moveEverythingModeWasActive = isActive
                }
                self.controlCenter?.refresh()
            }
        }
        windowManager.onMoveEverythingInventoryRefreshed = { [weak self] in
            DispatchQueue.main.async {
                guard let self,
                      self.controlCenter?.window?.isVisible == true else {
                    return
                }
                self.controlCenter?.refresh(forceMoveEverythingWindowRefresh: true)
            }
        }
        windowManager.onMoveEverythingNameWindowRequested = { [weak self] key in
            DispatchQueue.main.async {
                guard let self else { return }
                // If the editor is already open, just refocus — don't overwrite the saved frame
                if self.windowEditorRestorePending {
                    self.controlCenter?.showWindow(nil)
                    NSApp.activate(ignoringOtherApps: true)
                    self.controlCenter?.window?.makeKeyAndOrderFront(nil)
                    self.controlCenter?.openWindowEditor(forKey: key)
                    return
                }
                self.ensureMoveEverythingMode()
                // Save current visibility and position so we can restore after the editor closes
                let cursor = NSEvent.mouseLocation
                self.windowEditorCursorPosition = cursor
                self.windowEditorWasVisible = self.controlCenter?.window?.isVisible ?? false
                self.windowEditorSavedFrame = self.controlCenter?.window?.frame
                self.windowEditorRestorePending = true
                // Show at cursor with a sensible initial compact size; JS will send exact dimensions
                self.controlCenter?.placeWindowNearCursor(at: cursor, contentSize: NSSize(width: 580, height: 500))
                self.controlCenter?.showWindow(nil)
                NSApp.activate(ignoringOtherApps: true)
                self.controlCenter?.window?.makeKeyAndOrderFront(nil)
                // Push fresh inventory before opening the editor so JS can find any window type.
                // Both evaluateJavaScript calls are queued in order, so inventory arrives first.
                self.controlCenter?.refresh(forceMoveEverythingWindowRefresh: true)
                self.controlCenter?.openWindowEditor(forKey: key)
            }
        }
        windowManager.onMoveEverythingQuickViewRequested = { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                self.toggleQuickView()
            }
        }
        // Track any global input for activity overlay suppression.
        globalInputMonitor = NSEvent.addGlobalMonitorForEvents(matching: [
            .keyDown, .keyUp, .flagsChanged, .scrollWheel,
            .leftMouseDown, .leftMouseUp, .rightMouseDown,
        ]) { [weak self] _ in
            self?.lastGlobalInputAt = Date()
        }
    }

    private static func makeWindowManager(initialConfig: AppConfig) -> WindowManagerEngineProtocol {
        WindowManagerEngine(initialConfig: initialConfig)
    }
    func openControlCenter() {
        if controlCenter == nil {
            controlCenter = ControlCenterWindowController(appState: self)
            // Restore iTerm colors left tinted by a previous crash
            restoreTintedWindowsFromPreviousSession()
        }

        placementPreviewOverlay.prepare()
        controlCenter?.showWindow(nil)
        controlCenter?.setMoveEverythingAlwaysOnTop(moveEverythingAlwaysOnTop)
        controlCenter?.refresh()
        NSApp.activate(ignoringOtherApps: true)
    }

    func openSettings() {
        if controlCenter == nil {
            controlCenter = ControlCenterWindowController(appState: self)
        }

        placementPreviewOverlay.prepare()
        controlCenter?.showWindow(nil)
        controlCenter?.setMoveEverythingAlwaysOnTop(moveEverythingAlwaysOnTop)
        controlCenter?.refresh()
        controlCenter?.openSettingsModal()
        NSApp.activate(ignoringOtherApps: true)
    }

    func hideControlCenter() {
        placementPreviewOverlay.hide()
        controlCenter?.window?.orderOut(nil)
    }

    func handleWindowEditorOpened(cardWidth: Int, cardHeight: Int) {
        guard windowEditorRestorePending,
              let cursor = windowEditorCursorPosition else { return }
        // Add modal overlay padding (20px each side)
        let contentSize = NSSize(width: CGFloat(cardWidth) + 40, height: CGFloat(cardHeight) + 40)
        controlCenter?.placeWindowNearCursor(at: cursor, contentSize: contentSize)
    }

    func handleWindowEditorClosed() {
        defer {
            windowEditorSavedFrame = nil
            windowEditorWasVisible = false
            windowEditorCursorPosition = nil
            windowEditorRestorePending = false
        }

        guard windowEditorRestorePending else {
            return
        }

        if !windowEditorWasVisible {
            controlCenter?.window?.orderOut(nil)
        } else if let saved = windowEditorSavedFrame {
            controlCenter?.window?.setFrame(saved, display: false, animate: false)
        }
    }

    func toggleQuickView() {
        if quickViewActive {
            // Restore
            if !quickViewWasVisible {
                controlCenter?.window?.orderOut(nil)
            } else if let saved = quickViewSavedFrame {
                controlCenter?.window?.setFrame(saved, display: false, animate: false)
            }
            quickViewSavedFrame = nil
            quickViewWasVisible = false
            quickViewActive = false
        } else {
            // Save state
            quickViewWasVisible = controlCenter?.window?.isVisible ?? false
            quickViewSavedFrame = controlCenter?.window?.frame
            quickViewActive = true

            let cursor = NSEvent.mouseLocation
            let screen = NSScreen.screens.first(where: { NSMouseInRect(cursor, $0.frame, false) })
                ?? NSScreen.main
                ?? NSScreen.screens.first
            let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1920, height: 1080)

            let verticalMode = config.settings.moveEverythingQuickViewVerticalMode
            let placementY: CGFloat
            let availableHeight: CGFloat

            switch verticalMode {
            case .fullHeight:
                placementY = visible.minY
                availableHeight = visible.height
            case .fromCursor:
                let extraAbove: CGFloat = 150
                let topY = min(cursor.y + extraAbove, visible.maxY)
                placementY = visible.minY
                availableHeight = max(200, topY - visible.minY)
            case .padded:
                let padTop = visible.height * 0.2
                let padBottom = visible.height * 0.2
                placementY = visible.minY + padBottom
                availableHeight = max(200, visible.height - padTop - padBottom)
            }

            let contentSize = NSSize(width: 550, height: availableHeight)
            let placementCursor = NSPoint(x: cursor.x, y: placementY + availableHeight)

            ensureMoveEverythingMode()
            controlCenter?.placeWindowNearCursor(at: placementCursor, contentSize: contentSize)
            controlCenter?.showWindow(nil)
            NSApp.activate(ignoringOtherApps: true)
            controlCenter?.window?.makeKeyAndOrderFront(nil)

            // Shrink to fit content after the web view renders
            controlCenter?.shrinkQuickViewToFitContent(maxHeight: availableHeight)
        }
    }

    func refresh() {
        let next = configStore.loadOrCreate()
        config = next
        cachedConfigYAML = nil
        cachedConfigJSONObject = nil
        windowListActivityConfigSync.sync(
            settings: next.settings,
            iTermWindowOverridesByID: moveEverythingITermWindowOverridesByID,
            iTermWindowOverridesByNumber: moveEverythingITermWindowOverridesByNumber
        )
        windowManager.applyConfig(next)
        placementPreviewOverlay.hide()
        controlCenter?.refresh()
        publishAccessibilityStatus()
    }

    @discardableResult
    func save(config nextConfig: AppConfig, refreshControlCenter: Bool = true) -> Bool {
        let normalized = nextConfig.normalized()
        let didSave = configStore.save(normalized)
        guard didSave else { return false }

        config = normalized
        cachedConfigYAML = nil
        cachedConfigJSONObject = nil
        // Force iTerm tints to re-apply with new colors on next poll cycle
        iTermCurrentBgTintStatus.removeAll()
        iTermCurrentTabColorStatus.removeAll()
        // Re-push all window names (handles ALL CAPS toggle change)
        reapplyAllITermWindowNames()
        windowListActivityConfigSync.sync(
            settings: normalized.settings,
            iTermWindowOverridesByID: moveEverythingITermWindowOverridesByID,
            iTermWindowOverridesByNumber: moveEverythingITermWindowOverridesByNumber
        )
        windowManager.applyConfig(normalized)
        if refreshControlCenter {
            controlCenter?.refresh()
        }
        return true
    }

    @discardableResult
    func requestAccessibility(prompt: Bool, resetPermissionState: Bool = false) -> Bool {
        if resetPermissionState {
            _ = resetAccessibilityPermissionState()
        }
        let granted = windowManager.requestAccessibility(prompt: prompt)
        if resetPermissionState {
            if granted {
                clearStartupAccessibilityResetState()
            } else {
                markStartupAccessibilityResetState()
            }
        }
        if granted {
            markStartupAccessibilityKnownGrantedState()
        }
        return granted
    }

    @discardableResult
    func requestAccessibilityOnStartup(prompt: Bool) -> Bool {
        let isGranted = windowManager.requestAccessibility(prompt: false)
        if isGranted {
            clearStartupAccessibilityResetState()
            markStartupAccessibilityKnownGrantedState()
            return true
        }

        let shouldReset = shouldResetAccessibilityPermissionAtStartup()
        if shouldReset {
            _ = resetAccessibilityPermissionState()
            markStartupAccessibilityResetState()
        }

        let grantedAfterReset = windowManager.requestAccessibility(prompt: shouldReset ? prompt : false)
        if grantedAfterReset {
            clearStartupAccessibilityResetState()
            markStartupAccessibilityKnownGrantedState()
        }
        return grantedAfterReset
    }

    func clearStartupAccessibilityResetState() {
        UserDefaults.standard.removeObject(forKey: Self.startupAccessibilityResetMarkerKey)
        let bundleMarker = startupAccessibilityLegacyResetMarkerKey()
        if !bundleMarker.isEmpty {
            UserDefaults.standard.removeObject(forKey: bundleMarker)
        }
    }

    private func markStartupAccessibilityResetState() {
        UserDefaults.standard.set(true, forKey: Self.startupAccessibilityResetMarkerKey)
    }

    private func markStartupAccessibilityKnownGrantedState() {
        UserDefaults.standard.set(true, forKey: Self.startupAccessibilityKnownGrantedMarkerKey)
        let fingerprint = startupAccessibilityExecutableFingerprint()
        if !fingerprint.isEmpty {
            UserDefaults.standard.set(fingerprint, forKey: Self.startupAccessibilityKnownFingerprintMarkerKey)
        }
    }

    @discardableResult
    func resetAccessibilityPermissionState() -> Bool {
        guard let bundleIdentifier = Bundle.main.bundleIdentifier,
              !bundleIdentifier.isEmpty else {
            return false
        }

        let tccutilPath = "/usr/bin/tccutil"
        guard FileManager.default.isExecutableFile(atPath: tccutilPath) else {
            return false
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: tccutilPath)
        process.arguments = ["reset", "Accessibility", bundleIdentifier]

        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            NSLog("VibeGrid: Failed to reset Accessibility permissions for %@: %@", bundleIdentifier, error.localizedDescription)
            return false
        }
    }

    func accessibilityGranted() -> Bool {
        windowManager.requestAccessibility(prompt: false)
    }

    func beginHotkeyCapture() {
        windowManager.setHotkeysSuspended(true)
    }

    func endHotkeyCapture() {
        windowManager.setHotkeysSuspended(false)
    }

    func previewPlacement(_ placement: PlacementStep) {
        guard let frame = windowManager.previewRect(for: placement) else {
            placementPreviewOverlay.hide()
            return
        }
        placementPreviewOverlay.show(frame: frame)
    }

    func hidePlacementPreview() {
        placementPreviewOverlay.hide()
    }

    func openConfigFile() {
        NSWorkspace.shared.open(configStore.configURL)
    }

    func revealConfigInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([configStore.configURL])
    }

    func copyConfigPathToPasteboard() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(configStore.configURL.path, forType: .string)
    }

    func exportConfigAsYAML() -> FileDialogResult {
        let panel = NSSavePanel()
        panel.allowedContentTypes = yamlContentTypes
        panel.nameFieldStringValue = "vibegrid-config.yaml"
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false

        guard panel.runModal() == .OK, let url = panel.url else {
            return .cancelled
        }

        do {
            try YAMLConfigCodec.encode(config).write(to: url, atomically: true, encoding: .utf8)
            return .success("Saved YAML to \(url.path)")
        } catch {
            return .failure("Failed to save YAML: \(error.localizedDescription)")
        }
    }

    func importConfigFromYAML() -> FileDialogResult {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = yamlContentTypes
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false

        guard panel.runModal() == .OK, let url = panel.url else {
            return .cancelled
        }

        do {
            let text = try String(contentsOf: url, encoding: .utf8)
            let parsed = try YAMLConfigCodec.decode(text)
            guard save(config: parsed) else {
                return .failure("Failed to apply imported config")
            }
            return .success("Loaded YAML from \(url.path)")
        } catch {
            return .failure("Failed to load YAML: \(error)")
        }
    }

    func configURLString() -> String {
        configStore.configURL.path
    }

    func configParseError() -> String? {
        configStore.lastParseError
    }

    func runtimeEnvironment() -> RuntimeEnvironment {
        let sandboxed = isRunningInAppSandbox
        if sandboxed {
            return RuntimeEnvironment(
                sandboxed: true,
                message: "Sandboxed runtime detected. macOS App Sandbox restricts window-control automation APIs."
            )
        }

        return RuntimeEnvironment(
            sandboxed: false,
            message: ""
        )
    }

    func configYAML() -> String {
        if let cached = cachedConfigYAML {
            return cached
        }
        let raw = configStore.loadRawText()
        let result = raw.isEmpty ? YAMLConfigCodec.encode(config) : raw
        cachedConfigYAML = result
        return result
    }

    func configJSONObject() -> Any? {
        if let cached = cachedConfigJSONObject {
            return cached
        }
        guard let data = try? JSONEncoder().encode(config),
              let obj = try? JSONSerialization.jsonObject(with: data) else {
            return nil
        }
        cachedConfigJSONObject = obj
        return obj
    }

    func hotKeyRegistrationIssues() -> [HotKeyRegistrationIssue] {
        windowManager.registrationIssues()
    }

    func moveEverythingModeActive() -> Bool {
        windowManager.isMoveEverythingActive
    }

    func moveEverythingControlCenterFocused() -> Bool {
        windowManager.moveEverythingControlCenterFocused()
    }

    func moveEverythingFocusedWindowKey() -> String? {
        windowManager.moveEverythingFocusedWindowKeySnapshot()
    }

    func controlCenterFocused() -> Bool {
        controlCenter?.window?.isKeyWindow ?? false
    }

    func moveEverythingWindowInventory() -> MoveEverythingWindowInventory {
        windowManager.moveEverythingWindowInventory()
    }

    @discardableResult
    func ensureMoveEverythingMode() -> Bool {
        if moveEverythingModeActive() {
            return true
        }
        _ = windowManager.toggleMoveEverythingMode()
        return moveEverythingModeActive()
    }

    @discardableResult
    func closeMoveEverythingWindow(withKey key: String) -> Bool {
        windowManager.closeMoveEverythingWindow(withKey: key)
    }

    /// Matches mux session naming convention: machine-number[-name] (e.g. "local-0-dev", "neb-1-train").
    static func isMuxSessionName(_ name: String) -> Bool {
        name.range(of: #"^[a-zA-Z][a-zA-Z0-9]*-\d+"#, options: .regularExpression) != nil
    }

    /// Extract a repository group name from iTerm window metadata.
    /// Checks session name, badge text, window title, and iTerm window name
    /// for path-like patterns (e.g. "~/github/vibegrid") or known naming conventions.
    static func extractRepositoryGroup(
        sessionName: String?,
        badgeText: String?,
        windowTitle: String?,
        iTermWindowName: String?,
        panePath: String? = nil
    ) -> String? {
        // Try each candidate in priority order
        let candidates = [sessionName, badgeText, windowTitle, iTermWindowName, panePath]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        for candidate in candidates {
            if let repo = extractRepoFromString(candidate) {
                return repo
            }
        }
        return nil
    }

    private static func extractRepoFromString(_ text: String) -> String? {
        // 1. Bracket/angle-bracket prefix: "[vgrid] task name (tmux)" → "vgrid"
        //    Also handles "<cli> task (tmux)" → "cli"
        let bracketPattern = #"^\[([^\]]+)\]"#
        if let match = text.range(of: bracketPattern, options: .regularExpression) {
            let inner = String(text[match])
                .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            if !inner.isEmpty {
                return inner
            }
        }
        let anglePattern = #"^<([^>]+)>"#
        if let match = text.range(of: anglePattern, options: .regularExpression) {
            let inner = String(text[match])
                .trimmingCharacters(in: CharacterSet(charactersIn: "<>"))
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            if !inner.isEmpty {
                return inner
            }
        }

        // 2. Mux session names and Claude session IDs have no repo info —
        //    skip them so we fall through to pane path extraction.
        let trimmedForMux = text.replacingOccurrences(of: #"\s*\(tmux\)\s*$"#, with: "", options: .regularExpression)
        if isMuxSessionName(trimmedForMux) {
            return nil
        }
        if trimmedForMux.range(of: #"^cs-[0-9a-f]+"#, options: [.regularExpression, .caseInsensitive]) != nil {
            return nil
        }

        // 4. Path-like pattern: extract last meaningful component
        //    Handles ~/github/repo, /Users/x/github/repo, ~/repo, repo — path/to/dir
        let pathPattern = #"(?:^|[\s—\-|:])(?:~|/\w[\w/]*?)/([\w][\w.\-]*?)(?:\s|$|—|\||:)"#
        if let match = text.range(of: pathPattern, options: .regularExpression) {
            let matchStr = String(text[match])
            let cleaned = matchStr.trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "—|: "))
            let components = cleaned.split(separator: "/").map(String.init)
            if let last = components.last, !last.isEmpty {
                return last.lowercased()
            }
        }

        // 5. Worktree path: .claude/worktrees/fork-xxx → use the repo containing .claude/ + "⑂"
        if let worktreeRange = text.range(of: ".claude/worktrees/") {
            let repoPath = String(text[text.startIndex..<worktreeRange.lowerBound])
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let components = repoPath.split(separator: "/").map(String.init)
            if let last = components.last, !last.isEmpty {
                return "\(last.lowercased()) ⑂"
            }
        }

        // 6. Simple path: if the whole string looks like a path
        if text.contains("/") {
            let components = text.split(separator: "/").map(String.init)
            if let last = components.last?.trimmingCharacters(in: .whitespacesAndNewlines),
               !last.isEmpty,
               last.range(of: #"^[\w][\w.\-]*$"#, options: .regularExpression) != nil {
                return last.lowercased()
            }
        }

        // 6. Claude Code session title: "reponame (claude)" or "reponame (codex)"
        //    The suffix is REQUIRED — without it, bare words like "osascript" would false-positive.
        let claudePattern = #"^([\w][\w.\-]*)\s+\((?:claude|codex)\)\s*$"#
        if let match = text.range(of: claudePattern, options: [.regularExpression, .caseInsensitive]) {
            let repo = String(text[match])
                .replacingOccurrences(of: #"\s*\((?:claude|codex)\)\s*$"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            if !repo.isEmpty, repo.count > 1 {
                return repo
            }
        }

        return nil
    }

    /// Convert mux session name (e.g. "neb-8", "neb-8-train") to colon-separated
    /// machine:target format (e.g. "neb:8", "neb:8-train") that `mux kill` expects.
    /// Local sessions like "local-124" become "local:124".
    static func muxKillArgument(from sessionName: String) -> String {
        // Pattern: machine-number[-suffix] → machine:number[-suffix]
        guard sessionName.range(
            of: #"^([a-zA-Z][a-zA-Z0-9]*)-(\d+.*)$"#,
            options: .regularExpression
        ) != nil else {
            return sessionName
        }
        // Find the first "-" followed by a digit
        if let dashIndex = sessionName.firstIndex(where: { $0 == "-" }),
           let nextIndex = sessionName.index(dashIndex, offsetBy: 1, limitedBy: sessionName.endIndex),
           sessionName[nextIndex].isNumber {
            var result = sessionName
            result.replaceSubrange(dashIndex...dashIndex, with: ":")
            return result
        }
        return sessionName
    }

    /// Run `mux kill <sessionName>` to cleanly terminate a mux session and its iTerm window.
    @discardableResult
    static func muxKill(sessionName: String) -> Bool {
        guard let muxBin = findMuxBinary() else {
            NSLog("VibeGrid: mux binary not found, falling back to AX close")
            return false
        }
        let killArg = muxKillArgument(from: sessionName)
        NSLog("VibeGrid: mux kill %@ (from session name %@)", killArg, sessionName)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: muxBin)
        process.arguments = ["kill", killArg]
        let semaphore = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in semaphore.signal() }
        do {
            try process.run()
            // Timeout after 10s — remote sessions need SSH roundtrips.
            // This runs async so the timeout doesn't block the UI.
            if semaphore.wait(timeout: .now() + 10) == .timedOut {
                NSLog("VibeGrid: mux kill timed out for session %@, falling back to AX close", sessionName)
                process.terminate()
                return false
            }
            if process.terminationStatus == 0 {
                NSLog("VibeGrid: mux kill succeeded for session %@", sessionName)
                return true
            } else {
                NSLog("VibeGrid: mux kill exited with status %d for session %@", process.terminationStatus, sessionName)
                return false
            }
        } catch {
            NSLog("VibeGrid: mux kill failed for session %@: %@", sessionName, error.localizedDescription)
            return false
        }
    }

    static func captureTmuxPaneLines(session: String, maxLines: Int = 30) -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["tmux", "capture-pane", "-t", session, "-p"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return [] }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard let output = String(data: data, encoding: .utf8) else { return [] }
            return output.split(separator: "\n", omittingEmptySubsequences: true)
                .suffix(maxLines)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        } catch {
            return []
        }
    }

    // MARK: - vibed daemon integration

    /// Path to the vibed daemon's state file, written every ~2-3 seconds.
    private static let vibedStatePath = NSString("~/.local/state/vibed/state.json").expandingTildeInPath

    /// Read vibed daemon state and override the activity cache for Claude/Codex
    /// sessions where vibed's process-tree detection is available.
    /// This runs after both the screen-content detector and tmux fallback,
    /// so vibed data takes highest priority.
    ///
    /// Matching strategy (in priority order):
    ///   1. window_id (pty-...) → iTermRuntimeWindowIDBySnapshotKey (most reliable)
    ///   2. session name → iTermSessionNameCache (for remote sessions where the
    ///      iTerm window was created by a previous mux session but now runs a
    ///      different tmux session — the window_id still links them)
    ///
    /// We trust vibed's `tool` field ("claude"/"codex") and do NOT require
    /// VibeGrid's profile cache to confirm — vibed's detection is more reliable
    /// for remote sessions where screen-content heuristics may fail.
    static func overlayVibedSessionActivity(
        cache: inout [String: String],
        profileCache: inout [String: String],
        sessionNameCache: [String: String],
        runtimeWindowIDByKey: [String: String],
        lastActiveAt: inout [String: Date],
        logger: WindowListDebugLogger.Type
    ) {
        guard FileManager.default.fileExists(atPath: vibedStatePath) else { return }

        // Only read if the file was updated recently (within 10 seconds)
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: vibedStatePath),
              let modDate = attrs[.modificationDate] as? Date,
              Date().timeIntervalSince(modDate) < 10 else {
            return
        }

        guard let data = try? Data(contentsOf: URL(fileURLWithPath: vibedStatePath)),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sessions = root["sessions"] as? [String: Any] else {
            return
        }

        // Build reverse maps for matching
        var snapshotKeyByWindowID: [String: String] = [:]
        for (snapshotKey, windowID) in runtimeWindowIDByKey {
            snapshotKeyByWindowID[windowID] = snapshotKey
        }
        var snapshotKeyBySessionName: [String: String] = [:]
        for (snapshotKey, sessionName) in sessionNameCache {
            snapshotKeyBySessionName[sessionName] = snapshotKey
        }

        for (_, sessionValue) in sessions {
            guard let session = sessionValue as? [String: Any] else { continue }

            // Only override Claude/Codex sessions (trust vibed's tool field)
            let tool = session["tool"] as? String ?? ""
            guard tool == "claude" || tool == "codex" else { continue }

            let sessionName = session["name"] as? String ?? ""

            // Try matching: window_id first, then session name
            var snapshotKey: String?
            var matchedVia = ""

            if let windowID = session["window_id"] as? String,
               !windowID.isEmpty,
               let key = snapshotKeyByWindowID[windowID] {
                snapshotKey = key
                matchedVia = "window_id"
            } else if !sessionName.isEmpty,
                      let key = snapshotKeyBySessionName[sessionName] {
                snapshotKey = key
                matchedVia = "session_name"
            }

            guard let key = snapshotKey else { continue }

            let vibedStatus = session["status"] as? String ?? ""
            let activityReason = session["activity_reason"] as? String ?? ""
            let currentCacheValue = cache[key] ?? "idle"

            // Map vibed status to VibeGrid's "active"/"idle"
            let newStatus = vibedStatus == "active" ? "active" : "idle"

            // Ensure the profile cache reflects the tool type from vibed,
            // so that UI styling (activity colors, indicators) applies correctly.
            // The screen-content detector may classify remote sessions as
            // "default+tmux" instead of "claude-code" — vibed knows better.
            let currentProfile = profileCache[key] ?? ""
            let baseProfile = currentProfile.split(separator: "+").first.map(String.init) ?? currentProfile
            if baseProfile != "claude-code" && baseProfile != "codex" {
                // Preserve the "+tmux" suffix if present
                let suffix = currentProfile.contains("+") ? "+" + currentProfile.split(separator: "+").dropFirst().joined(separator: "+") : ""
                let vibedProfile = (tool == "codex" ? "codex" : "claude-code") + suffix
                profileCache[key] = vibedProfile
            }

            if newStatus != currentCacheValue {
                logger.log(
                    "vibed-overlay",
                    "key=\(key) session=\(sessionName) matched=\(matchedVia) vibed=\(vibedStatus) reason=\(activityReason) was=\(currentCacheValue) now=\(newStatus)"
                )
                cache[key] = newStatus
                if newStatus == "active" {
                    lastActiveAt[key] = Date()
                }
            }
        }
    }

    private static func findMuxBinary() -> String? {
        // Same search order as the Python worker
        let candidates = [
            "/usr/local/bin/mux",
            NSString("~/github/mux/mux").expandingTildeInPath,
        ]
        for path in candidates {
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }
        return nil
    }

    @discardableResult
    func hideMoveEverythingWindow(withKey key: String) -> Bool {
        windowManager.hideMoveEverythingWindow(withKey: key)
    }

    @discardableResult
    func showHiddenMoveEverythingWindow(withKey key: String) -> Bool {
        windowManager.showHiddenMoveEverythingWindow(withKey: key)
    }

    @discardableResult
    func showAllHiddenMoveEverythingWindows() -> Bool {
        windowManager.showAllHiddenMoveEverythingWindows()
    }

    @discardableResult
    func saveCurrentMoveEverythingWindowPositions() -> Bool {
        windowManager.saveCurrentMoveEverythingWindowPositions() != nil
    }

    @discardableResult
    func restorePreviousMoveEverythingSavedWindowPositions() -> Bool {
        windowManager.restorePreviousMoveEverythingSavedWindowPositions()
    }

    @discardableResult
    func restoreNextMoveEverythingSavedWindowPositions() -> Bool {
        windowManager.restoreNextMoveEverythingSavedWindowPositions()
    }

    @discardableResult
    func focusMoveEverythingWindow(
        withKey key: String,
        movePointerToCenter: Bool
    ) -> Bool {
        windowManager.focusMoveEverythingWindow(
            withKey: key,
            movePointerToCenter: movePointerToCenter
        )
    }

    @discardableResult
    func centerMoveEverythingWindow(withKey key: String) -> Bool {
        let shouldTemporarilyDropAlwaysOnTop = moveEverythingModeActive() && moveEverythingAlwaysOnTop
        if shouldTemporarilyDropAlwaysOnTop {
            controlCenter?.setMoveEverythingAlwaysOnTop(false)
        }

        let didCenter = windowManager.centerMoveEverythingWindow(withKey: key)

        if shouldTemporarilyDropAlwaysOnTop {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                guard let self,
                      self.moveEverythingModeActive(),
                      self.moveEverythingAlwaysOnTop else {
                    return
                }
                self.controlCenter?.setMoveEverythingAlwaysOnTop(true)
            }
        }

        return didCenter
    }

    @discardableResult
    func maximizeMoveEverythingWindow(withKey key: String) -> Bool {
        windowManager.maximizeMoveEverythingWindow(withKey: key)
    }

    @discardableResult
    func renameMoveEverythingITermWindow(
        withKey key: String,
        windowNumber: Int?,
        iTermWindowID: String,
        sourceFrame: MoveEverythingWindowFrameSnapshot?,
        sourceAppName: String,
        sourceTitle: String,
        sourceDisplayedTitle: String,
        titleProvided: Bool,
        title: String,
        badgeTextProvided: Bool,
        badgeText: String,
        badgeColorProvided: Bool,
        badgeColor: String,
        badgeOpacity: Int,
        badgeSize: Int
    ) -> Bool {
        let normalizedKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
        let providedWindowNumber: Int? = {
            guard let windowNumber, windowNumber >= 0 else {
                return nil
            }
            return windowNumber
        }()
        let providedITermWindowID = iTermWindowID.trimmingCharacters(in: .whitespacesAndNewlines)
        WindowListDebugLogger.log(
            "rename",
            "request key=\(normalizedKey) providedWindowNumber=\(providedWindowNumber?.description ?? "nil") " +
                "providedITermWindowID=\(providedITermWindowID.isEmpty ? "nil" : providedITermWindowID) " +
                "sourceFrame=\(sourceFrame.map { "\($0.x),\($0.y),\($0.width),\($0.height)" } ?? "nil") " +
                "sourceAppName=\(sourceAppName) sourceTitle=\(sourceTitle) " +
                "sourceDisplayedTitle=\(sourceDisplayedTitle) titleProvided=\(titleProvided) title=\(title) " +
                "badgeTextProvided=\(badgeTextProvided) badgeText=\(badgeText) " +
                "badgeColorProvided=\(badgeColorProvided) badgeColor=\(badgeColor)"
        )
        guard !normalizedKey.isEmpty || providedWindowNumber != nil || !providedITermWindowID.isEmpty else {
            WindowListDebugLogger.log("rename", "rejected request with empty key and no provided window identity")
            return false
        }
        let inventory = moveEverythingWindowInventory()
        let matchedWindow = normalizedKey.isEmpty
            ? nil
            : (inventory.visible + inventory.hidden).first { $0.key == normalizedKey }
        if let matchedWindow {
            WindowListDebugLogger.log(
                "rename",
                "matched inventory window key=\(matchedWindow.key) appName=\(matchedWindow.appName) " +
                    "windowNumber=\(matchedWindow.windowNumber?.description ?? "nil") " +
                    "iTermWindowID=\(matchedWindow.iTermWindowID ?? "nil") title=\(matchedWindow.title)"
            )
        } else {
            WindowListDebugLogger.log("rename", "no inventory match for key=\(normalizedKey)")
        }
        let normalizedSourceAppName = sourceAppName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let normalizedMatchedAppName = matchedWindow?.appName
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
        let appLooksLikeITerm = normalizedSourceAppName.contains("iterm") ||
            normalizedMatchedAppName.contains("iterm")
        guard appLooksLikeITerm else {
            WindowListDebugLogger.log(
                "rename",
                "rejected non-iTerm rename sourceAppName=\(normalizedSourceAppName) matchedAppName=\(normalizedMatchedAppName)"
            )
            return false
        }
        let fallbackCandidateTitles = [
            sourceDisplayedTitle,
            sourceTitle,
            matchedWindow?.title ?? ""
        ]
        let resolvedIdentityAndSource: (windowID: String?, windowNumber: Int?, source: String) = {
            if let runtimeWindowID = canonicalRuntimeITermWindowID(providedITermWindowID) {
                return (runtimeWindowID, nil, "payload.runtimeID")
            }
            if let matchedWindowID = canonicalRuntimeITermWindowID(matchedWindow?.iTermWindowID ?? "") {
                return (matchedWindowID, nil, "inventory.runtimeID")
            }
            if let parsedITermWindowID = moveEverythingITermWindowID(fromKey: normalizedKey),
               let runtimeWindowID = canonicalRuntimeITermWindowID(parsedITermWindowID) {
                return (runtimeWindowID, nil, "key.runtimeID")
            }
            if let matchedWindow,
               let resolved = moveEverythingFallbackRuntimeITermWindowDescriptorForWindow(
                   matchedWindow,
                   debugContext: "rename key=\(normalizedKey) snapshotTitle=\(matchedWindow.title)"
               ) {
                return (resolved.windowID, resolved.windowNumber, "runtimeResolver.snapshot")
            }
            if let resolved = moveEverythingFallbackRuntimeITermWindowDescriptorForTitles(
                fallbackCandidateTitles,
                frame: sourceFrame.map {
                    CGRect(x: $0.x, y: $0.y, width: $0.width, height: $0.height)
                },
                debugContext: "rename key=\(normalizedKey) titles=\(fallbackCandidateTitles)"
            ) {
                return (resolved.windowID, resolved.windowNumber, "runtimeResolver.titles")
            }
            // Fallback: use the JXA-sourced iTermWindowID directly as the override key.
            // It's an integer (e.g. "1636"), not a "pty-" prefixed runtime ID, so it can't
            // be used for badge application via the Python API — but it's perfectly valid
            // for storing title/badge overrides and will be stable for the session.
            if !providedITermWindowID.isEmpty {
                return (providedITermWindowID, nil, "payload.jxaID")
            }
            if let matchedID = matchedWindow?.iTermWindowID, !matchedID.isEmpty {
                return (matchedID, nil, "inventory.jxaID")
            }
            if let fallbackNumber = providedWindowNumber ?? matchedWindow?.windowNumber {
                return (nil, fallbackNumber, "payload.windowNumber")
            }
            return (nil, nil, "unresolved")
        }()
        let resolvedITermWindowID = resolvedIdentityAndSource.windowID?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedWindowNumber = resolvedIdentityAndSource.windowNumber
        guard (resolvedITermWindowID?.isEmpty == false) || resolvedWindowNumber != nil else {
            WindowListDebugLogger.log(
                "rename",
                "failed to resolve iTerm window identity key=\(normalizedKey) source=\(resolvedIdentityAndSource.source)"
            )
            return false
        }
        WindowListDebugLogger.log(
            "rename",
            "resolved iTerm window identity key=\(normalizedKey) " +
                "windowID=\(resolvedITermWindowID ?? "nil") " +
                "windowNumber=\(resolvedWindowNumber?.description ?? "nil") " +
                "source=\(resolvedIdentityAndSource.source)"
        )
        let existingOverride: WindowListActivityConfigSync.ITermWindowOverride? = {
            if let resolvedITermWindowID, !resolvedITermWindowID.isEmpty,
               let override = moveEverythingITermWindowOverridesByID[resolvedITermWindowID] {
                return override
            }
            if let resolvedWindowNumber,
               let override = moveEverythingITermWindowOverridesByNumber[resolvedWindowNumber] {
                return override
            }
            return nil
        }()
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedBadgeText = badgeText.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedBadgeColor = badgeColor.trimmingCharacters(in: .whitespacesAndNewlines)
        let mergedTitle = titleProvided ? trimmedTitle : (existingOverride?.title ?? "")
        let mergedBadgeText = badgeTextProvided ? trimmedBadgeText : (existingOverride?.badgeText ?? "")
        let mergedBadgeColor = badgeColorProvided ? trimmedBadgeColor : (existingOverride?.badgeColor ?? "")
        let mergedBadgeOpacity = badgeColorProvided ? max(10, min(100, badgeOpacity)) : (existingOverride?.badgeOpacity ?? 60)
        let mergedBadgeSize = badgeTextProvided ? max(5, min(95, badgeSize)) : (existingOverride?.badgeSize ?? 55)
        WindowListDebugLogger.log(
            "rename",
            "merged override key=\(normalizedKey) title=\(mergedTitle) badgeText=\(mergedBadgeText) badgeColor=\(mergedBadgeColor)"
        )
        let override = WindowListActivityConfigSync.ITermWindowOverride(
            title: mergedTitle,
            badgeText: mergedBadgeText,
            badgeColor: mergedBadgeColor,
            badgeOpacity: mergedBadgeOpacity,
            badgeSize: mergedBadgeSize
        )

        if mergedTitle.isEmpty && mergedBadgeText.isEmpty && mergedBadgeColor.isEmpty && mergedBadgeOpacity == 60 && mergedBadgeSize == 55 {
            if let resolvedITermWindowID, !resolvedITermWindowID.isEmpty {
                moveEverythingITermWindowOverridesByID.removeValue(forKey: resolvedITermWindowID)
                WindowListDebugLogger.log("rename", "cleared override windowID=\(resolvedITermWindowID)")
            }
            if let resolvedWindowNumber {
                moveEverythingITermWindowOverridesByNumber.removeValue(forKey: resolvedWindowNumber)
                WindowListDebugLogger.log("rename", "cleared numeric fallback windowNumber=\(resolvedWindowNumber)")
            }
        } else {
            if let resolvedITermWindowID, !resolvedITermWindowID.isEmpty {
                moveEverythingITermWindowOverridesByID[resolvedITermWindowID] = override
                WindowListDebugLogger.log(
                    "rename",
                    "stored override windowID=\(resolvedITermWindowID) title=\(mergedTitle) " +
                        "badgeText=\(mergedBadgeText) badgeColor=\(mergedBadgeColor)"
                )
            }
            if let resolvedWindowNumber {
                if resolvedITermWindowID?.isEmpty == false {
                    moveEverythingITermWindowOverridesByNumber.removeValue(forKey: resolvedWindowNumber)
                    WindowListDebugLogger.log(
                        "rename",
                        "removed numeric fallback windowNumber=\(resolvedWindowNumber) because stable windowID is available"
                    )
                } else {
                    moveEverythingITermWindowOverridesByNumber[resolvedWindowNumber] = override
                    WindowListDebugLogger.log(
                        "rename",
                        "stored numeric fallback windowNumber=\(resolvedWindowNumber) title=\(mergedTitle) " +
                            "badgeText=\(mergedBadgeText) badgeColor=\(mergedBadgeColor)"
                    )
                }
            }
        }
        windowListActivityConfigSync.sync(
            settings: config.settings,
            iTermWindowOverridesByID: moveEverythingITermWindowOverridesByID,
            iTermWindowOverridesByNumber: moveEverythingITermWindowOverridesByNumber
        )
        WindowListDebugLogger.log(
            "rename",
            "sync complete overrideIDs=\(moveEverythingITermWindowOverridesByID.keys.sorted()) " +
                "overrideNumbers=\(moveEverythingITermWindowOverridesByNumber.keys.sorted())"
        )

        // Apply badge to iTerm immediately if we have a resolved window ID
        let effectiveBadgeText: String = {
            if !mergedBadgeText.isEmpty {
                return mergedBadgeText
            }
            if config.settings.moveEverythingITermBadgeFromTitle && !mergedTitle.isEmpty {
                return mergedTitle
            }
            return ""
        }()
        if (badgeTextProvided || titleProvided), let resolvedITermWindowID, !resolvedITermWindowID.isEmpty {
            ITermWindowInventoryResolver.applyBadge(
                windowID: resolvedITermWindowID,
                badgeText: effectiveBadgeText,
                badgeColor: mergedBadgeColor,
                badgeOpacity: mergedBadgeOpacity,
                badgeSize: mergedBadgeSize,
                debugContext: "rename key=\(normalizedKey)"
            )
        }

        // Set iTerm window title and session name via the Python API so the
        // title sticks (especially with "Apps may change title" disabled).
        if titleProvided, !mergedTitle.isEmpty, let resolvedITermWindowID, !resolvedITermWindowID.isEmpty {
            let pythonURL = ITermWindowInventoryResolver.pythonURL()
            let iTermTitle = config.settings.moveEverythingITermTitleAllCaps ? mergedTitle.uppercased() : mergedTitle
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let ok = self?.iTermActivityWorkerClient.setWindowName(
                    pythonURL: pythonURL,
                    windowID: resolvedITermWindowID,
                    name: iTermTitle
                ) ?? false
                WindowListDebugLogger.log(
                    "rename",
                    "set_name via Python API windowID=\(resolvedITermWindowID) title=\(mergedTitle) ok=\(ok)"
                )
            }
        }

        return true
    }

    @discardableResult
    func retileVisibleMoveEverythingWindows() -> Bool {
        windowManager.retileVisibleMoveEverythingWindows()
    }

    @discardableResult
    func miniRetileVisibleMoveEverythingWindows() -> Bool {
        windowManager.miniRetileVisibleMoveEverythingWindows()
    }

    @discardableResult
    func iTermRetileVisibleMoveEverythingWindows() -> Bool {
        windowManager.iTermRetileVisibleMoveEverythingWindows()
    }

    @discardableResult
    func nonITermRetileVisibleMoveEverythingWindows() -> Bool {
        windowManager.nonITermRetileVisibleMoveEverythingWindows()
    }

    @discardableResult
    func hybridRetileVisibleMoveEverythingWindows() -> Bool {
        windowManager.hybridRetileVisibleMoveEverythingWindows()
    }

    @discardableResult
    func undoLastMoveEverythingRetile() -> Bool {
        windowManager.undoLastMoveEverythingRetile()
    }

    func moveEverythingUndoRetileAvailable() -> Bool {
        windowManager.moveEverythingUndoRetileAvailable()
    }

    func moveEverythingLastDirectActionError() -> String? {
        windowManager.moveEverythingLastDirectActionError()
    }

    func moveEverythingAlwaysOnTopEnabled() -> Bool {
        moveEverythingAlwaysOnTop
    }

    func windowListDebugLogPath() -> String {
        WindowListDebugLogger.logPath()
    }

    func setMoveEverythingAlwaysOnTop(enabled: Bool) {
        let effective = enabled && moveEverythingModeActive()
        moveEverythingAlwaysOnTop = effective
        controlCenter?.setMoveEverythingAlwaysOnTop(effective)
    }

    func moveEverythingShowOverlaysEnabled() -> Bool {
        moveEverythingShowOverlays
    }

    func moveEverythingMoveToBottomEnabled() -> Bool {
        moveEverythingMoveToBottom
    }

    func moveEverythingDontMoveVibeGridEnabled() -> Bool {
        moveEverythingDontMoveVibeGrid
    }

    func setMoveEverythingShowOverlays(enabled: Bool) {
        moveEverythingShowOverlays = enabled
        windowManager.setMoveEverythingShowOverlays(enabled)
    }

    func setMoveEverythingMoveToBottom(enabled: Bool) {
        let effective = enabled && moveEverythingModeActive()
        moveEverythingMoveToBottom = effective
        windowManager.setMoveEverythingMoveToBottom(effective)
    }

    func setMoveEverythingDontMoveVibeGrid(enabled: Bool) {
        let effective = enabled && moveEverythingModeActive()
        moveEverythingDontMoveVibeGrid = effective
        windowManager.setMoveEverythingDontMoveVibeGrid(effective)
    }

    func pinMoveEverythingWindow(withKey key: String) {
        windowManager.pinMoveEverythingWindow(withKey: key)
    }

    func unpinMoveEverythingWindow(withKey key: String) {
        windowManager.unpinMoveEverythingWindow(withKey: key)
    }

    func moveEverythingPinnedKeys() -> Set<String> {
        windowManager.moveEverythingPinnedKeys()
    }

    func iTermRepoGroups() -> [String: String] {
        windowManager.iTermRepositoryGroupBySnapshotKey
    }

    func setMoveEverythingPinMode(enabled: Bool) {
        windowManager.setMoveEverythingPinMode(enabled)
    }

    func setMoveEverythingNarrowMode(enabled: Bool) {
        windowManager.setMoveEverythingNarrowMode(enabled)
    }

    @discardableResult
    func setMoveEverythingHoveredWindow(withKey key: String?) -> Bool {
        windowManager.setMoveEverythingHoveredWindow(withKey: key)
    }

    @discardableResult
    func toggleMoveEverythingMode() -> MoveEverythingToggleResult {
        windowManager.toggleMoveEverythingMode()
    }

    func launchAtLoginState() -> LaunchAtLoginState {
        launchAtLoginService.currentState()
    }

    func setLaunchAtLogin(enabled: Bool) -> LaunchAtLoginUpdateResult {
        launchAtLoginService.setEnabled(enabled)
    }

    func openLoginItemsSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    func handleControlCenterClosed() {
        placementPreviewOverlay.hide()
    }

    func terminateApp() {
        placementPreviewOverlay.hide()
        // Best-effort restore of iTerm colors on shutdown
        queueRestoreAllITermColors()
        if !pendingITermColorCommands.isEmpty {
            let commands = pendingITermColorCommands
            pendingITermColorCommands = []
            let pythonURL = ITermWindowInventoryResolver.pythonURL()
            _ = iTermActivityWorkerClient.poll(
                pythonURL: pythonURL,
                timeout: 2.0,
                maxPolledNonEmptyLines: 1,
                commands: commands
            )
        }
        NSApplication.shared.terminate(nil)
    }

    private var yamlContentTypes: [UTType] {
        let types = [UTType(filenameExtension: "yaml"), UTType(filenameExtension: "yml")].compactMap { $0 }
        return types.isEmpty ? [.plainText] : types
    }

    private func publishAccessibilityStatus() {
        NotificationCenter.default.post(
            name: .vibeGridAccessibilityStatusDidUpdate,
            object: self,
            userInfo: ["granted": accessibilityGranted()]
        )
    }

    private func moveEverythingWindowNumber(fromKey key: String) -> Int? {
        let normalized = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            return nil
        }
        let cgPattern = #"^\d+-cg-(\d+)$"#
        let managedPattern = #"^\d+-(\d+)$"#

        let candidates = [cgPattern, managedPattern]
        for pattern in candidates {
            guard let regex = try? NSRegularExpression(pattern: pattern) else {
                continue
            }
            let range = NSRange(normalized.startIndex..<normalized.endIndex, in: normalized)
            guard let match = regex.firstMatch(in: normalized, options: [], range: range),
                  match.numberOfRanges >= 2,
                  let numberRange = Range(match.range(at: 1), in: normalized),
                  let parsed = Int(normalized[numberRange]),
                  parsed >= 0 else {
                continue
            }
            return parsed
        }

        return nil
    }

    private func moveEverythingITermWindowID(fromKey key: String) -> String? {
        let normalized = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty,
              let regex = try? NSRegularExpression(pattern: #"^\d+-iterm-(.+)$"#) else {
            return nil
        }
        let range = NSRange(normalized.startIndex..<normalized.endIndex, in: normalized)
        guard let match = regex.firstMatch(in: normalized, options: [], range: range),
              match.numberOfRanges >= 2,
              let idRange = Range(match.range(at: 1), in: normalized) else {
            return nil
        }
        let parsedID = String(normalized[idRange]).trimmingCharacters(in: .whitespacesAndNewlines)
        return parsedID.isEmpty ? nil : parsedID
    }

    private func canonicalRuntimeITermWindowID(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("pty-") else {
            return nil
        }
        return trimmed
    }

    private func moveEverythingRuntimeRect(fromTopLeftRect rect: CGRect?) -> CGRect? {
        guard let rect else {
            return nil
        }
        let desktopFrame = NSScreen.screens.reduce(CGRect.null) { partial, screen in
            partial.union(screen.frame)
        }
        let cocoaY = desktopFrame.maxY - rect.origin.y - rect.size.height
        return CGRect(x: rect.origin.x, y: cocoaY, width: rect.size.width, height: rect.size.height)
    }

    private func moveEverythingFallbackRuntimeITermWindowDescriptorForWindow(
        _ snapshot: MoveEverythingWindowSnapshot,
        debugContext: String? = nil
    ) -> ITermWindowInventoryResolver.RuntimeWindowDescriptor? {
        let inventory = ITermWindowInventoryResolver.fetchRuntimeInventory(debugContext: debugContext)
        return ITermWindowInventoryResolver.resolveRuntimeWindowDescriptor(
            from: inventory,
            titleCandidates: [snapshot.title],
            frame: moveEverythingRuntimeRect(fromTopLeftRect: snapshot.frame.map {
                CGRect(x: $0.x, y: $0.y, width: $0.width, height: $0.height)
            }),
            debugContext: debugContext
        )
    }

    private func moveEverythingFallbackRuntimeITermWindowDescriptorForTitles(
        _ candidateTitles: [String],
        frame: CGRect? = nil,
        debugContext: String? = nil
    ) -> ITermWindowInventoryResolver.RuntimeWindowDescriptor? {
        let inventory = ITermWindowInventoryResolver.fetchRuntimeInventory(debugContext: debugContext)
        return ITermWindowInventoryResolver.resolveRuntimeWindowDescriptor(
            from: inventory,
            titleCandidates: candidateTitles,
            frame: moveEverythingRuntimeRect(fromTopLeftRect: frame),
            debugContext: debugContext
        )
    }

    private func iTermActivityTitleCandidates(for snapshot: MoveEverythingWindowSnapshot) -> [String] {
        [
            iTermBadgeTextCache[snapshot.key] ?? "",
            iTermSessionNameCache[snapshot.key] ?? "",
            snapshot.iTermWindowName ?? "",
            snapshot.title,
        ]
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
    }

    private func matchITermActivityEntryIndex(
        for snapshot: MoveEverythingWindowSnapshot,
        unmatchedEntries: [(offset: Int, element: ITermWindowActivityDetector.PollEntry)],
        desktopHeight: CGFloat
    ) -> Int? {
        guard let frame = snapshot.frame else {
            return nil
        }

        if let cachedRuntimeWindowID = iTermRuntimeWindowIDBySnapshotKey[snapshot.key],
           let cachedMatchIndex = unmatchedEntries.firstIndex(where: {
               $0.element.windowID == cachedRuntimeWindowID
           }) {
            return cachedMatchIndex
        }

        if let iTermWindowID = snapshot.iTermWindowID?.trimmingCharacters(in: .whitespacesAndNewlines),
           !iTermWindowID.isEmpty,
           let stableMatchIndex = unmatchedEntries.firstIndex(where: {
               $0.element.windowID == iTermWindowID
           }) {
            return stableMatchIndex
        }

        let cocoaY = desktopHeight - frame.y - frame.height
        if let strictFrameMatchIndex = unmatchedEntries.firstIndex(where: {
            abs($0.element.x - frame.x) <= 4 &&
            abs($0.element.y - cocoaY) <= 4 &&
            abs($0.element.width - frame.width) <= 4 &&
            abs($0.element.height - frame.height) <= 4
        }) {
            return strictFrameMatchIndex
        }

        let titleCandidates = iTermActivityTitleCandidates(for: snapshot)
        guard !titleCandidates.isEmpty else {
            return nil
        }

        let exactRawTitles = Set(
            titleCandidates
                .map { $0.lowercased() }
                .filter { !$0.isEmpty }
        )
        let normalizedTitles = Set(
            titleCandidates
                .map(ITermWindowInventoryResolver.normalizedTitle)
                .filter { !$0.isEmpty }
        )

        let titleMatches = unmatchedEntries.filter { candidate in
            let entry = candidate.element
            let rawFields = [
                entry.badgeText.trimmingCharacters(in: .whitespacesAndNewlines),
                entry.sessionName.trimmingCharacters(in: .whitespacesAndNewlines),
                entry.presentationName.trimmingCharacters(in: .whitespacesAndNewlines),
            ]
            let exactRawFields = Set(rawFields.map { $0.lowercased() }.filter { !$0.isEmpty })
            if !exactRawTitles.isDisjoint(with: exactRawFields) {
                return true
            }

            let normalizedFields = Set(
                rawFields
                    .map(ITermWindowInventoryResolver.normalizedTitle)
                    .filter { !$0.isEmpty }
            )
            if !normalizedTitles.isDisjoint(with: normalizedFields) {
                return true
            }

            return normalizedFields.contains { field in
                normalizedTitles.contains { title in
                    field.contains(title) || title.contains(field)
                }
            }
        }

        guard !titleMatches.isEmpty else {
            return nil
        }
        if titleMatches.count == 1 {
            return titleMatches[0].offset
        }

        return titleMatches.min(by: { lhs, rhs in
            activityFrameDistance(lhs.element, frame: frame, desktopHeight: desktopHeight) <
                activityFrameDistance(rhs.element, frame: frame, desktopHeight: desktopHeight)
        })?.offset
    }

    private func activityFrameDistance(
        _ entry: ITermWindowActivityDetector.PollEntry,
        frame: MoveEverythingWindowFrameSnapshot,
        desktopHeight: CGFloat
    ) -> Double {
        let cocoaY = Double(desktopHeight) - frame.y - frame.height
        return abs(entry.x - frame.x) +
            abs(entry.y - cocoaY) +
            abs(entry.width - frame.width) +
            abs(entry.height - frame.height)
    }

    // MARK: - iTerm activity (screen-delta polling)

    /// Kick off a background iTerm poll. A dedicated detector owns the
    /// semantic-screen heuristics and stabilizes "active vs idle" per iTerm
    /// window before the results are mapped back onto Window List snapshot keys.
    func refreshITermActivity(cachedInventory: MoveEverythingWindowInventory? = nil) {
        let now = Date()
        if let lastCompleted = iTermActivityPollLastCompletedAt,
           now.timeIntervalSince(lastCompleted) < iTermActivityPollMinInterval {
            return
        }
        if iTermActivityPollInFlight {
            if let startedAt = iTermActivityPollStartedAt,
               now.timeIntervalSince(startedAt) >= iTermActivityPollStaleAfter {
                WindowListDebugLogger.log(
                    "iterm-activity",
                    String(
                        format: "stale poll detected after %.2fs; resetting in-flight state",
                        now.timeIntervalSince(startedAt)
                    )
                )
                iTermActivityPollInFlight = false
                iTermActivityPollStartedAt = nil
                iTermActivityPollGeneration += 1
            } else {
                return
            }
        }
        let pythonURL = ITermWindowActivityDetector.defaultPythonURL()
        guard FileManager.default.isExecutableFile(atPath: pythonURL.path) else {
            WindowListDebugLogger.log("iterm-activity", "python not found at \(pythonURL.path)")
            return
        }

        iTermActivityPollInFlight = true
        iTermActivityPollStartedAt = now
        iTermActivityPollGeneration += 1
        let pollGeneration = iTermActivityPollGeneration
        let currentInventory = cachedInventory ?? moveEverythingWindowInventory()
        let maxPolledNonEmptyLines = 60
        let iTermSnapshotCount = (currentInventory.visible + currentInventory.hidden).reduce(into: 0) { count, snapshot in
            if snapshot.appName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().contains("iterm") {
                count += 1
            }
        }

        WindowListDebugLogger.log(
            "iterm-activity",
            "poll start generation=\(pollGeneration) inventoryITermWindows=\(iTermSnapshotCount)"
        )

        let colorCommands = pendingITermColorCommands
        pendingITermColorCommands = []
        let pollTimeout = colorCommands.isEmpty ? iTermActivityPollTimeout : iTermActivityPollTimeout + Double(colorCommands.count) * 1.5

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let holdSeconds = self?.config.settings.moveEverythingITermActivityHoldSeconds ?? 7.0
            let pollResult = self?.iTermActivityWorkerClient.poll(
                pythonURL: pythonURL,
                timeout: pollTimeout,
                maxPolledNonEmptyLines: maxPolledNonEmptyLines,
                commands: colorCommands,
                activeHoldOverride: holdSeconds
            ) ?? ITermWindowActivityDetector.PollResult(
                entries: [],
                activitiesByWindowID: [:],
                rawOutput: "",
                stderrText: "worker unavailable",
                terminationStatus: -1,
                parseSucceeded: false
            )
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                guard pollGeneration == self.iTermActivityPollGeneration else {
                    WindowListDebugLogger.log(
                        "iterm-activity",
                        "discarding stale poll result generation=\(pollGeneration) current=\(self.iTermActivityPollGeneration)"
                    )
                    return
                }
                self.iTermActivityPollInFlight = false
                self.iTermActivityPollStartedAt = nil
                self.iTermActivityPollLastCompletedAt = Date()

                let pollFailed = pollResult.timedOut || pollResult.terminationStatus != 0 || !pollResult.parseSucceeded
                let pollReturnedNoEntriesForITerm = iTermSnapshotCount > 0 && pollResult.entries.isEmpty
                if pollFailed || pollReturnedNoEntriesForITerm {
                    WindowListDebugLogger.log(
                        "iterm-activity",
                        "poll failed generation=\(pollGeneration) timedOut=\(pollResult.timedOut) " +
                            "status=\(pollResult.terminationStatus) parse=\(pollResult.parseSucceeded) " +
                            "entries=\(pollResult.entries.count) stderr=\(pollResult.stderrText)"
                    )
                    return
                }

                let activityEntries = pollResult.entries
                let activitiesByWindowID = pollResult.activitiesByWindowID
                var newCache: [String: String] = [:]
                var newBadgeCache: [String: String] = [:]
                var newSessionNameCache: [String: String] = [:]
                var newLastLineCache: [String: String] = [:]
                var newProfileCache: [String: String] = [:]
                var newPaneCommandCache: [String: String] = [:]
                var newPanePathCache: [String: String] = [:]
                var newPaneTitleCache: [String: String] = [:]
                var newRuntimeWindowIDBySnapshotKey: [String: String] = [:]
                let desktopHeight = NSScreen.screens.reduce(CGRect.null) { $0.union($1.frame) }.height
                var unmatchedEntries = Array(activityEntries.enumerated())

                for snapshot in currentInventory.visible + currentInventory.hidden {
                    let appName = snapshot.appName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                    guard appName.contains("iterm"), snapshot.frame != nil else { continue }
                    let matchedEntryIndex = self.matchITermActivityEntryIndex(
                        for: snapshot,
                        unmatchedEntries: unmatchedEntries,
                        desktopHeight: desktopHeight
                    )
                    if let matchedEntryIndex {
                        let matched = unmatchedEntries.remove(at: matchedEntryIndex).element
                        let activity = activitiesByWindowID[matched.windowID]
                        newRuntimeWindowIDBySnapshotKey[snapshot.key] = matched.windowID
                        newCache[snapshot.key] = activity?.status.rawValue ?? "idle"
                        // Cache original background on first encounter only.
                        // Once captured, never overwrite — the session bg may be tinted.
                        if self.iTermOriginalBackgroundByWindowID[matched.windowID] == nil {
                            self.iTermOriginalBackgroundByWindowID[matched.windowID] = OriginalBackground(
                                dark: (r: matched.backgroundColorR, g: matched.backgroundColorG, b: matched.backgroundColorB),
                                light: (r: matched.backgroundColorLightR, g: matched.backgroundColorLightG, b: matched.backgroundColorLightB),
                                useSeparateColors: matched.useSeparateColors
                            )
                        }
                        if let badgeText = activity?.badgeText, !badgeText.isEmpty {
                            newBadgeCache[snapshot.key] = badgeText
                        }
                        if let sessionName = activity?.sessionName, !sessionName.isEmpty {
                            newSessionNameCache[snapshot.key] = sessionName
                        }
                        if let lastLine = activity?.lastLine, !lastLine.isEmpty {
                            newLastLineCache[snapshot.key] = lastLine
                        }
                        if let profileID = activity?.profileID, !profileID.isEmpty {
                            newProfileCache[snapshot.key] = profileID
                        }
                        if let paneCmd = activity?.tmuxPaneCommand, !paneCmd.isEmpty {
                            newPaneCommandCache[snapshot.key] = paneCmd
                        }
                        if let panePath = activity?.tmuxPanePath, !panePath.isEmpty {
                            newPanePathCache[snapshot.key] = panePath
                        }
                        if let paneTitle = activity?.tmuxPaneTitle, !paneTitle.isEmpty {
                            newPaneTitleCache[snapshot.key] = paneTitle
                        }
                        if let activity {
                            WindowListDebugLogger.log(
                                "iterm-activity",
                                "key=\(snapshot.key) windowID=\(matched.windowID) " +
                                    "status=\(activity.status.rawValue) profile=\(activity.profileID) " +
                                    "reason=\(activity.reason) " +
                                    "semanticLines=\(activity.semanticLineCount)" +
                                    (activity.detail.isEmpty ? "" : " detail=\(activity.detail)")
                            )
                        }
                    } else {
                        newCache[snapshot.key] = "idle"
                        if let existingBadge = self.iTermBadgeTextCache[snapshot.key] {
                            newBadgeCache[snapshot.key] = existingBadge
                        }
                        if let existingName = self.iTermSessionNameCache[snapshot.key] {
                            newSessionNameCache[snapshot.key] = existingName
                        }
                        if let existingLastLine = self.iTermLastLineCache[snapshot.key] {
                            newLastLineCache[snapshot.key] = existingLastLine
                        }
                        if let existingProfile = self.iTermActivityProfileCache[snapshot.key] {
                            newProfileCache[snapshot.key] = existingProfile
                        }
                        if let existingPaneCmd = self.iTermPaneCommandCache[snapshot.key] {
                            newPaneCommandCache[snapshot.key] = existingPaneCmd
                        }
                        if let existingPanePath = self.iTermPanePathCache[snapshot.key] {
                            newPanePathCache[snapshot.key] = existingPanePath
                        }
                        if let existingPaneTitle = self.iTermPaneTitleCache[snapshot.key] {
                            newPaneTitleCache[snapshot.key] = existingPaneTitle
                        }
                        WindowListDebugLogger.log(
                            "iterm-activity",
                            "key=\(snapshot.key) unmatched runtime window; forcing idle"
                        )
                    }
                }
                // Track when each window last became active
                let now = Date()
                for (key, status) in newCache where status == "active" {
                    if self.iTermActivityCache[key] != "active" || self.iTermLastActiveAt[key] == nil {
                        self.iTermLastActiveAt[key] = now
                    }
                }
                // Prune stale entries
                for key in self.iTermLastActiveAt.keys where newCache[key] == nil {
                    self.iTermLastActiveAt.removeValue(forKey: key)
                }
                // Fallback: for idle claude-code/codex windows with a tmux session,
                // try tmux capture-pane to detect activity from actual pane content.
                for (key, status) in newCache where status == "idle" {
                    let sessionName = newSessionNameCache[key] ?? ""
                    let profileID = newProfileCache[key] ?? ""
                    guard !sessionName.isEmpty, profileID.hasPrefix("claude-code") || profileID.hasPrefix("codex") else {
                        continue
                    }
                    let tmuxLines = Self.captureTmuxPaneLines(session: sessionName)
                    guard !tmuxLines.isEmpty else { continue }
                    // Check if Claude Code is actively working (not idle at prompt).
                    // Active spinners end with "…" (e.g. "· Canoodling…", "✻ Thinking…").
                    // Completed spinners do NOT end with "…" (e.g. "✽ Cooked for 3m 0s").
                    let hasActiveIndicator = tmuxLines.contains { line in
                        let trimmed = line.trimmingCharacters(in: .whitespaces)
                        // Active spinner: Unicode char + word containing "…"
                        // e.g. "· Canoodling…" or "· Perambulating… (thinking with high effort)"
                        // But NOT completed: "✽ Cooked for 3m 0s" (no "…")
                        // Active spinner: single Unicode char + word ending in "…"
                        // e.g. "· Canoodling…" or "✻ Thinking… (5m)"
                        // NOT: "⏺ Fixed ... some text with … in it"
                        if trimmed.range(of: #"^[·✻✳✶✢●◆☉◉❖] \S+…"#, options: .regularExpression) != nil {
                            return true
                        }
                        let lower = trimmed.lowercased()
                        return (lower.contains("running") && lower.contains("bash command"))
                            || (lower.contains("reading") && lower.contains("file"))
                    }
                    if hasActiveIndicator {
                        self.iTermTmuxFallbackLastActiveAt[key] = Date()
                        newCache[key] = "active"
                        WindowListDebugLogger.log(
                            "iterm-activity",
                            "key=\(key) tmux-fallback session=\(sessionName) lines=\(tmuxLines.count) active=true"
                        )
                    } else if let lastActive = self.iTermTmuxFallbackLastActiveAt[key],
                              Date().timeIntervalSince(lastActive) < 3.0 {
                        newCache[key] = "active"
                        WindowListDebugLogger.log(
                            "iterm-activity",
                            "key=\(key) tmux-fallback session=\(sessionName) lines=\(tmuxLines.count) active=grace"
                        )
                    }
                }

                // Overlay vibed daemon session activity when available.
                // vibed uses caffeinate process-tree detection which is more
                // reliable than screen-content heuristics for Claude/Codex sessions.
                Self.overlayVibedSessionActivity(
                    cache: &newCache,
                    profileCache: &newProfileCache,
                    sessionNameCache: newSessionNameCache,
                    runtimeWindowIDByKey: newRuntimeWindowIDBySnapshotKey,
                    lastActiveAt: &self.iTermLastActiveAt,
                    logger: WindowListDebugLogger.self
                )

                self.iTermActivityCache = newCache
                self.iTermBadgeTextCache = newBadgeCache
                self.iTermSessionNameCache = newSessionNameCache
                self.iTermLastLineCache = newLastLineCache
                self.iTermActivityProfileCache = newProfileCache
                self.iTermPaneCommandCache = newPaneCommandCache
                self.iTermPanePathCache = newPanePathCache
                self.iTermPaneTitleCache = newPaneTitleCache
                self.iTermRuntimeWindowIDBySnapshotKey = newRuntimeWindowIDBySnapshotKey
                self.windowManager.iTermLastActiveAtBySnapshotKey = self.iTermLastActiveAt

                // Compute repository groups from session/badge/title/override metadata
                var repoGroups: [String: String] = [:]
                for (key, sessionName) in newSessionNameCache {
                    // Also try VibeGrid override title (user-assigned name) as a candidate
                    let overrideTitle: String? = {
                        guard let runtimeID = newRuntimeWindowIDBySnapshotKey[key],
                              let override = self.moveEverythingITermWindowOverridesByID[runtimeID] else {
                            return nil
                        }
                        let title = override.title.trimmingCharacters(in: .whitespacesAndNewlines)
                        return title.isEmpty ? nil : title
                    }()
                    if let repo = AppState.extractRepositoryGroup(
                        sessionName: sessionName,
                        badgeText: newBadgeCache[key],
                        windowTitle: nil,
                        iTermWindowName: overrideTitle,
                        panePath: newPanePathCache[key]
                    ) {
                        repoGroups[key] = repo
                    } else {
                        WindowListDebugLogger.log(
                            "iterm-repo-groups",
                            "no-group key=\(key) session=\(sessionName) panePath=\(newPanePathCache[key] ?? "nil")"
                        )
                    }
                }
                // Also check windows not in session cache but in badge/title/override
                for snapshot in currentInventory.visible + currentInventory.hidden {
                    guard repoGroups[snapshot.key] == nil else { continue }
                    let appName = snapshot.appName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                    guard appName.contains("iterm") else { continue }
                    // Prefer VibeGrid override title (user-assigned name) over the iTerm API name
                    let overrideTitle: String? = {
                        guard let runtimeID = newRuntimeWindowIDBySnapshotKey[snapshot.key],
                              let override = self.moveEverythingITermWindowOverridesByID[runtimeID] else {
                            return nil
                        }
                        let title = override.title.trimmingCharacters(in: .whitespacesAndNewlines)
                        return title.isEmpty ? nil : title
                    }()
                    if let repo = AppState.extractRepositoryGroup(
                        sessionName: newSessionNameCache[snapshot.key],
                        badgeText: newBadgeCache[snapshot.key],
                        windowTitle: snapshot.title,
                        iTermWindowName: overrideTitle ?? snapshot.iTermWindowName,
                        panePath: newPanePathCache[snapshot.key]
                    ) {
                        repoGroups[snapshot.key] = repo
                    }
                }
                self.windowManager.iTermRepositoryGroupBySnapshotKey = repoGroups
                self.windowManager.iTermActivityProfileCache = newProfileCache
                if !repoGroups.isEmpty {
                    WindowListDebugLogger.log(
                        "iterm-repo-groups",
                        "groups=\(repoGroups.sorted(by: { $0.key < $1.key }).map { "\($0.key)=\($0.value)" }.joined(separator: ", "))"
                    )
                }

                WindowListDebugLogger.log(
                    "iterm-activity",
                    "poll done generation=\(pollGeneration): matched=\(newCache.keys.sorted()) " +
                        "activity=\(newCache.filter { $0.value == "active" }.keys.sorted())"
                )

                // Update activity overlays for claude-code/codex windows
                self.refreshITermActivityOverlays(inventory: currentInventory)

                // Update iTerm background tint and tab color indicators
                self.refreshITermActivityIndicators(inventory: currentInventory)

                // Trigger a UI refresh so the updated cache is rendered
                self.controlCenter?.refresh()

                // Schedule the next poll after the minimum interval so activity
                // detection runs at a steady cadence independent of the UI timer.
                let interval = self.iTermActivityPollMinInterval
                DispatchQueue.main.asyncAfter(deadline: .now() + interval) { [weak self] in
                    self?.refreshITermActivity()
                }
            }
        }
    }

    private func refreshITermActivityOverlays(inventory: MoveEverythingWindowInventory) {
        let now = Date()
        let suppressionSeconds = config.settings.moveEverythingITermActivityHoldSeconds
        let inputCutoff = now.addingTimeInterval(-suppressionSeconds)
        // Prune old input timestamps
        iTermInputTimestamps = iTermInputTimestamps.filter { $0.value > inputCutoff }

        // Check if user recently interacted (key/click/scroll) with a focused iTerm window
        let focusedWindowNumber = recordRecentITermInteractions()

        // Clear input timestamps for windows that are no longer focused —
        // overlay should reappear quickly after switching away.
        if let focusedWindowNumber {
            for wn in iTermInputTimestamps.keys where wn != focusedWindowNumber {
                iTermInputTimestamps.removeValue(forKey: wn)
            }
        }


        var trackedWindows: [ITermActivityOverlayController.TrackedWindow] = []
        for snapshot in inventory.visible + inventory.hidden {
            let profileID = iTermActivityProfileCache[snapshot.key] ?? ""
            let isClaudeOrCodex = profileID.hasPrefix("claude-code") || profileID.hasPrefix("codex")
            guard isClaudeOrCodex,
                  let frameSnapshot = snapshot.frame else {
                continue
            }
            let topLeftFrame = CGRect(
                x: frameSnapshot.x,
                y: frameSnapshot.y,
                width: frameSnapshot.width,
                height: frameSnapshot.height
            )
            guard let cocoaFrame = moveEverythingRuntimeRect(fromTopLeftRect: topLeftFrame) else {
                continue
            }
            let isActive = iTermActivityCache[snapshot.key] == "active"
            let hasRecentKeystroke = snapshot.windowNumber.flatMap { iTermInputTimestamps[$0] }.map { $0 > inputCutoff } ?? false
            let hasRecentMouseInput = snapshot.windowNumber.flatMap { iTermInputTimestamps[$0] }.map { $0 > inputCutoff } ?? false
            trackedWindows.append(ITermActivityOverlayController.TrackedWindow(
                key: snapshot.key,
                frame: cocoaFrame,
                isActive: isActive,
                hasRecentUserInput: hasRecentKeystroke || hasRecentMouseInput,
                windowNumber: snapshot.windowNumber,
                overlayOpacity: config.settings.moveEverythingITermActivityOverlayOpacity,
                activeHoldDuration: config.settings.moveEverythingITermActivityHoldSeconds
            ))
        }
        iTermActivityOverlayController.update(windows: trackedWindows)
    }

    /// Returns true if the snapshot has a VibeGrid name override (user renamed it).
    private func hasITermNameOverride(for snapshot: MoveEverythingWindowSnapshot) -> Bool {
        if let runtimeID = iTermRuntimeWindowIDBySnapshotKey[snapshot.key],
           let override = moveEverythingITermWindowOverridesByID[runtimeID],
           !override.title.isEmpty {
            return true
        }
        if let windowNumber = snapshot.windowNumber,
           let override = moveEverythingITermWindowOverridesByNumber[windowNumber],
           !override.title.isEmpty {
            return true
        }
        return false
    }

    /// Drives iTerm background-tint and tab-color indicators via the Python API.
    /// Called on each poll cycle. Queues commands for the next poll round-trip.
    /// Restores original colors when the user is actively interacting (same
    /// suppression logic as the overlay: recent user input hides the indicator).
    private func refreshITermActivityIndicators(inventory: MoveEverythingWindowInventory) {
        let bgTintEnabled = config.settings.moveEverythingITermActivityBackgroundTintEnabled
        let tabColorEnabled = config.settings.moveEverythingITermActivityTabColorEnabled

        guard bgTintEnabled || tabColorEnabled else {
            if !iTermCurrentBgTintStatus.isEmpty || !iTermCurrentTabColorStatus.isEmpty {
                queueRestoreAllITermColors()
            }
            return
        }

        let activeRGBDark = Self.parseHexColor(config.settings.moveEverythingITermRecentActivityActiveColor) ?? (r: 47, g: 143, b: 78)
        let idleRGBDark = Self.parseHexColor(config.settings.moveEverythingITermRecentActivityIdleColor) ?? (r: 186, g: 77, b: 77)
        let activeRGBLight = Self.parseHexColor(config.settings.moveEverythingITermRecentActivityActiveColorLight) ?? (r: 26, g: 117, b: 53)
        let idleRGBLight = Self.parseHexColor(config.settings.moveEverythingITermRecentActivityIdleColorLight) ?? (r: 160, g: 48, b: 48)

        let inputCutoff = Date().addingTimeInterval(-config.settings.moveEverythingITermActivityHoldSeconds)

        var activeWindowIDs = Set<String>()

        for snapshot in inventory.visible + inventory.hidden {
            let profileID = iTermActivityProfileCache[snapshot.key] ?? ""
            let isClaudeOrCodex = profileID.hasPrefix("claude-code") || profileID.hasPrefix("codex")
            guard isClaudeOrCodex,
                  let windowID = iTermRuntimeWindowIDBySnapshotKey[snapshot.key] else {
                continue
            }
            activeWindowIDs.insert(windowID)

            // Suppress tint when user is actively interacting with this iTerm window,
            // unless the persistent setting is enabled (keeps tint visible always).
            let hasRecentInput: Bool
            if config.settings.moveEverythingITermActivityBackgroundTintPersistent {
                hasRecentInput = false
            } else {
                hasRecentInput = snapshot.windowNumber
                    .flatMap { iTermInputTimestamps[$0] }
                    .map { $0 > inputCutoff } ?? false
            }

            let isActive = iTermActivityCache[snapshot.key] == "active"
            let statusKey = hasRecentInput ? "suppressed" : (isActive ? "active" : "idle")

            if bgTintEnabled && iTermCurrentBgTintStatus[windowID] != statusKey {
                if let original = iTermOriginalBackgroundByWindowID[windowID] {
                    if statusKey == "suppressed" {
                        pendingITermColorCommands.append(
                            Self.buildBgColorCommand(windowID: windowID, original: original, tintDark: nil, tintLight: nil)
                        )
                    } else {
                        let tintDark = isActive ? activeRGBDark : idleRGBDark
                        let tintLight = isActive ? activeRGBLight : idleRGBLight
                        pendingITermColorCommands.append(
                            Self.buildBgColorCommand(windowID: windowID, original: original, tintDark: tintDark, tintLight: tintLight, intensity: config.settings.moveEverythingITermActivityTintIntensity)
                        )
                    }
                }
                iTermCurrentBgTintStatus[windowID] = statusKey
            }

            if tabColorEnabled && iTermCurrentTabColorStatus[windowID] != statusKey {
                if statusKey == "suppressed" {
                    pendingITermColorCommands.append([
                        "op": "set_tab_color",
                        "window_id": windowID,
                        "r": 0, "g": 0, "b": 0,
                        "enabled": false,
                    ])
                } else {
                    let tintDark = isActive ? activeRGBDark : idleRGBDark
                    let tintLight = isActive ? activeRGBLight : idleRGBLight
                    var cmd: [String: Any] = [
                        "op": "set_tab_color",
                        "window_id": windowID,
                        "r": tintDark.r, "g": tintDark.g, "b": tintDark.b,
                        "enabled": true,
                    ]
                    cmd["r_light"] = tintLight.r
                    cmd["g_light"] = tintLight.g
                    cmd["b_light"] = tintLight.b
                    pendingITermColorCommands.append(cmd)
                }
                iTermCurrentTabColorStatus[windowID] = statusKey
            }
        }

        // Clean up state for windows no longer tracked
        for windowID in iTermCurrentBgTintStatus.keys where !activeWindowIDs.contains(windowID) {
            if let original = iTermOriginalBackgroundByWindowID[windowID] {
                pendingITermColorCommands.append(
                    Self.buildBgColorCommand(windowID: windowID, original: original, tintDark: nil, tintLight: nil)
                )
            }
            iTermOriginalBackgroundByWindowID.removeValue(forKey: windowID)
        }
        for windowID in iTermCurrentTabColorStatus.keys where !activeWindowIDs.contains(windowID) {
            pendingITermColorCommands.append([
                "op": "set_tab_color",
                "window_id": windowID,
                "r": 0, "g": 0, "b": 0,
                "enabled": false,
            ])
        }
        iTermCurrentBgTintStatus = iTermCurrentBgTintStatus.filter { activeWindowIDs.contains($0.key) }
        iTermCurrentTabColorStatus = iTermCurrentTabColorStatus.filter { activeWindowIDs.contains($0.key) }
        // Prune original background cache for windows no longer in inventory
        let allCurrentWindowIDs = Set(iTermRuntimeWindowIDBySnapshotKey.values)
        for windowID in iTermOriginalBackgroundByWindowID.keys where !allCurrentWindowIDs.contains(windowID) {
            iTermOriginalBackgroundByWindowID.removeValue(forKey: windowID)
        }
        // Persist tinted state for crash recovery
        if iTermOriginalBackgroundByWindowID.isEmpty {
            Self.clearTintedWindowsFile()
        } else {
            saveTintedWindowsFile()
        }
    }

    /// Re-push all known window names to iTerm (e.g., after ALL CAPS toggle changes).
    private func reapplyAllITermWindowNames() {
        let pythonURL = ITermWindowInventoryResolver.pythonURL()
        let allCaps = config.settings.moveEverythingITermTitleAllCaps
        for (windowID, override) in moveEverythingITermWindowOverridesByID {
            guard !override.title.isEmpty else { continue }
            let title = allCaps ? override.title.uppercased() : override.title
            let client = self.iTermActivityWorkerClient
            DispatchQueue.global(qos: .userInitiated).async {
                _ = client.setWindowName(pythonURL: pythonURL, windowID: windowID, name: title)
            }
        }
    }

    /// Queues restore commands for all iTerm windows. Called when indicators are disabled.
    private func queueRestoreAllITermColors() {
        for (windowID, original) in iTermOriginalBackgroundByWindowID {
            pendingITermColorCommands.append(
                Self.buildBgColorCommand(windowID: windowID, original: original, tintDark: nil, tintLight: nil)
            )
        }
        for windowID in iTermCurrentTabColorStatus.keys {
            pendingITermColorCommands.append([
                "op": "set_tab_color",
                "window_id": windowID,
                "r": 0, "g": 0, "b": 0,
                "enabled": false,
            ])
        }
        iTermOriginalBackgroundByWindowID.removeAll()
        iTermCurrentBgTintStatus.removeAll()
        iTermCurrentTabColorStatus.removeAll()
        Self.clearTintedWindowsFile()
    }

    /// Persist tinted window IDs and their original backgrounds so a crash recovery can restore them.
    private func saveTintedWindowsFile() {
        let entries = iTermOriginalBackgroundByWindowID.map { (windowID, bg) -> [String: Any] in
            let entry: [String: Any] = [
                "windowID": windowID,
                "dark_r": bg.dark.r, "dark_g": bg.dark.g, "dark_b": bg.dark.b,
                "light_r": bg.light.r, "light_g": bg.light.g, "light_b": bg.light.b,
                "useSeparateColors": bg.useSeparateColors,
            ]
            return entry
        }
        guard !entries.isEmpty,
              let data = try? JSONSerialization.data(withJSONObject: entries) else {
            Self.clearTintedWindowsFile()
            return
        }
        try? data.write(to: Self.tintedWindowsFileURL)
    }

    private static func clearTintedWindowsFile() {
        try? FileManager.default.removeItem(at: tintedWindowsFileURL)
    }

    /// On startup, restore any iTerm windows left tinted by a previous crash.
    private func restoreTintedWindowsFromPreviousSession() {
        guard let data = try? Data(contentsOf: Self.tintedWindowsFileURL),
              let entries = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return
        }
        for entry in entries {
            guard let windowID = entry["windowID"] as? String else { continue }
            let bg = OriginalBackground(
                dark: (
                    r: (entry["dark_r"] as? Int) ?? 0,
                    g: (entry["dark_g"] as? Int) ?? 0,
                    b: (entry["dark_b"] as? Int) ?? 0
                ),
                light: (
                    r: (entry["light_r"] as? Int) ?? 0,
                    g: (entry["light_g"] as? Int) ?? 0,
                    b: (entry["light_b"] as? Int) ?? 0
                ),
                useSeparateColors: (entry["useSeparateColors"] as? Bool) ?? false
            )
            pendingITermColorCommands.append(
                Self.buildBgColorCommand(windowID: windowID, original: bg, tintDark: nil, tintLight: nil)
            )
            pendingITermColorCommands.append([
                "op": "set_tab_color",
                "window_id": windowID,
                "r": 0, "g": 0, "b": 0,
                "enabled": false,
            ])
        }
        Self.clearTintedWindowsFile()
        if !pendingITermColorCommands.isEmpty {
            WindowListDebugLogger.log("iterm-indicators", "restoring \(pendingITermColorCommands.count) colors from previous crash")
        }
    }

    /// Build a set_background_color command dict. If tintDark/tintLight are nil, restores the original.
    private static func buildBgColorCommand(
        windowID: String,
        original: OriginalBackground,
        tintDark: (r: Int, g: Int, b: Int)?,
        tintLight: (r: Int, g: Int, b: Int)?,
        intensity: Double = 0.25
    ) -> [String: Any] {
        let alpha = min(max(intensity, 0), 1)
        func blend(_ orig: (r: Int, g: Int, b: Int), _ tint: (r: Int, g: Int, b: Int)) -> (r: Int, g: Int, b: Int) {
            (
                r: min(max(Int(Double(orig.r) * (1 - alpha) + Double(tint.r) * alpha), 0), 255),
                g: min(max(Int(Double(orig.g) * (1 - alpha) + Double(tint.g) * alpha), 0), 255),
                b: min(max(Int(Double(orig.b) * (1 - alpha) + Double(tint.b) * alpha), 0), 255)
            )
        }
        let dark = tintDark.map { blend(original.dark, $0) } ?? original.dark
        let light = tintLight.map { blend(original.light, $0) } ?? original.light
        var cmd: [String: Any] = [
            "op": "set_background_color",
            "window_id": windowID,
            "r": dark.r, "g": dark.g, "b": dark.b,
        ]
        if original.useSeparateColors {
            cmd["r_light"] = light.r
            cmd["g_light"] = light.g
            cmd["b_light"] = light.b
        }
        return cmd
    }

    /// Parse "#RRGGBB" hex string to RGB tuple.
    private static func parseHexColor(_ hex: String) -> (r: Int, g: Int, b: Int)? {
        var h = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if h.hasPrefix("#") { h = String(h.dropFirst()) }
        guard h.count == 6, let value = UInt32(h, radix: 16) else { return nil }
        return (
            r: Int((value >> 16) & 0xFF),
            g: Int((value >> 8) & 0xFF),
            b: Int(value & 0xFF)
        )
    }

    /// Checks for recent user input directed at iTerm. Returns the focused
    /// iTerm window number (if iTerm is frontmost), or nil otherwise.
    @discardableResult
    private func recordRecentITermInteractions() -> Int? {
        guard let frontApp = NSWorkspace.shared.frontmostApplication,
              frontApp.localizedName?.lowercased().contains("iterm") == true else {
            return nil
        }

        let frontPID = frontApp.processIdentifier
        guard let infoList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]],
              let frontInfo = infoList.first(where: {
                  ($0[kCGWindowLayer as String] as? Int) == 0 &&
                  ($0[kCGWindowOwnerPID as String] as? pid_t) == frontPID
              }),
              let windowNumber = frontInfo[kCGWindowNumber as String] as? Int else {
            return nil
        }

        let threshold: Double = 0.35
        let clickAge = CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: .leftMouseDown)
        let keyAge = CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: .keyDown)
        let scrollAge = CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: .scrollWheel)
        let hasRecentHIDInput = clickAge < threshold || keyAge < threshold || scrollAge < threshold
        let hasRecentGlobalInput = lastGlobalInputAt.timeIntervalSinceNow > -threshold

        if hasRecentHIDInput || hasRecentGlobalInput {
            iTermInputTimestamps[windowNumber] = Date()
        }

        return windowNumber
    }

    private var isRunningInAppSandbox: Bool {
        !(ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] ?? "").isEmpty
    }

    private func shouldResetAccessibilityPermissionAtStartup() -> Bool {
        let defaults = UserDefaults.standard
        if defaults.bool(forKey: Self.startupAccessibilityResetMarkerKey) {
            return false
        }

        let legacyMarkerKey = startupAccessibilityLegacyResetMarkerKey()
        if !legacyMarkerKey.isEmpty && defaults.bool(forKey: legacyMarkerKey) {
            defaults.set(true, forKey: Self.startupAccessibilityResetMarkerKey)
            defaults.removeObject(forKey: legacyMarkerKey)
            return false
        }

        if !defaults.bool(forKey: Self.startupAccessibilityKnownGrantedMarkerKey) {
            return false
        }

        let expectedFingerprint = defaults.string(
            forKey: Self.startupAccessibilityKnownFingerprintMarkerKey
        ) ?? ""
        if expectedFingerprint.isEmpty {
            return false
        }

        let currentFingerprint = startupAccessibilityExecutableFingerprint()
        if currentFingerprint.isEmpty || currentFingerprint != expectedFingerprint {
            return false
        }

        return true
    }

    private func startupAccessibilityLegacyResetMarkerKey() -> String {
        let bundleIdentifier = Bundle.main.bundleIdentifier ?? "unknown"
        return "\(Self.startupAccessibilityResetMarkerKeyPrefix).\(bundleIdentifier)"
    }

    private func startupAccessibilityExecutableFingerprint() -> String {
        guard let executableURL = Bundle.main.executableURL else {
            return ""
        }

        do {
            let executableData = try Data(contentsOf: executableURL)
            let digest = SHA256.hash(data: executableData)
            return digest.map { String(format: "%02x", $0) }.joined()
        } catch {
            NSLog("VibeGrid: Failed to compute startup accessibility fingerprint: %@", error.localizedDescription)
            return ""
        }
    }
}

private final class LaunchAtLoginService {
    func currentState() -> LaunchAtLoginState {
        guard isRunningAsBundledApp else {
            return LaunchAtLoginState(
                supported: false,
                enabled: false,
                requiresApproval: false,
                message: "Launch at login requires running VibeGrid as a bundled .app."
            )
        }

        guard #available(macOS 13.0, *) else {
            return LaunchAtLoginState(
                supported: false,
                enabled: false,
                requiresApproval: false,
                message: "Launch at login is supported on macOS 13 or newer."
            )
        }

        switch SMAppService.mainApp.status {
        case .enabled:
            return LaunchAtLoginState(
                supported: true,
                enabled: true,
                requiresApproval: false,
                message: "VibeGrid will launch automatically when you log in."
            )
        case .requiresApproval:
            return LaunchAtLoginState(
                supported: true,
                enabled: true,
                requiresApproval: true,
                message: "Login launch is pending approval in System Settings > General > Login Items."
            )
        case .notRegistered:
            return LaunchAtLoginState(
                supported: true,
                enabled: false,
                requiresApproval: false,
                message: "VibeGrid will not launch automatically at login."
            )
        case .notFound:
            return LaunchAtLoginState(
                supported: true,
                enabled: false,
                requiresApproval: false,
                message: "VibeGrid could not be registered for login yet. Move it to /Applications, relaunch, then enable this option."
            )
        @unknown default:
            return LaunchAtLoginState(
                supported: true,
                enabled: false,
                requiresApproval: false,
                message: "Unknown launch-at-login status returned by macOS."
            )
        }
    }

    func setEnabled(_ enabled: Bool) -> LaunchAtLoginUpdateResult {
        let snapshot = currentState()
        guard snapshot.supported else {
            return LaunchAtLoginUpdateResult(state: snapshot, errorMessage: snapshot.message)
        }

        guard #available(macOS 13.0, *) else {
            return LaunchAtLoginUpdateResult(
                state: snapshot,
                errorMessage: "Launch at login is supported on macOS 13 or newer."
            )
        }

        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            return LaunchAtLoginUpdateResult(state: currentState(), errorMessage: nil)
        } catch {
            return LaunchAtLoginUpdateResult(
                state: currentState(),
                errorMessage: "Failed to update launch at login: \(error.localizedDescription)"
            )
        }
    }

    private var isRunningAsBundledApp: Bool {
        Bundle.main.bundlePath.lowercased().hasSuffix(".app")
    }
}

#endif
