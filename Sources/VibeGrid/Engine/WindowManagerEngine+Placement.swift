#if os(macOS)
import AppKit
import ApplicationServices
import Foundation

// MARK: - Placement shortcut handling, screen selection, and preview

extension WindowManagerEngine {

    // MARK: - Shortcut dispatch

    func handleShortcutPress(shortcutID: String) {
        guard requestAccessibility(prompt: false) else {
            NSLog("VibeGrid: accessibility permission is required")
            return
        }

        let action = registeredHotkeyActionsByID[shortcutID] ?? .shortcut(shortcutID)
        switch action {
        case .shortcut(let resolvedShortcutID):
            handlePlacementShortcutPress(shortcutID: resolvedShortcutID)
        case .moveEverything(let moveEverythingAction):
            handleMoveEverythingAction(moveEverythingAction)
        }
    }

    // MARK: - Placement shortcut application

    func handlePlacementShortcutPress(shortcutID: String) {
        guard let shortcut = shortcutsByID[shortcutID], shortcut.enabled, !shortcut.placements.isEmpty else {
            NSLog("VibeGrid: shortcut '%@' has no placements", shortcutID)
            return
        }

        guard let targetPlacement = nextPlacement(for: shortcut) else {
            return
        }

        if shortcut.controlCenterOnly {
            _ = applyPlacementShortcutToControlCenter(
                shortcutID: shortcutID,
                placement: targetPlacement
            )
            return
        }

        let hasHoveredMoveEverythingWindow = moveEverythingHoveredWindowKey != nil
        if isMoveEverythingActive, !hasHoveredMoveEverythingWindow {
            syncMoveEverythingSelectionToFocusedWindowIfNeeded(forceFocusedWindowRefresh: true)
        }

        let ownFocusedWindow = focusedOwnWindowForPlacementShortcut(
            allowControlCenterTarget: !moveEverythingDontMoveVibeGrid
        )
        let shouldTargetControlCenter = ownFocusedWindow.map(isControlCenterWindow) ?? false

        if isMoveEverythingActive,
           moveEverythingDontMoveVibeGrid,
           !hasHoveredMoveEverythingWindow,
           isMoveEverythingControlCenterFocused() {
            NSLog(
                "VibeGrid: skipping shortcut '%@' because Sticky VibeGrid is enabled and Control Center is focused",
                shortcutID
            )
            return
        }

        if isMoveEverythingActive &&
            (!shouldTargetControlCenter || hasHoveredMoveEverythingWindow) {
            let controlCenterFocusedBeforeHotkey = isMoveEverythingControlCenterFocused()
            let hoveredWindowKeyBeforeHotkeyAction = moveEverythingHoveredWindowKey
            let consumedHoveredWindowKey = consumeMoveEverythingHoveredWindowForHotkeyAction()
            let preferredWindowKey = consumedHoveredWindowKey ?? hoveredWindowKeyBeforeHotkeyAction
            if applyPlacementShortcutToMoveEverythingSelection(
                shortcutID: shortcutID,
                placement: targetPlacement,
                preferredWindowKey: preferredWindowKey
            ) {
                if let consumedHoveredWindowKey {
                    moveEverythingHoveredWindowKey = consumedHoveredWindowKey
                    lockMoveEverythingHoveredWindow(consumedHoveredWindowKey)
                }
                if controlCenterFocusedBeforeHotkey, !isMoveEverythingControlCenterFocused() {
                    ensureControlCenterWindowVisibleForMoveEverything()
                }
                return
            }
            return
        }

        let focusedWindowElement = ownFocusedWindow == nil ? focusedWindow() : nil
        if ownFocusedWindow == nil, focusedWindowElement == nil {
            NSLog("VibeGrid: no focused window available")
            return
        }

        let focusedWindowRect = ownFocusedWindow?.frame ?? focusedWindowElement.flatMap { currentWindowRect(for: $0) }
        let displayOffset = displayOffsetByShortcut[shortcutID] ?? 0
        guard let screen = selectScreen(
            for: targetPlacement.display,
            focusedWindowRect: focusedWindowRect,
            displayOffset: displayOffset,
            activeDisplayAnchor: activeDisplayAnchor(for: shortcutID, focusedWindowRect: focusedWindowRect)
        ) else {
            NSLog("VibeGrid: no screen available")
            return
        }

        guard let normalizedRect = targetPlacement.normalizedRect(
            defaultColumns: config.settings.defaultGridColumns,
            defaultRows: config.settings.defaultGridRows
        ) else {
            NSLog("VibeGrid: invalid normalized rect for placement '%@'", targetPlacement.id)
            return
        }

        let isControlCenter = ownFocusedWindow.map(isControlCenterWindow) ?? false
        let targetRect = makeTargetRect(normalizedRect: normalizedRect, on: screen, excludeControlCenter: !isControlCenter)
        let didMove: Bool
        let movementTarget: HotkeyWindowMovementTarget?
        if let ownFocusedWindow {
            didMove = setOwnWindow(ownFocusedWindow, cocoaRect: targetRect)
            movementTarget = hotkeyWindowMovementTarget(for: ownFocusedWindow)
        } else if let focusedWindowElement {
            didMove = setWindow(focusedWindowElement, cocoaRect: targetRect)
            movementTarget = hotkeyWindowMovementTarget(for: focusedWindowElement)
        } else {
            didMove = false
            movementTarget = nil
        }

        if !didMove {
            NSLog("VibeGrid: failed to move focused window for shortcut '%@'", shortcutID)
            return
        }
        if let movementTarget, let focusedWindowRect {
            recordHotkeyWindowMovement(
                target: movementTarget,
                from: focusedWindowRect,
                to: targetRect
            )
        }
    }

