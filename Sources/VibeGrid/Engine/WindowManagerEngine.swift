#if os(macOS)
import AppKit
import ApplicationServices
import Foundation

final class WindowManagerEngine: WindowManagerEngineProtocol {

    // MARK: - Shared enums

    enum RegisteredHotkeyAction {
        case shortcut(String)
        case moveEverything(MoveEverythingHotkeyAction)
    }

    enum MoveEverythingDirectActionResult {
        case changed
        case noOp
        case failed
    }

    struct MoveEverythingManagedWindow {
        let key: String
        let pid: pid_t
        let windowNumber: Int?
        let title: String?
        let appName: String
        let bundleIdentifier: String?
        let window: AXUIElement
    }

    struct MoveEverythingCoreGraphicsFallbackWindow {
        let key: String
        let pid: pid_t
        let windowNumber: Int
        let title: String?
        let appName: String
        let bundleIdentifier: String?
    }

    struct MoveEverythingCoreGraphicsFallbackCandidate {
        let windowNumber: Int
        let title: String?
    }

    struct MoveEverythingWindowState {
        var originalFrame: CGRect
        var hasVisited: Bool
        var isCentered: Bool
    }

    struct MoveEverythingRunState {
        var windows: [MoveEverythingManagedWindow]
        var currentIndex: Int
        var statesByWindowKey: [String: MoveEverythingWindowState]
        var hiddenWindowRestoreByKey: [String: MoveEverythingHiddenWindowRestore]
    }

    struct MoveEverythingManagedWindowInventory {
        var visible: [MoveEverythingManagedWindow]
        var hidden: [MoveEverythingManagedWindow]
        var hiddenCoreGraphicsFallback: [MoveEverythingCoreGraphicsFallbackWindow]
    }

    struct MoveEverythingHiddenWindowRestore {
        var frame: CGRect
        var state: MoveEverythingWindowState
    }

    // MARK: - Stored properties

    let hotKeyManager: HotKeyManager
    let moveEverythingOverlay = PlacementPreviewOverlayController()
    let moveEverythingBottomOverlay = PlacementPreviewOverlayController()
    let moveEverythingOriginalPositionOverlay = PlacementPreviewOverlayController()

    private(set) var config: AppConfig
    var isMoveEverythingActive = false
    var onMoveEverythingModeChanged: ((Bool) -> Void)?

    var shortcutsByID: [String: ShortcutConfig] = [:]
    var registeredHotkeyActionsByID: [String: RegisteredHotkeyAction] = [:]

    var cycleIndexByShortcut: [String: Int] = [:]
    var displayOffsetByShortcut: [String: Int] = [:]
    var activeDisplayAnchorIndexByShortcut: [String: Int] = [:]
    let shortcutCycleResetTimeout: TimeInterval = 10
    var lastShortcutID: String?
    var lastShortcutPressAt: Date?
    var hotkeysSuspendedForCapture = false

