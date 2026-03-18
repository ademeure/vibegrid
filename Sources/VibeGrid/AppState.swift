#if os(macOS)
import AppKit
import Foundation
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
    private var quickViewActive = false
    private var quickViewSavedFrame: NSRect?
    private var quickViewWasVisible = false
    private(set) var iTermActivityCache: [String: String] = [:]  // snapshot key → "active"/"idle"
    private(set) var iTermBadgeTextCache: [String: String] = [:]  // snapshot key → badge text
    private var iTermActivityPollInFlight = false
    var iTermTitleTracker: [String: (title: String, changedAt: Date)] = [:]

    private(set) var config: AppConfig
    private var controlCenter: ControlCenterWindowController?

    init() {
        let initialConfig = configStore.loadOrCreate()
        config = initialConfig
        windowListActivityConfigSync.sync(
            settings: initialConfig.settings,
            iTermWindowOverridesByID: moveEverythingITermWindowOverridesByID,
            iTermWindowOverridesByNumber: moveEverythingITermWindowOverridesByNumber
        )
        ITermWindowInventoryResolver.ensurePythonVenv(debugContext: "startup")
        windowManager = Self.makeWindowManager(initialConfig: initialConfig)
        windowManager.isMoveEverythingAlwaysOnTopEnabledProvider = { [weak self] in
            self?.moveEverythingAlwaysOnTop ?? false
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
                self.ensureMoveEverythingMode()
                // Save current visibility and position so we can restore after the editor closes
                let cursor = NSEvent.mouseLocation
                self.windowEditorCursorPosition = cursor
                self.windowEditorWasVisible = self.controlCenter?.window?.isVisible ?? false
                self.windowEditorSavedFrame = self.controlCenter?.window?.frame
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
    }

    private static func makeWindowManager(initialConfig: AppConfig) -> WindowManagerEngineProtocol {
        WindowManagerEngine(initialConfig: initialConfig)
    }
    func openControlCenter() {
        if controlCenter == nil {
            controlCenter = ControlCenterWindowController(appState: self)
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
        guard let cursor = windowEditorCursorPosition else { return }
        // Add modal overlay padding (20px each side)
        let contentSize = NSSize(width: CGFloat(cardWidth) + 40, height: CGFloat(cardHeight) + 40)
        controlCenter?.placeWindowNearCursor(at: cursor, contentSize: contentSize)
    }

    func handleWindowEditorClosed() {
        if !windowEditorWasVisible {
            controlCenter?.window?.orderOut(nil)
        } else if let saved = windowEditorSavedFrame {
            controlCenter?.window?.setFrame(saved, display: false, animate: false)
        }
        windowEditorSavedFrame = nil
        windowEditorWasVisible = false
        windowEditorCursorPosition = nil
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

            // Compute compact narrow size: width ~550px, height capped at 1/4 screen
            let cursor = NSEvent.mouseLocation
            let screen = NSScreen.screens.first(where: { NSMouseInRect(cursor, $0.frame, false) })
                ?? NSScreen.main
                ?? NSScreen.screens.first
            let maxHeight = (screen?.visibleFrame.height ?? 800) / 4
            let contentSize = NSSize(width: 550, height: min(1120, maxHeight * 1.6))

            ensureMoveEverythingMode()
            controlCenter?.placeWindowNearCursor(at: cursor, contentSize: contentSize)
            controlCenter?.showWindow(nil)
            NSApp.activate(ignoringOtherApps: true)
            controlCenter?.window?.makeKeyAndOrderFront(nil)
        }
    }

    func refresh() {
        let next = configStore.loadOrCreate()
        config = next
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
        let raw = configStore.loadRawText()
        if raw.isEmpty {
            return YAMLConfigCodec.encode(config)
        }
        return raw
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

    func moveEverythingHoveredWindowKey() -> String? {
        windowManager.moveEverythingHoveredWindowKey
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

    @discardableResult
    func hideMoveEverythingWindow(withKey key: String) -> Bool {
        windowManager.hideMoveEverythingWindow(withKey: key)
    }

    @discardableResult
    func showHiddenMoveEverythingWindow(withKey key: String) -> Bool {
        windowManager.showHiddenMoveEverythingWindow(withKey: key)
    }

    @discardableResult
    func focusMoveEverythingWindow(
        withKey key: String,
        movePointerToTopMiddle: Bool
    ) -> Bool {
        windowManager.focusMoveEverythingWindow(
            withKey: key,
            movePointerToTopMiddle: movePointerToTopMiddle
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

    // MARK: - iTerm activity (TTY mtime polling)

    /// Kick off a background Python API poll to check TTY mtimes for each iTerm
    /// window. Results are stored in `iTermActivityCache` keyed by snapshot key,
    /// matched via (x, width, height) which is identical across coordinate systems.
    func refreshITermActivity() {
        guard !iTermActivityPollInFlight else { return }
        let pythonURL = ITermWindowInventoryResolver.pythonURL()
        guard FileManager.default.isExecutableFile(atPath: pythonURL.path) else {
            WindowListDebugLogger.log("iterm-activity", "python not found at \(pythonURL.path)")
            return
        }

        iTermActivityPollInFlight = true
        let timeout = config.settings.moveEverythingITermRecentActivityTimeout
        let currentInventory = moveEverythingWindowInventory()

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let activityEntries = Self.pollITermTTYActivity(
                pythonURL: pythonURL,
                timeout: timeout
            )
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.iTermActivityPollInFlight = false

                var newCache: [String: String] = [:]
                var newBadgeCache: [String: String] = [:]
                let desktopHeight = NSScreen.screens.reduce(CGRect.null) { $0.union($1.frame) }.height

                for snapshot in currentInventory.visible + currentInventory.hidden {
                    let appName = snapshot.appName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                    guard appName.contains("iterm"), let sf = snapshot.frame else { continue }
                    let cocoaY = desktopHeight - sf.y - sf.height
                    let matched = activityEntries.first { entry in
                        abs(entry.x - sf.x) <= 4 &&
                        abs(entry.y - cocoaY) <= 4 &&
                        abs(entry.width - sf.width) <= 4 &&
                        abs(entry.height - sf.height) <= 4
                    }
                    if let matched {
                        newCache[snapshot.key] = matched.active ? "active" : "idle"
                        if !matched.badgeText.isEmpty {
                            newBadgeCache[snapshot.key] = matched.badgeText
                        }
                    } else {
                        newCache[snapshot.key] = self.iTermActivityCache[snapshot.key] ?? "idle"
                        if let existingBadge = self.iTermBadgeTextCache[snapshot.key] {
                            newBadgeCache[snapshot.key] = existingBadge
                        }
                    }
                }
                self.iTermActivityCache = newCache
                self.iTermBadgeTextCache = newBadgeCache
                // Trigger a UI refresh so the updated cache is rendered
                self.controlCenter?.refresh()
            }
        }
    }

    private struct ITermActivityEntry {
        let active: Bool
        let x: Double
        let y: Double
        let width: Double
        let height: Double
        let badgeText: String
    }

    private static func pollITermTTYActivity(
        pythonURL: URL,
        timeout: Double
    ) -> [ITermActivityEntry] {
        let process = Process()
        process.executableURL = pythonURL
        process.arguments = [
            "-c",
            """
            import iterm2, os, time, json

            async def main(connection):
                app = await iterm2.async_get_app(connection)
                now = time.time()
                timeout = \(timeout)
                result = []
                for window in app.windows:
                    min_age = 999999.0
                    badge = ""
                    for tab in window.tabs:
                        for session in tab.sessions:
                            try:
                                tty = await session.async_get_variable("tty")
                                if tty:
                                    age = now - os.stat(tty).st_mtime
                                    if age < min_age:
                                        min_age = age
                            except Exception:
                                pass
                    # Read rendered badge text from the current tab's current session
                    try:
                        cur = window.current_tab.current_session
                        bt = await cur.async_get_variable("badge")
                        if isinstance(bt, str) and bt.strip():
                            badge = bt.strip()
                    except Exception:
                        pass
                    f = window.frame
                    result.append({
                        "a": min_age < timeout,
                        "x": f.origin.x,
                        "y": f.origin.y,
                        "w": f.size.width,
                        "h": f.size.height,
                        "b": badge,
                    })
                print(json.dumps(result))

            iterm2.run_until_complete(main, retry=False)
            """
        ]

        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return []
        }

        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            return []
        }

        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        guard let outputText = String(data: outputData, encoding: .utf8),
              let data = outputText.data(using: .utf8),
              let entries = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }

        return entries.compactMap { entry -> ITermActivityEntry? in
            let active = entry["a"] as? Bool ?? false
            let x = (entry["x"] as? NSNumber)?.doubleValue ?? 0
            let y = (entry["y"] as? NSNumber)?.doubleValue ?? 0
            let w = (entry["w"] as? NSNumber)?.doubleValue ?? 0
            let h = (entry["h"] as? NSNumber)?.doubleValue ?? 0
            let badge = (entry["b"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return ITermActivityEntry(active: active, x: x, y: y, width: w, height: h, badgeText: badge)
        }
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