    func focusedOwnWindowForPlacementShortcut(allowControlCenterTarget: Bool) -> NSWindow? {
        if allowControlCenterTarget,
           let controlCenterWindow = NSApp.windows.first(where: isControlCenterWindow),
           controlCenterWindow.isVisible,
           !controlCenterWindow.isMiniaturized,
           isOwnWindowFocused(controlCenterWindow) {
            return controlCenterWindow
        }
        if let ownWindow = frontmostOwnWindow() {
            if isControlCenterWindow(ownWindow) {
                guard allowControlCenterTarget, isOwnWindowFocused(ownWindow) else {
                    return nil
                }
            }
            return ownWindow
        }

        return nil
    }

    func isOwnWindowFocused(_ window: NSWindow) -> Bool {
        window.isKeyWindow ||
            window.isMainWindow ||
            NSApp.keyWindow === window ||
            NSApp.mainWindow === window
    }

    @discardableResult
    private func applyPlacementShortcutToControlCenter(
        shortcutID: String,
        placement targetPlacement: PlacementStep
    ) -> Bool {
        guard let controlCenterWindow = NSApp.windows.first(where: isControlCenterWindow) else {
            NSLog("VibeGrid: control center window not found for shortcut '%@'", shortcutID)
            return false
        }

        if controlCenterWindow.isMiniaturized {
            controlCenterWindow.deminiaturize(nil)
        }
        ensureControlCenterWindowVisibleForMoveEverything()

        let referenceFrame = controlCenterWindow.frame
        let displayOffset = displayOffsetByShortcut[shortcutID] ?? 0
        guard let screen = selectScreen(
            for: targetPlacement.display,
            focusedWindowRect: referenceFrame,
            displayOffset: displayOffset,
            activeDisplayAnchor: activeDisplayAnchor(for: shortcutID, focusedWindowRect: referenceFrame)
        ) else {
            NSLog("VibeGrid: no screen available for Control Center target")
            return false
        }

        guard let normalizedRect = targetPlacement.normalizedRect(
            defaultColumns: config.settings.defaultGridColumns,
            defaultRows: config.settings.defaultGridRows
        ) else {
            NSLog("VibeGrid: invalid normalized rect for placement '%@'", targetPlacement.id)
            return false
        }

        let targetRect = makeTargetRect(normalizedRect: normalizedRect, on: screen, excludeControlCenter: false)
        guard setOwnWindow(controlCenterWindow, cocoaRect: targetRect) else {
            NSLog("VibeGrid: failed to move control center window for shortcut '%@'", shortcutID)
            return false
        }

        recordHotkeyWindowMovement(
            target: hotkeyWindowMovementTarget(for: controlCenterWindow),
            from: referenceFrame,
            to: targetRect
        )

        ensureControlCenterWindowVisibleForMoveEverything()
        return true
    }