    var moveEverythingRunState: MoveEverythingRunState?
    var moveEverythingOverlaySyncTimer: Timer?
    var moveEverythingBackgroundInventoryTimer: Timer?
    var moveEverythingOverlayLastFrame: CGRect?
    var moveEverythingBottomOverlayLastFrame: CGRect?
    var moveEverythingOriginalPositionOverlayLastFrame: CGRect?
    var moveEverythingHoveredWindowKey: String?
    var moveEverythingShowOverlays = true
    var moveEverythingMoveToBottom = false
    var moveEverythingDontMoveVibeGrid = false
    var moveEverythingNarrowMode = false
    var moveEverythingFallbackStyleHiddenWindowKeys: Set<String> = []
    var moveEverythingLastDirectActionErrorMessage: String?
    var moveEverythingHiddenWindowVisibilitySuppressionByKey: [String: Date] = [:]
    var moveEverythingHoverAdvancedOriginalFrameByWindowKey: [String: CGRect] = [:]
    var moveEverythingIconDataURLByPID: [pid_t: String] = [:]
    var moveEverythingResolvedInventoryCache: MoveEverythingManagedWindowInventory?
    var moveEverythingResolvedInventoryLastRefreshAt: Date?
    let moveEverythingInventoryRefreshQueue = DispatchQueue(
        label: "vibegrid.moveEverything.inventory.refresh",
        qos: .userInitiated
    )
    var moveEverythingInventoryRefreshInFlight = false
    var moveEverythingInventoryRefreshQueued = false
    var moveEverythingInventoryRefreshRevision: UInt64 = 0
    let moveEverythingOverlaySyncInterval: TimeInterval = 0.02
    let moveEverythingFocusedWindowPollingInterval: TimeInterval = 0.125
    let moveEverythingSelectionSyncSuppressionInterval: TimeInterval = 0.2
    let moveEverythingHoverRetentionInterval: TimeInterval = 0.35
    let moveEverythingResolvedInventoryRefreshInterval: TimeInterval = 0.35
    let axMessagingTimeout: Float = 1.0
    let axFocusMessagingTimeout: Float = 0.2
    let moveEverythingAdvancedControlCenterWidth: CGFloat = 1450
    let moveEverythingAdvancedControlCenterHeight: CGFloat = 865
    let moveEverythingNarrowModeMaxSideWidthFraction: CGFloat = 0.4
    var moveEverythingFocusedWindowKey: String?
    var moveEverythingFocusedWindowLastCheckAt: Date?
    var moveEverythingSelectionSyncSuppressedUntil: Date?
    var moveEverythingHoveredWindowLockKey: String?
    var moveEverythingHoveredWindowLockUntil: Date?
    var moveEverythingTemporaryControlCenterTopRestoreWorkItem: DispatchWorkItem?
    let moveEverythingTemporaryControlCenterTopDuration: TimeInterval = 0.42
    var moveEverythingControlCenterFocusedLastKnown = false
    var moveEverythingHoverFocusTransitionDepth = 0
    var hotkeyPassthroughRestoreWorkItem: DispatchWorkItem?
    var firefoxFrameRetryWorkItemsByKey: [String: [DispatchWorkItem]] = [:]
    var onMoveEverythingInventoryRefreshed: (() -> Void)?
    var isMoveEverythingAlwaysOnTopEnabledProvider: (() -> Bool)?

    // MARK: - Init

    init(initialConfig: AppConfig, hotKeyManager: HotKeyManager = .shared) {
        self.config = initialConfig.normalized()
        self.hotKeyManager = hotKeyManager
        self.hotKeyManager.onShortcutPressed = { [weak self] shortcutID in
            DispatchQueue.main.async {
                self?.handleShortcutPress(shortcutID: shortcutID)
            }
        }
        applyConfig(initialConfig)
    }

    deinit {
        hotkeyPassthroughRestoreWorkItem?.cancel()
        firefoxFrameRetryWorkItemsByKey.values.flatMap { $0 }.forEach { $0.cancel() }
        moveEverythingOverlaySyncTimer?.invalidate()
        moveEverythingBackgroundInventoryTimer?.invalidate()
    }

    // MARK: - Configuration

    func applyConfig(_ nextConfig: AppConfig) {
        let normalized = nextConfig.normalized()
        config = normalized
        shortcutsByID = normalized.shortcuts.reduce(into: [String: ShortcutConfig]()) { lookup, shortcut in
            if lookup.updateValue(shortcut, forKey: shortcut.id) != nil {
                NSLog("VibeGrid: duplicate shortcut id '%@' detected after normalization; keeping last definition", shortcut.id)
            }
        }
        cycleIndexByShortcut.removeAll()
        displayOffsetByShortcut.removeAll()
        activeDisplayAnchorIndexByShortcut.removeAll()
        lastShortcutID = nil
        lastShortcutPressAt = nil

        if isMoveEverythingActive,
           (normalized.settings.moveEverythingMoveOnSelection != .miniControlCenterOnTop ||
            !moveEverythingMoveToBottom) {
            restoreAllMoveEverythingAdvancedHoverLayoutsIfNeeded(in: moveEverythingRunState)
        } else if !isMoveEverythingActive {
            moveEverythingHoverAdvancedOriginalFrameByWindowKey.removeAll()
            clearMoveEverythingExternalFocusOverlayState()
        }

        guard !hotkeysSuspendedForCapture else {
            hotKeyManager.setSuspended(true)
            hotKeyManager.unregisterAll()
            return
        }

        hotKeyManager.setSuspended(false)
        registerEnabledHotkeys()
    }

    func requestAccessibility(prompt: Bool) -> Bool {
        if prompt {
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            return AXIsProcessTrustedWithOptions(options)
        }
        return AXIsProcessTrusted()
    }

