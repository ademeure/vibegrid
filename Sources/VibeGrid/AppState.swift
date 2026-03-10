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
    private let launchAtLoginService = LaunchAtLoginService()
    private let placementPreviewOverlay = PlacementPreviewOverlayController()
    private let windowManager: WindowManagerEngineProtocol
    private var moveEverythingAlwaysOnTop = false
    private var moveEverythingMoveToBottom = false
    private var moveEverythingDontMoveVibeGrid = false
    private var moveEverythingShowOverlays = true
    private var moveEverythingModeWasActive = false

    private(set) var config: AppConfig
    private var controlCenter: ControlCenterWindowController?

    init() {
        let initialConfig = configStore.loadOrCreate()
        config = initialConfig
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

    func refresh() {
        let next = configStore.loadOrCreate()
        config = next
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