    @discardableResult
    func applyPlacementShortcutToMoveEverythingSelection(
        shortcutID: String,
        placement targetPlacement: PlacementStep,
        preferredWindowKey: String? = nil
    ) -> Bool {
        guard isMoveEverythingActive else {
            return false
        }

        let normalizedPreferredWindowKey = preferredWindowKey?.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalizedPreferredWindowKey?.isEmpty == false {
            requestMoveEverythingInventoryRefreshIfNeeded(force: false)
        } else {
            pruneMoveEverythingWindows()
        }

        guard var runState = moveEverythingRunState, !runState.windows.isEmpty else {
            return false
        }

        let targetIndex: Int
        if let normalizedPreferredWindowKey,
           !normalizedPreferredWindowKey.isEmpty {
            guard let preferredIndex = runState.windows.firstIndex(where: { managedWindow in
                managedWindow.key == normalizedPreferredWindowKey &&
                    !isMoveEverythingControlCenterWindow(managedWindow)
            }) else {
                NSLog(
                    "VibeGrid: hovered target key '%@' was not found for shortcut '%@'; skipping move",
                    normalizedPreferredWindowKey,
                    shortcutID
                )
                return true
            }
            targetIndex = preferredIndex
        } else {
            if moveEverythingDontMoveVibeGrid && isMoveEverythingControlCenterFocused() {
                return true
            }

            refreshMoveEverythingFocusedWindowKeyIfNeeded(force: true)
            if let focusedKey = moveEverythingFocusedWindowKey,
               let focusedIndex = runState.windows.firstIndex(where: { managedWindow in
                   managedWindow.key == focusedKey && !isMoveEverythingControlCenterWindow(managedWindow)
               }) {
                targetIndex = focusedIndex
            } else {
                let movableIndices = runState.windows.indices.filter { index in
                    !isMoveEverythingControlCenterWindow(runState.windows[index])
                }
                if movableIndices.count == 1, let onlyMovableIndex = movableIndices.first {
                    targetIndex = onlyMovableIndex
                } else {
                    NSLog(
                        "VibeGrid: unable to resolve an unambiguous Window List target for shortcut '%@'; skipping move",
                        shortcutID
                    )
                    return true
                }
            }
        }

        guard runState.windows.indices.contains(targetIndex) else {
            return false
        }
        runState.currentIndex = targetIndex

        let managedWindow = runState.windows[targetIndex]
        let referenceFrame = currentWindowRect(for: managedWindow.window) ??
            runState.statesByWindowKey[managedWindow.key]?.originalFrame
        let displayOffset = displayOffsetByShortcut[shortcutID] ?? 0
        guard let screen = selectScreen(
            for: targetPlacement.display,
            focusedWindowRect: referenceFrame,
            displayOffset: displayOffset,
            activeDisplayAnchor: activeDisplayAnchor(for: shortcutID, focusedWindowRect: referenceFrame)
        ) else {
            NSLog("VibeGrid: no screen available for Window List target")
            return true
        }

        guard let normalizedRect = targetPlacement.normalizedRect(
            defaultColumns: config.settings.defaultGridColumns,
            defaultRows: config.settings.defaultGridRows
        ) else {
            NSLog("VibeGrid: invalid normalized rect for placement '%@'", targetPlacement.id)
            return true
        }

        let targetRect = makeTargetRect(normalizedRect: normalizedRect, on: screen)
        guard setMoveEverythingWindowFrame(managedWindow, cocoaRect: targetRect) else {
            NSLog("VibeGrid: failed to move selected Window List window for shortcut '%@'", shortcutID)
            return true
        }

        if let referenceFrame {
            recordHotkeyWindowMovement(
                target: hotkeyWindowMovementTarget(for: managedWindow),
                from: referenceFrame,
                to: targetRect
            )
        }

        var state = runState.statesByWindowKey[managedWindow.key] ??
            MoveEverythingWindowState(
                originalFrame: referenceFrame ?? targetRect,
                hasVisited: true,
                isCentered: false
            )
        if state.originalFrame == .zero {
            state.originalFrame = referenceFrame ?? targetRect
        }
        state.hasVisited = true
        state.isCentered = false
        runState.statesByWindowKey[managedWindow.key] = state
        moveEverythingRunState = runState

        clearMoveEverythingExternalFocusOverlayState()
        refreshMoveEverythingOverlayPresentation()
        notifyMoveEverythingModeChanged()
        return true
    }

    // MARK: - MoveEverything action dispatch

