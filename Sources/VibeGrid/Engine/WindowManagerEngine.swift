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
        let iTermWindowID: String?
        let iTermWindowName: String?
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

    struct MoveEverythingRetileUndoWindowState {
        let originalFrame: CGRect
        let retiledFrame: CGRect
        let targetFrame: CGRect
    }

    struct MoveEverythingRetileUndoRecord {
        var windowStatesByKey: [String: MoveEverythingRetileUndoWindowState]
        var orderedWindowKeys: [String]
    }

    struct MoveEverythingSavedWindowPositionMatch {
        let saved: MoveEverythingSavedWindowPosition
        let managedWindow: MoveEverythingManagedWindow
    }

    struct HotkeyWindowMovementTarget {
        let pid: pid_t
        let windowNumber: Int?
        let title: String
        let appName: String
    }

    struct HotkeyWindowMovementRecord {
        let target: HotkeyWindowMovementTarget
        let fromFrame: CGRect
        let toFrame: CGRect
    }

    enum ResolvedHotkeyWindowMovementTarget {
        case own(NSWindow)
        case managed(MoveEverythingManagedWindow)
    }

    // MARK: - Stored properties

    let hotKeyManager: HotKeyManager
    let moveEverythingOverlay = PlacementPreviewOverlayController()
    let moveEverythingBottomOverlay = PlacementPreviewOverlayController()
    let moveEverythingOriginalPositionOverlay = PlacementPreviewOverlayController()

    private(set) var config: AppConfig
    var isMoveEverythingActive = false
    var onMoveEverythingModeChanged: ((Bool) -> Void)?

    /// Side-effect hook called before the default AX close (e.g. async mux session kill).
    /// `force` is true for the deferred kill triggered by smart close after its grace delay,
    /// which should use `mux kill --now` (not undoable).
    var onCloseWindowOverride: ((_ key: String, _ force: Bool) -> Void)?

    /// Resolves the mux/tmux session name associated with a window key *right now*.
    /// Smart close reads this at hide-time and captures the result, so the deferred kill
    /// cannot drift onto a different session if the window's active tab changes during the
    /// grace delay.
    var muxSessionNameForKey: ((_ key: String) -> String?)?

    /// Kills a specific mux session by name, bypassing any window-to-session cache. Used by
    /// smart close's deferred kill with `force: true` so the captured session is the one
    /// that actually gets killed.
    var killMuxSessionByName: ((_ sessionName: String, _ force: Bool) -> Void)?

    /// Pending deferred kills scheduled by smart close. Keyed by window key so a second
    /// close press on the same window cancels the first pending kill (idempotent).
    var pendingSmartCloseWorkItemsByKey: [String: DispatchWorkItem] = [:]

    var iTermLastActiveAtBySnapshotKey: [String: Date] = [:]
    var iTermRepositoryGroupBySnapshotKey: [String: String] = [:]
    var iTermActivityProfileCache: [String: String] = [:]
    var windowLastGenuineFocusAt: [String: Date] = [:]
    var shortcutsByID: [String: ShortcutConfig] = [:]
    var registeredHotkeyActionsByID: [String: RegisteredHotkeyAction] = [:]

    /// Per-(shortcut, target window) cycling state. Keyed by
    /// `shortcutCycleKey(shortcutID:windowKey:)` so each window maintains an
    /// independent cycle position, pending-reset flag, and press timestamp.
    /// Switching windows or firing a different shortcut no longer clobbers
    /// progress on the original (shortcut, window).
    struct ShortcutCycleState {
        var cycleIndex: Int = 0
        var displayOffset: Int = 0
        var activeDisplayAnchorIndex: Int? = nil
        var pendingResetConsumed: Bool = false
        var lastPressAt: Date? = nil
    }
    var shortcutCycleStates: [String: ShortcutCycleState] = [:]

    /// Pre-sequence frame shared across all reset-enabled placement shortcuts
    /// targeting the same window. Captured by the FIRST reset-enabled shortcut
    /// to fire on a fresh window; subsequent shortcuts inherit it instead of
    /// re-capturing their own (intermediate) frame. Cleared when any wrap-reset
    /// is consumed or when the entry goes stale (no reset-enabled press within
    /// `shortcutCycleResetTimeout`).
    struct PreSequenceFrameEntry {
        var frame: CGRect
        var cursorPosition: CGPoint?
        var lastTouchedAt: Date
    }
    var preSequenceFrameByWindowKey: [String: PreSequenceFrameEntry] = [:]
    /// ID of the last placement shortcut that fired. Used to interrupt a
    /// non-memory shortcut's cycle when a different shortcut is pressed in
    /// between, so the sequence 1→2→1 restarts step 1 of shortcut 1 rather
    /// than continuing where it left off. Memory shortcuts
    /// (`resetBeforeFirstStep`) are exempt — their state is preserved across
    /// other presses so the eventual reset-to-original still works.
    var lastFiredPlacementShortcutID: String?
    let shortcutCycleResetTimeout: TimeInterval = 10
    /// How long an unused (shortcut, window) entry is retained before pruning.
    /// Bounds memory when users repeatedly press shortcuts across many windows.
    let shortcutCycleStatePruneThreshold: TimeInterval = 3600
    var hotkeysSuspendedForCapture = false

    var moveEverythingRunState: MoveEverythingRunState?
    var moveEverythingOverlaySyncTimer: Timer?
    var moveEverythingBackgroundInventoryTimer: Timer?
    var moveEverythingOverlayLastFrame: CGRect?
    var moveEverythingBottomOverlayLastFrame: CGRect?
    var moveEverythingOriginalPositionOverlayLastFrame: CGRect?
    var moveEverythingHoveredWindowKey: String?
    var moveEverythingHoverElevatedWindows: [(windowNumber: Int, originalLevel: Int32)] = []
    var moveEverythingHoverOriginalLevelByWindowNumber: [Int: Int32] = [:]
    var moveEverythingResolvedWindowNumberByKey: [String: Int] = [:]
    /// Caches the iTerm window descriptor by CG window number so that hotkey
    /// moves (which change the frame) don't cause the frame-based iTerm
    /// resolver to match the wrong session.
    var moveEverythingITermDescriptorByWindowNumber: [Int: ITermWindowInventoryResolver.WindowDescriptor] = [:]
    var moveEverythingFocusedKeyBeforeHover: String?
    var moveEverythingShowOverlays = true
    var moveEverythingMoveToBottom = false
    var moveEverythingMoveToCenter = false
    var moveEverythingDontMoveVibeGrid = false
    var moveEverythingPinnedWindowKeys: Set<String> = []
    var moveEverythingPinMode = false
    var moveEverythingPinnedOverlaysByKey: [String: PlacementPreviewOverlayController] = [:]
    var moveEverythingNarrowMode = false
    var moveEverythingFallbackStyleHiddenWindowKeys: Set<String> = []
    var moveEverythingLastDirectActionErrorMessage: String?
    var moveEverythingHiddenWindowVisibilitySuppressionByKey: [String: Date] = [:]
    var moveEverythingPendingHideVisibleSuppressionByKey: [String: Date] = [:]
    var moveEverythingLastRetileUndoRecord: MoveEverythingRetileUndoRecord?
    var moveEverythingSavedWindowPositionSnapshots: [MoveEverythingSavedWindowPositionsSnapshot] = []
    var moveEverythingSavedWindowPositionSelectedIndex: Int?
    var hotkeyWindowMovementUndoHistory: [HotkeyWindowMovementRecord] = []
    var hotkeyWindowMovementRedoHistory: [HotkeyWindowMovementRecord] = []

    /// Per-window movement timeline storage. Keyed by `"{pid}:{windowNumber}"`
    /// so VibeGrid moves and MoveEverything inventory polling samples land on
    /// the same timeline. Separate from `hotkeyWindowMovement{Undo,Redo}History`
    /// (the global stack) — both systems run alongside each other.
    var perWindowMovementTimelinesByKey: [String: PerWindowMovementTimeline] = [:]
    var moveEverythingHoverAdvancedOriginalFrameByWindowKey: [String: CGRect] = [:]
    var moveEverythingIconDataURLByPID: [pid_t: String] = [:]
    var moveEverythingResolvedInventoryCache: MoveEverythingManagedWindowInventory?
    var moveEverythingResolvedInventoryLastRefreshAt: Date?
    let moveEverythingInventoryRefreshQueue = DispatchQueue(
        label: "vibegrid.moveEverything.inventory.refresh",
        qos: .userInitiated
    )
    var moveEverythingITermFetchCache: [ITermWindowInventoryResolver.WindowDescriptor] = []
    var moveEverythingITermFetchCacheAt: Date?
    let moveEverythingITermFetchCacheTTL: TimeInterval = 2.0
    var moveEverythingInventoryRefreshInFlight = false
    var moveEverythingInventoryRefreshQueued = false
    var moveEverythingInventoryRefreshRevision: UInt64 = 0
    // Overlay sync runs at 30 Hz while move-everything is active. Was 50 Hz
    // (0.02), but at 30 Hz the overlay still tracks window drags smoothly
    // and we save ~40% of the timer wake-ups.
    let moveEverythingOverlaySyncInterval: TimeInterval = 0.033
    // Halved from 0.125 (8 Hz) → 0.0625 (16 Hz). Only runs while move-
    // everything mode is active, so this trades a small extra AX-call
    // burst during drag for sharper focus tracking.
    let moveEverythingFocusedWindowPollingInterval: TimeInterval = 0.0625
    let moveEverythingSelectionSyncSuppressionInterval: TimeInterval = 0.2
    let moveEverythingHoverRetentionInterval: TimeInterval = 0.35
    let moveEverythingResolvedInventoryRefreshInterval: TimeInterval = 0.35
    let moveEverythingRetileUndoPositionTolerance: CGFloat = 14
    let moveEverythingRetileUndoCaptureTimeout: TimeInterval = 0.18
    let moveEverythingRetileUndoRestoreTimeout: TimeInterval = 0.45
    let moveEverythingSavedPositionRestoreTimeout: TimeInterval = 0.12
    let moveEverythingSavedPositionRestoreSettleDelay: TimeInterval = 0.06
    let moveEverythingSavedWindowPositionHistoryLimit = 20
    let hotkeyWindowMovementHistoryLimit = 100
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

    // MARK: - Proxy-hover state

    struct ProxyHoverEntry {
        let gatingFocusPid: pid_t
        let gatingFocusWindowNumber: Int?
        let gatingFocusITermWindowID: String?
        let targetPid: pid_t?
        let targetWindowNumber: Int?
        let targetITermWindowID: String?
        let targetITermTTY: String?
        let expiresAt: Date
    }

    var proxyHoverEntriesByGatingPid: [pid_t: ProxyHoverEntry] = [:]
    var proxyHoverActiveGatingPid: pid_t?
    var proxyHoverActiveWindowKey: String?
    var proxyHoverStartedMoveEverythingMode = false
    var proxyHoverEvaluationTimer: Timer?
    var proxyHoverFrontmostObserver: NSObjectProtocol?
    // Halved from 0.5 → 0.25. The eval is a single dict lookup + frontmost-
    // app check; with the proxy-hover entry duration now at 1s, evaluating
    // 4×/s means a hover gets re-decided right around the time it would
    // expire if no follow-up POST arrives. NSWorkspace.didActivateApplication
    // already fires immediate evals on app focus changes — this timer is
    // the safety net.
    let proxyHoverEvaluationInterval: TimeInterval = 0.25
    var proxyHoverITermTTYCache: Any?
    /// Last time each pid was observed as the frontmost application. Used by
    /// proxy-hover gating to tolerate brief focus blips (e.g. when our own
    /// hover overlay momentarily steals focus from the gating app, which
    /// would otherwise cause the hover to release and re-apply on a flicker
    /// loop).
    var proxyHoverLastFrontmostByPid: [pid_t: Date] = [:]
    /// How long after losing frontmost status a pid is still treated as
    /// "frontmost enough" for proxy-hover gating purposes.
    let proxyHoverFrontmostGraceInterval: TimeInterval = 1.0
    /// Set true while proxy-hover is applying its hover state. Read by
    /// hover-pulse code to skip focus-stealing operations (e.g. activating
    /// VibeGrid for Control Center input) — the gating app must keep focus
    /// or proxy-hover release-flickers the moment we apply.
    var proxyHoverSuppressFocusEffects: Bool = false
    var hotkeyPassthroughRestoreWorkItem: DispatchWorkItem?
    var firefoxFrameRetryWorkItemsByKey: [String: [DispatchWorkItem]] = [:]
    var onMoveEverythingInventoryRefreshed: (() -> Void)?
    var onMoveEverythingNameWindowRequested: ((String) -> Void)?
    var onMoveEverythingQuickViewRequested: (() -> Void)?
    var onRetileHotkeyFired: ((_ action: MoveEverythingHotkeyAction) -> Void)?
    var onMoveEverythingSavedWindowPositionsHistoryChanged: (([MoveEverythingSavedWindowPositionsSnapshot]) -> Void)?
    var isMoveEverythingAlwaysOnTopEnabledProvider: (() -> Bool)?
    var cachedDesktopFrame: CGRect?
    var cachedDesktopFrameScreenCount: Int = 0

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
        proxyHoverEvaluationTimer?.invalidate()
        if let observer = proxyHoverFrontmostObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
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
        shortcutCycleStates.removeAll()
        lastFiredPlacementShortcutID = nil

        if isMoveEverythingActive,
           (normalized.settings.moveEverythingMoveOnSelection != .miniControlCenterOnTop ||
            (!moveEverythingMoveToBottom && !moveEverythingMoveToCenter)) {
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

        actions.append(.nameWindow)
        actions.append(.quickView)
        actions.append(.undoWindowMovement)
        actions.append(.redoWindowMovement)
        actions.append(.undoWindowMovementForFocusedWindow)
        actions.append(.redoWindowMovementForFocusedWindow)
        actions.append(.showAllHiddenWindows)
        actions.append(.retile1)
        actions.append(.retile2)
        actions.append(.retile3)

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