    func setHotkeysSuspended(_ suspended: Bool) {
        guard suspended != hotkeysSuspendedForCapture else {
            return
        }

        hotkeysSuspendedForCapture = suspended
        hotKeyManager.setSuspended(suspended)

        if suspended {
            hotkeyPassthroughRestoreWorkItem?.cancel()
            hotkeyPassthroughRestoreWorkItem = nil
            hotKeyManager.unregisterAll()
        } else {
            registerEnabledHotkeys()
        }
    }

    // MARK: - Hotkey registration

    func registerEnabledHotkeys() {
        var registrationPayload: [ShortcutConfig] = []
        var actionByHotkeyID: [String: RegisteredHotkeyAction] = [:]
        var reservedSignatures: Set<String> = []

        for action in moveEverythingActionsToRegister() {
            guard let hotkey = normalizedHotkeyForRegistration(config.settings.moveEverythingHotkey(for: action)) else {
                continue
            }
            let signature = hotkeySignature(hotkey)
            guard !signature.isEmpty, !reservedSignatures.contains(signature) else {
                continue
            }

            let hotkeyID = moveEverythingHotkeyID(for: action)
            reservedSignatures.insert(signature)
            registrationPayload.append(
                ShortcutConfig(
                    id: hotkeyID,
                    name: action.displayName,
                    enabled: true,
                    hotkey: hotkey,
                    cycleDisplaysOnWrap: false,
                    placements: []
                )
            )
            actionByHotkeyID[hotkeyID] = .moveEverything(action)
        }

        for shortcut in config.shortcuts where shortcut.enabled {
            let signature = hotkeySignature(shortcut.hotkey)
            if !signature.isEmpty, reservedSignatures.contains(signature) {
                continue
            }
            registrationPayload.append(shortcut)
            actionByHotkeyID[shortcut.id] = .shortcut(shortcut.id)
        }

        registeredHotkeyActionsByID = actionByHotkeyID
        hotKeyManager.register(shortcuts: registrationPayload)
        if isMoveEverythingActive {
            refreshMoveEverythingOverlayPresentation()
        }
    }

    func moveEverythingActionsToRegister() -> [MoveEverythingHotkeyAction] {
        var actions: [MoveEverythingHotkeyAction] = []

        if isMoveEverythingActive || config.settings.moveEverythingCloseHideHotkeysOutsideMode {
            actions.append(.closeWindow)
            actions.append(.hideWindow)
        }

        return actions
    }

    func moveEverythingHotkeyID(for action: MoveEverythingHotkeyAction) -> String {
        "move-everything-\(action.rawValue)"
    }

    func normalizedHotkeyForRegistration(_ hotkey: Hotkey?) -> Hotkey? {
        guard var hotkey else {
            return nil
        }

        hotkey.key = hotkey.key
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !hotkey.key.isEmpty else {
            return nil
        }

        hotkey.modifiers = Array(
            Set(
                hotkey.modifiers.map {
                    $0.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
                }
            )
        )
        .filter { !$0.isEmpty }
        .sorted(by: modifierCompare)

        return hotkey
    }

    func hotkeySignature(_ hotkey: Hotkey?) -> String {
        guard let normalized = normalizedHotkeyForRegistration(hotkey) else {
            return ""
        }
        return "\(normalized.key)|\(normalized.modifiers.joined(separator: "+"))"
    }

    private func modifierCompare(_ left: String, _ right: String) -> Bool {
        let leftIndex = modifierOrder.firstIndex(of: left) ?? Int.max
        let rightIndex = modifierOrder.firstIndex(of: right) ?? Int.max
        if leftIndex == rightIndex {
            return left < right
        }
        return leftIndex < rightIndex
    }

    // MARK: - Perf logging

    func logMoveEverythingPerfIfSlow(
        _ label: String,
        startedAt: UInt64,
        thresholdMs: Double
    ) {
        let elapsedMs = Double(DispatchTime.now().uptimeNanoseconds - startedAt) / 1_000_000
        guard elapsedMs >= thresholdMs else {
            return
        }
        NSLog("VibeGrid perf: %@ took %.1fms", label, elapsedMs)
    }

    private let modifierOrder = ["cmd", "ctrl", "alt", "shift", "fn"]
}

extension CGRect {
    var area: CGFloat {
        if isNull || isEmpty {
            return 0
        }
        return width * height
    }
}

#endif