    func handleMoveEverythingAction(_ action: MoveEverythingHotkeyAction) {
        if isMoveEverythingActive && (action == .closeWindow || action == .hideWindow) {
            syncMoveEverythingSelectionToFocusedWindowIfNeeded(forceFocusedWindowRefresh: true)
        }

        switch action {
        case .closeWindow:
            if isMoveEverythingActive {
                _ = consumeMoveEverythingHoveredWindowForHotkeyAction()
                closeMoveEverythingCurrentWindow()
            } else {
                _ = closeFocusedWindowOutsideMoveEverythingMode()
            }

        case .hideWindow:
            if isMoveEverythingActive {
                _ = consumeMoveEverythingHoveredWindowForHotkeyAction()
                hideMoveEverythingCurrentWindow()
            } else {
                _ = hideFocusedWindowOutsideMoveEverythingMode()
            }

        case .nameWindow:
            nameWindowFromHotkey()

        case .quickView:
            onMoveEverythingQuickViewRequested?()

        case .undoWindowMovement:
            _ = undoHotkeyWindowMovement()

        case .redoWindowMovement:
            _ = redoHotkeyWindowMovement()
        }
    }

    func hotkeyWindowMovementTarget(for managedWindow: MoveEverythingManagedWindow) -> HotkeyWindowMovementTarget {
        HotkeyWindowMovementTarget(
            pid: managedWindow.pid,
            windowNumber: managedWindow.windowNumber,
            title: moveEverythingWindowTitle(for: managedWindow),
            appName: managedWindow.appName
        )
    }

    func hotkeyWindowMovementTarget(for ownWindow: NSWindow) -> HotkeyWindowMovementTarget {
        HotkeyWindowMovementTarget(
            pid: ProcessInfo.processInfo.processIdentifier,
            windowNumber: ownWindow.windowNumber,
            title: ownWindow.title.trimmingCharacters(in: .whitespacesAndNewlines),
            appName: "VibeGrid"
        )
    }

    func hotkeyWindowMovementTarget(for axWindow: AXUIElement) -> HotkeyWindowMovementTarget? {
        var pid: pid_t = 0
        AXUIElementGetPid(axWindow, &pid)
        guard pid != 0 else {
            return nil
        }

        let title = copyStringAttribute(from: axWindow, attribute: kAXTitleAttribute)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let appName = NSRunningApplication(processIdentifier: pid)?.localizedName?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "PID \(pid)"
        return HotkeyWindowMovementTarget(
            pid: pid,
            windowNumber: resolvedAXWindowNumber(for: axWindow),
            title: title,
            appName: appName
        )
    }

    func recordHotkeyWindowMovement(
        target: HotkeyWindowMovementTarget,
        from fromFrame: CGRect,
        to toFrame: CGRect
    ) {
        guard !moveEverythingFramesApproximatelyEqual(fromFrame, toFrame, tolerance: 1) else {
            return
        }

        hotkeyWindowMovementUndoHistory.append(
            HotkeyWindowMovementRecord(
                target: target,
                fromFrame: fromFrame,
                toFrame: toFrame
            )
        )
        if hotkeyWindowMovementUndoHistory.count > hotkeyWindowMovementHistoryLimit {
            hotkeyWindowMovementUndoHistory.removeFirst(
                hotkeyWindowMovementUndoHistory.count - hotkeyWindowMovementHistoryLimit
            )
        }
        hotkeyWindowMovementRedoHistory.removeAll()
    }

    @discardableResult
    func undoHotkeyWindowMovement() -> Bool {
        guard let record = hotkeyWindowMovementUndoHistory.popLast() else {
            return false
        }
        guard applyHotkeyWindowMovementRecord(record, targetFrame: record.fromFrame) else {
            hotkeyWindowMovementUndoHistory.append(record)
            return false
        }
        hotkeyWindowMovementRedoHistory.append(record)
        if hotkeyWindowMovementRedoHistory.count > hotkeyWindowMovementHistoryLimit {
            hotkeyWindowMovementRedoHistory.removeFirst(
                hotkeyWindowMovementRedoHistory.count - hotkeyWindowMovementHistoryLimit
            )
        }
        return true
    }

    @discardableResult
    func redoHotkeyWindowMovement() -> Bool {
        guard let record = hotkeyWindowMovementRedoHistory.popLast() else {
            return false
        }
        guard applyHotkeyWindowMovementRecord(record, targetFrame: record.toFrame) else {
            hotkeyWindowMovementRedoHistory.append(record)
            return false
        }
        hotkeyWindowMovementUndoHistory.append(record)
        if hotkeyWindowMovementUndoHistory.count > hotkeyWindowMovementHistoryLimit {
            hotkeyWindowMovementUndoHistory.removeFirst(
                hotkeyWindowMovementUndoHistory.count - hotkeyWindowMovementHistoryLimit
            )
        }
        return true
    }

    func applyHotkeyWindowMovementRecord(
        _ record: HotkeyWindowMovementRecord,
        targetFrame: CGRect
    ) -> Bool {
        guard let resolvedTarget = resolveHotkeyWindowMovementTarget(
            record.target,
            expectedCurrentFrame: targetFrame == record.fromFrame ? record.toFrame : record.fromFrame
        ) else {
            return false
        }

        switch resolvedTarget {
        case .own(let ownWindow):
            return setOwnWindow(ownWindow, cocoaRect: targetFrame)
        case .managed(let managedWindow):
            guard setMoveEverythingWindowFrame(managedWindow, cocoaRect: targetFrame) else {
                return false
            }
            syncMoveEverythingRunStateAfterHotkeyMovement(managedWindow, targetFrame: targetFrame)
            return true
        }
    }

    func syncMoveEverythingRunStateAfterHotkeyMovement(
        _ managedWindow: MoveEverythingManagedWindow,
        targetFrame: CGRect
    ) {
        guard var runState = moveEverythingRunState,
              let windowIndex = runState.windows.firstIndex(where: { $0.key == managedWindow.key }) else {
            return
        }

        runState.windows[windowIndex] = managedWindow
        var state = runState.statesByWindowKey[managedWindow.key] ??
            MoveEverythingWindowState(
                originalFrame: targetFrame,
                hasVisited: true,
                isCentered: false
            )
        if state.originalFrame == .zero {
            state.originalFrame = targetFrame
        }
        state.hasVisited = true
        state.isCentered = false
        runState.statesByWindowKey[managedWindow.key] = state
        moveEverythingRunState = runState
        clearMoveEverythingExternalFocusOverlayState()
        refreshMoveEverythingOverlayPresentation()
        notifyMoveEverythingModeChanged()
    }

    func resolveHotkeyWindowMovementTarget(
        _ target: HotkeyWindowMovementTarget,
        expectedCurrentFrame: CGRect?
    ) -> ResolvedHotkeyWindowMovementTarget? {
        if target.pid == ProcessInfo.processInfo.processIdentifier {
            if let windowNumber = target.windowNumber,
               let window = NSApp.windows.first(where: { $0.windowNumber == windowNumber }) {
                return .own(window)
            }
            let normalizedTitle = target.title.trimmingCharacters(in: .whitespacesAndNewlines)
            if !normalizedTitle.isEmpty,
               let window = NSApp.windows.first(where: {
                   $0.title.trimmingCharacters(in: .whitespacesAndNewlines) == normalizedTitle
               }) {
                return .own(window)
            }
            return nil
        }

        let inventory = resolveMoveEverythingWindowInventory(forceRefresh: true)
        let candidates = (inventory.visible + inventory.hidden).filter { $0.pid == target.pid }
        guard !candidates.isEmpty else {
            return nil
        }

        if let windowNumber = target.windowNumber,
           let exact = candidates.first(where: { $0.windowNumber == windowNumber }) {
            return .managed(exact)
        }

        let normalizedTitle = target.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !normalizedTitle.isEmpty {
            let titleMatches = candidates.filter {
                moveEverythingWindowTitle(for: $0).trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == normalizedTitle
            }
            if titleMatches.count == 1, let exactTitleMatch = titleMatches.first {
                return .managed(exactTitleMatch)
            }
            if let expectedCurrentFrame, !titleMatches.isEmpty,
               let nearestTitleMatch = nearestHotkeyWindowMovementCandidate(
                   from: titleMatches,
                   expectedCurrentFrame: expectedCurrentFrame
               ) {
                return .managed(nearestTitleMatch)
            }
        }

        if let expectedCurrentFrame,
           let nearest = nearestHotkeyWindowMovementCandidate(
               from: candidates,
               expectedCurrentFrame: expectedCurrentFrame
           ) {
            return .managed(nearest)
        }

        if candidates.count == 1, let onlyCandidate = candidates.first {
            return .managed(onlyCandidate)
        }

        return nil
    }

    func nearestHotkeyWindowMovementCandidate(
        from candidates: [MoveEverythingManagedWindow],
        expectedCurrentFrame: CGRect
    ) -> MoveEverythingManagedWindow? {
        candidates.min { left, right in
            let leftDistance = hotkeyWindowMovementDistance(
                currentWindowRect(for: left.window),
                expected: expectedCurrentFrame
            )
            let rightDistance = hotkeyWindowMovementDistance(
                currentWindowRect(for: right.window),
                expected: expectedCurrentFrame
            )
            if leftDistance == rightDistance {
                return left.key < right.key
            }
            return leftDistance < rightDistance
        }
    }

    func hotkeyWindowMovementDistance(_ rect: CGRect?, expected: CGRect) -> CGFloat {
        guard let rect else {
            return .greatestFiniteMagnitude
        }
        return abs(rect.minX - expected.minX) +
            abs(rect.minY - expected.minY) +
            abs(rect.width - expected.width) +
            abs(rect.height - expected.height)
    }

    func nameWindowFromHotkey() {
        if isMoveEverythingActive,
           let hoveredKey = moveEverythingHoveredWindowKey,
           isMoveEverythingControlCenterFocused() {
            onMoveEverythingNameWindowRequested?(hoveredKey)
            return
        }

        let currentRunState = moveEverythingRunState
        let currentSelectionKey: String? = {
            guard let currentRunState,
                  currentRunState.windows.indices.contains(currentRunState.currentIndex) else {
                return nil
            }
            return currentRunState.windows[currentRunState.currentIndex].key
        }()

        let focusedAXWindow = focusedWindow()
        if isMoveEverythingActive,
           let focusedAXWindow,
           let currentRunState,
           let matchedKey = moveEverythingMatchingWindowKey(
                forFocusedAXWindow: focusedAXWindow,
                among: currentRunState.windows
           ) {
            onMoveEverythingNameWindowRequested?(matchedKey)
            return
        }

        if isMoveEverythingActive,
           let focusedAXWindow {
            var focusedPID: pid_t = 0
            AXUIElementGetPid(focusedAXWindow, &focusedPID)
            if focusedPID == ProcessInfo.processInfo.processIdentifier,
               let currentSelectionKey {
                onMoveEverythingNameWindowRequested?(currentSelectionKey)
                return
            }
        } else if let currentSelectionKey {
            onMoveEverythingNameWindowRequested?(currentSelectionKey)
            return
        }

        guard let focusedAXWindow else {
            return
        }

        let inventory = resolveMoveEverythingWindowInventory(forceRefresh: true)
        let allWindows = inventory.visible + inventory.hidden
        guard let matchedKey = moveEverythingMatchingWindowKey(
            forFocusedAXWindow: focusedAXWindow,
            among: allWindows
        ) else {
            return
        }

        onMoveEverythingNameWindowRequested?(matchedKey)
    }

    // MARK: - Placement cycling

    func nextPlacement(for shortcut: ShortcutConfig) -> PlacementStep? {
        guard !shortcut.placements.isEmpty else {
            return nil
        }

        let count = shortcut.placements.count
        let shortcutID = shortcut.id
        let now = Date()
        let didTimeout = lastShortcutPressAt.map {
            now.timeIntervalSince($0) >= shortcutCycleResetTimeout
        } ?? false
        let isFreshCycle = lastShortcutID != shortcutID || didTimeout

        if isFreshCycle {
            cycleIndexByShortcut[shortcutID] = 0
            displayOffsetByShortcut[shortcutID] = 0
            activeDisplayAnchorIndexByShortcut[shortcutID] = nil
        }

        let currentIndex = cycleIndexByShortcut[shortcutID] ?? 0
        let wrappedToFirst = !isFreshCycle && currentIndex == 0
        if wrappedToFirst && shortcut.cycleDisplaysOnWrap {
            let screensCount = max(sortedScreens().count, 1)
            let currentOffset = displayOffsetByShortcut[shortcutID] ?? 0
            displayOffsetByShortcut[shortcutID] = (currentOffset + 1) % screensCount
        }

        let nextIndex = (currentIndex + 1) % count
        cycleIndexByShortcut[shortcutID] = nextIndex
        lastShortcutID = shortcutID
        lastShortcutPressAt = now

        return shortcut.placements[currentIndex]
    }

    func registrationIssues() -> [HotKeyRegistrationIssue] {
        let shortcutIDs = Set(shortcutsByID.keys)
        return hotKeyManager.lastRegistrationIssues.filter { shortcutIDs.contains($0.shortcutID) }
    }

    func previewRect(for placement: PlacementStep) -> CGRect? {
        guard let screen = selectScreen(
            for: placement.display,
            focusedWindowRect: nil,
            displayOffset: 0,
            activeDisplayAnchor: nil
        ) else {
            return nil
        }

        guard let normalizedRect = placement.normalizedRect(
            defaultColumns: config.settings.defaultGridColumns,
            defaultRows: config.settings.defaultGridRows
        ) else {
            return nil
        }

        return makeTargetRect(normalizedRect: normalizedRect, on: screen)
    }

    // MARK: - Screen selection and target rect

    func selectScreen(
        for target: DisplayTarget,
        focusedWindowRect: CGRect?,
        displayOffset: Int,
        activeDisplayAnchor: NSScreen?
    ) -> NSScreen? {
        let screens = sortedScreens()
        guard !screens.isEmpty else { return nil }

        let baseScreen: NSScreen?
        switch target {
        case .active:
            baseScreen = activeDisplayAnchor ??
                (focusedWindowRect.flatMap(screenIntersecting(rect:)) ??
                 screenContaining(point: NSEvent.mouseLocation) ??
                 NSScreen.main ??
                 screens.first)
        case .main:
            baseScreen = NSScreen.main ?? screens.first
        case .index(let index):
            if index >= 0, index < screens.count {
                baseScreen = screens[index]
            } else {
                baseScreen = screens.first
            }
        }

        guard let baseScreen else { return nil }
        return screenByOffset(baseScreen: baseScreen, offset: displayOffset, in: screens)
    }

    func makeTargetRect(normalizedRect: CGRect, on screen: NSScreen, excludeControlCenter: Bool = true) -> CGRect {
        let width = min(max(normalizedRect.size.width, 0.05), 1)
        let height = min(max(normalizedRect.size.height, 0.05), 1)
        let clamped = CGRect(
            x: min(max(normalizedRect.origin.x, 0), 1 - width),
            y: min(max(normalizedRect.origin.y, 0), 1 - height),
            width: width,
            height: height
        )

        var available = screen.visibleFrame
        if excludeControlCenter, isMoveEverythingActive, config.settings.moveEverythingExcludeControlCenter {
            let controlCenterFrame = currentControlCenterFrameForMoveEverything()
            available = MoveEverythingRetileLayout.availableFrame(
                within: available,
                excluding: controlCenterFrame
            )
        }
        var target = CGRect(
            x: available.minX + (clamped.origin.x * available.width),
            // UI coordinates are top-left based, convert to Cocoa's bottom-left system.
            y: available.minY + ((1 - clamped.origin.y - clamped.size.height) * available.height),
            width: clamped.size.width * available.width,
            height: clamped.size.height * available.height
        )

        let gap = CGFloat(max(config.settings.gap, 0))
        if gap > 0 {
            target = target.insetBy(dx: min(gap / 2, target.width * 0.45), dy: min(gap / 2, target.height * 0.45))
        }

        let minWidth: CGFloat = 140
        let minHeight: CGFloat = 110
        target.size.width = max(target.size.width, minWidth)
        target.size.height = max(target.size.height, minHeight)

        if target.maxX > available.maxX {
            target.origin.x = available.maxX - target.width
        }
        if target.maxY > available.maxY {
            target.origin.y = available.maxY - target.height
        }
        if target.minX < available.minX {
            target.origin.x = available.minX
        }
        if target.minY < available.minY {
            target.origin.y = available.minY
        }

        return target.integral
    }

    // MARK: - Display anchor

    func activeDisplayAnchor(for shortcutID: String, focusedWindowRect: CGRect?) -> NSScreen? {
        let screens = sortedScreens()
        guard !screens.isEmpty else {
            return nil
        }

        if let anchoredIndex = activeDisplayAnchorIndexByShortcut[shortcutID],
           anchoredIndex >= 0,
           anchoredIndex < screens.count {
            return screens[anchoredIndex]
        }

        let anchor = focusedWindowRect.flatMap(screenIntersecting(rect:)) ??
            screenContaining(point: NSEvent.mouseLocation) ??
            NSScreen.main ??
            screens.first
        if let anchor, let index = screens.firstIndex(of: anchor) {
            activeDisplayAnchorIndexByShortcut[shortcutID] = index
        }
        return anchor
    }
}

#endif
