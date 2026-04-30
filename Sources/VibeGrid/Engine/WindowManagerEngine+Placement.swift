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

        let targetWindowKey = resolvePlacementShortcutTargetWindowKey(for: shortcut)
        let cycleKey = shortcutCycleKey(shortcutID: shortcutID, windowKey: targetWindowKey)

        guard let action = nextShortcutAction(for: shortcut, targetWindowKey: targetWindowKey) else {
            return
        }

        let targetPlacement: PlacementStep
        let shouldCapturePreFirstStepFrame: Bool
        let isResetAction: Bool
        switch action {
        case .placement(let step, let capture):
            targetPlacement = step
            shouldCapturePreFirstStepFrame = capture
            isResetAction = false
        case .reset:
            guard shortcutPreFirstStepFrame(cycleKey: cycleKey) != nil else {
                return
            }
            targetPlacement = shortcut.placements[0]
            shouldCapturePreFirstStepFrame = false
            isResetAction = true
        }

        let hasHoveredMoveEverythingWindow = moveEverythingHoveredWindowKey != nil
        if isMoveEverythingActive, !hasHoveredMoveEverythingWindow {
            syncMoveEverythingSelectionToFocusedWindowIfNeeded(forceFocusedWindowRefresh: true)
        }

        let controlCenterStickyActive = config.settings.controlCenterSticky || moveEverythingDontMoveVibeGrid
        let canMoveCC = shortcut.canMoveControlCenter || !controlCenterStickyActive
        let ownFocusedWindow = focusedOwnWindowForPlacementShortcut(allowControlCenterTarget: canMoveCC)
        let shouldTargetControlCenter = ownFocusedWindow.map(isControlCenterWindow) ?? false

        // When sticky is on and the CC is the focused window (either by our own-window check, or via the
        // MoveEverything-mode focus probe), skip the shortcut entirely unless it opts in via canMoveControlCenter.
        let controlCenterFocused: Bool = {
            if isMoveEverythingControlCenterFocused() {
                return true
            }
            if let focused = ownFocusedWindow, isControlCenterWindow(focused) {
                return true
            }
            // `ownFocusedWindow` is nil when allowControlCenterTarget is false and CC is focused;
            // check key window directly as a fallback.
            if let key = NSApp.keyWindow, isControlCenterWindow(key) {
                return true
            }
            return false
        }()

        if !canMoveCC,
           !hasHoveredMoveEverythingWindow,
           controlCenterFocused {
            NSLog(
                "VibeGrid: skipping shortcut '%@' because the control center is sticky and focused",
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
                cycleKey: cycleKey,
                placement: targetPlacement,
                preferredWindowKey: preferredWindowKey,
                capturePreFirstStepFrame: shouldCapturePreFirstStepFrame,
                overrideTargetRect: isResetAction ? shortcutPreFirstStepFrame(cycleKey: cycleKey) : nil
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

        let targetRect: CGRect
        if isResetAction, let captured = shortcutPreFirstStepFrame(cycleKey: cycleKey) {
            targetRect = captured
        } else {
            let displayOffset = shortcutDisplayOffset(cycleKey: cycleKey)
            guard let screen = selectScreen(
                for: targetPlacement.display,
                focusedWindowRect: focusedWindowRect,
                displayOffset: displayOffset,
                activeDisplayAnchor: activeDisplayAnchor(cycleKey: cycleKey, focusedWindowRect: focusedWindowRect)
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
            let excludeCC = !isControlCenter && !shortcut.ignoreExcludePinnedWindows
            targetRect = makeTargetRect(normalizedRect: normalizedRect, on: screen, excludeControlCenter: excludeCC)
        }

        if shouldCapturePreFirstStepFrame, let focusedWindowRect {
            let cursorToStore = shortcut.resetBeforeFirstStepMoveCursor
                ? cursorPositionToCapture()
                : nil
            storeShortcutPreFirstStepFrame(
                cycleKey: cycleKey,
                frame: focusedWindowRect,
                cursorPosition: cursorToStore,
                forceOverwrite: shortcut.resetBeforeFirstStepMoveCursor
            )
        }

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

        if shortcut.resetBeforeFirstStep, shortcut.resetBeforeFirstStepMoveCursor {
            if isResetAction,
               let restoreCursor = shortcutPreFirstStepCursorPosition(cycleKey: cycleKey) {
                warpCursorToCocoaPoint(restoreCursor)
                refocusControlCenterIfCursorIsOverIt(cocoaPoint: restoreCursor)
            } else {
                warpCursorToCocoaPoint(CGPoint(x: targetRect.midX, y: targetRect.midY))
            }
        }

        if isResetAction {
            clearSharedPreSequenceState(cycleKey: cycleKey)
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
        cycleKey: String,
        placement targetPlacement: PlacementStep,
        capturePreFirstStepFrame: Bool = false,
        overrideTargetRect: CGRect? = nil
    ) -> Bool {
        guard let controlCenterWindow = NSApp.windows.first(where: isControlCenterWindow) else {
            NSLog("VibeGrid: control center window not found for shortcut '%@'", shortcutID)
            return false
        }

        if controlCenterWindow.isMiniaturized {
            controlCenterWindow.deminiaturize(nil)
        }
        ensureControlCenterWindowVisibleForMoveEverything()

        let shortcut = shortcutsByID[shortcutID]
        let isResetAction = overrideTargetRect != nil
        let moveCursor = (shortcut?.resetBeforeFirstStep ?? false) &&
            (shortcut?.resetBeforeFirstStepMoveCursor ?? false)

        let referenceFrame = controlCenterWindow.frame
        let targetRect: CGRect
        if let overrideTargetRect {
            targetRect = overrideTargetRect
        } else {
            let displayOffset = shortcutDisplayOffset(cycleKey: cycleKey)
            guard let screen = selectScreen(
                for: targetPlacement.display,
                focusedWindowRect: referenceFrame,
                displayOffset: displayOffset,
                activeDisplayAnchor: activeDisplayAnchor(cycleKey: cycleKey, focusedWindowRect: referenceFrame)
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

            targetRect = makeTargetRect(normalizedRect: normalizedRect, on: screen, excludeControlCenter: false)
        }

        if capturePreFirstStepFrame {
            let cursorToStore = moveCursor
                ? cursorPositionToCapture()
                : nil
            storeShortcutPreFirstStepFrame(
                cycleKey: cycleKey,
                frame: referenceFrame,
                cursorPosition: cursorToStore,
                forceOverwrite: moveCursor
            )
        }

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

        if moveCursor {
            if isResetAction,
               let restoreCursor = shortcutPreFirstStepCursorPosition(cycleKey: cycleKey) {
                warpCursorToCocoaPoint(restoreCursor)
            } else {
                warpCursorToCocoaPoint(CGPoint(x: targetRect.midX, y: targetRect.midY))
            }
        }
        if isResetAction {
            clearSharedPreSequenceState(cycleKey: cycleKey)
        }
        return true
    }

    @discardableResult
    func applyPlacementShortcutToMoveEverythingSelection(
        shortcutID: String,
        cycleKey: String? = nil,
        placement targetPlacement: PlacementStep,
        preferredWindowKey: String? = nil,
        capturePreFirstStepFrame: Bool = false,
        overrideTargetRect: CGRect? = nil
    ) -> Bool {
        let resolvedCycleKey = cycleKey ?? shortcutCycleKey(shortcutID: shortcutID, windowKey: preferredWindowKey.map { "me:\($0)" })
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

        let targetRect: CGRect
        if let overrideTargetRect {
            targetRect = overrideTargetRect
        } else {
            let displayOffset = shortcutDisplayOffset(cycleKey: resolvedCycleKey)
            guard let screen = selectScreen(
                for: targetPlacement.display,
                focusedWindowRect: referenceFrame,
                displayOffset: displayOffset,
                activeDisplayAnchor: activeDisplayAnchor(cycleKey: resolvedCycleKey, focusedWindowRect: referenceFrame)
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

            let ignoreExclude = shortcutsByID[shortcutID]?.ignoreExcludePinnedWindows ?? false
            targetRect = makeTargetRect(normalizedRect: normalizedRect, on: screen, excludeControlCenter: !ignoreExclude)
        }

        let shortcut = shortcutsByID[shortcutID]
        let isResetAction = overrideTargetRect != nil
        let moveCursor = (shortcut?.resetBeforeFirstStep ?? false) &&
            (shortcut?.resetBeforeFirstStepMoveCursor ?? false)

        if capturePreFirstStepFrame, let referenceFrame {
            let cursorToStore = moveCursor
                ? cursorPositionToCapture()
                : nil
            storeShortcutPreFirstStepFrame(
                cycleKey: resolvedCycleKey,
                frame: referenceFrame,
                cursorPosition: cursorToStore,
                forceOverwrite: moveCursor
            )
        }

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

        if moveCursor {
            if isResetAction,
               let restoreCursor = shortcutPreFirstStepCursorPosition(cycleKey: resolvedCycleKey) {
                warpCursorToCocoaPoint(restoreCursor)
            } else {
                warpCursorToCocoaPoint(CGPoint(x: targetRect.midX, y: targetRect.midY))
            }
            if !isMoveEverythingControlCenterWindow(managedWindow) {
                NSRunningApplication(processIdentifier: managedWindow.pid)?
                    .activate(options: [.activateIgnoringOtherApps])
                focusMoveEverythingWindow(managedWindow, allowAppActivation: false)
            }
        }
        if isResetAction {
            clearSharedPreSequenceState(cycleKey: resolvedCycleKey)
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
        if moveEverythingPinMode {
            refreshMoveEverythingPinnedOverlays()
        }
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
                if config.settings.moveEverythingCloseSmart {
                    smartCloseCurrentWindow()
                } else {
                    closeMoveEverythingCurrentWindow()
                }
            } else {
                if config.settings.moveEverythingCloseSmart {
                    smartCloseCurrentWindow()
                } else {
                    _ = closeFocusedWindowOutsideMoveEverythingMode()
                }
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

        case .undoWindowMovementForFocusedWindow:
            _ = undoPerWindowMovementForCurrentTarget()

        case .redoWindowMovementForFocusedWindow:
            _ = redoPerWindowMovementForCurrentTarget()

        case .showAllHiddenWindows:
            _ = showAllHiddenMoveEverythingWindows()

        case .retile1, .retile2, .retile3:
            onRetileHotkeyFired?(action)
        }
    }

    func runRetile(mode: MoveEverythingRetileShortcutMode) -> Bool {
        switch mode {
        case .full:
            return retileVisibleMoveEverythingWindows()
        case .mini:
            return miniRetileVisibleMoveEverythingWindows()
        case .iterm:
            return iTermRetileVisibleMoveEverythingWindows()
        case .nonITerm:
            return nonITermRetileVisibleMoveEverythingWindows()
        case .hybrid:
            return hybridRetileVisibleMoveEverythingWindows()
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

        recordPerWindowMovement(target: target, from: fromFrame, to: toFrame)

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
        if moveEverythingPinMode {
            refreshMoveEverythingPinnedOverlays()
        }
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

    /// Returns a stable identity string for the window that this shortcut will
    /// act on. Used to restart the placement sequence when the user presses the
    /// same hotkey after switching to a different window. Returns `nil` when the
    /// target cannot be determined — in that case the existing sequence is
    /// preserved rather than reset.
    func resolvePlacementShortcutTargetWindowKey(for shortcut: ShortcutConfig) -> String? {
        let hasHoveredMoveEverythingWindow = moveEverythingHoveredWindowKey != nil

        if isMoveEverythingActive {
            if let hoveredKey = moveEverythingHoveredWindowKey {
                return "me:\(hoveredKey)"
            }

            let stickyBlocksCC = (config.settings.controlCenterSticky || moveEverythingDontMoveVibeGrid)
                && !shortcut.canMoveControlCenter
            let ownFocusedWindow = focusedOwnWindowForPlacementShortcut(
                allowControlCenterTarget: !stickyBlocksCC
            )
            let shouldTargetControlCenter = ownFocusedWindow.map(isControlCenterWindow) ?? false
            if !shouldTargetControlCenter || hasHoveredMoveEverythingWindow {
                syncMoveEverythingSelectionToFocusedWindowIfNeeded(forceFocusedWindowRefresh: true)
                if let focusedKey = moveEverythingFocusedWindowKey {
                    return "me:\(focusedKey)"
                }
                return nil
            }
            if let ownFocusedWindow {
                return "own:\(ownFocusedWindow.windowNumber)"
            }
            return nil
        }

        if let ownFocusedWindow = focusedOwnWindowForPlacementShortcut(allowControlCenterTarget: true) {
            return "own:\(ownFocusedWindow.windowNumber)"
        }

        guard let axWindow = focusedWindow() else {
            return nil
        }
        var pid: pid_t = 0
        AXUIElementGetPid(axWindow, &pid)
        if let winNum = resolvedAXWindowNumber(for: axWindow) {
            return "ax:\(pid):\(winNum)"
        }
        return "ax:\(pid)"
    }

    enum NextShortcutAction {
        /// Apply this placement. `capturePreFirstStepFrame` is true when this is step 1 of a
        /// sequence with `resetBeforeFirstStep` enabled — the caller must capture the current
        /// window frame BEFORE applying the placement so the eventual wrap can restore it.
        case placement(PlacementStep, capturePreFirstStepFrame: Bool)
        /// Restore the previously-captured pre-sequence frame instead of applying a step. The
        /// cycle index is not advanced; the next press applies step 1.
        case reset
    }

    /// Stable key for per-(shortcut, window) cycle state. When no window target can be
    /// resolved we fall back to the shortcut ID alone so the sequence still cycles.
    func shortcutCycleKey(shortcutID: String, windowKey: String?) -> String {
        if let windowKey, !windowKey.isEmpty {
            return "\(shortcutID)|\(windowKey)"
        }
        return shortcutID
    }

    func pruneStaleShortcutCycleStates(now: Date = Date()) {
        let threshold = shortcutCycleStatePruneThreshold
        shortcutCycleStates = shortcutCycleStates.filter { _, state in
            guard let ts = state.lastPressAt else { return true }
            return now.timeIntervalSince(ts) < threshold
        }
    }

    func nextShortcutAction(for shortcut: ShortcutConfig, targetWindowKey: String? = nil) -> NextShortcutAction? {
        guard !shortcut.placements.isEmpty else {
            return nil
        }

        let count = shortcut.placements.count
        let cycleKey = shortcutCycleKey(shortcutID: shortcut.id, windowKey: targetWindowKey)
        let now = Date()
        pruneStaleShortcutCycleStates(now: now)
        var state = shortcutCycleStates[cycleKey] ?? ShortcutCycleState()

        let didTimeout = state.lastPressAt.map {
            now.timeIntervalSince($0) >= shortcutCycleResetTimeout
        } ?? false
        // A different placement shortcut firing in between always restarts the
        // cycle at step 1 — so 1→2→1 begins shortcut 1 from the top regardless
        // of whether resetBeforeFirstStep is set. The pre-sequence restore frame
        // is shared per-window and first-write-wins, so it survives the restart.
        let interruptedByOtherShortcut = lastFiredPlacementShortcutID != nil
            && lastFiredPlacementShortcutID != shortcut.id
        let isFreshCycle = state.lastPressAt == nil || didTimeout || interruptedByOtherShortcut

        if isFreshCycle {
            state.cycleIndex = 0
            state.displayOffset = 0
            state.activeDisplayAnchorIndex = nil
            state.pendingResetConsumed = false
        }

        let currentIndex = state.cycleIndex
        let wrappedToFirst = !isFreshCycle && currentIndex == 0
        let justConsumedReset = state.pendingResetConsumed

        // Refresh the shared pre-sequence frame's touch timestamp so it
        // doesn't go stale while the user keeps interleaving reset-enabled
        // shortcuts on this window within the timeout window.
        if shortcut.resetBeforeFirstStep {
            touchPreSequenceFrame(cycleKey: cycleKey)
        }

        if wrappedToFirst,
           shortcut.resetBeforeFirstStep,
           !justConsumedReset,
           shortcutPreFirstStepFrame(cycleKey: cycleKey) != nil {
            state.pendingResetConsumed = true
            state.lastPressAt = now
            shortcutCycleStates[cycleKey] = state
            lastFiredPlacementShortcutID = shortcut.id
            return .reset
        }

        state.pendingResetConsumed = false

        if wrappedToFirst && shortcut.cycleDisplaysOnWrap {
            let screensCount = max(sortedScreens().count, 1)
            state.displayOffset = (state.displayOffset + 1) % screensCount
        }

        state.cycleIndex = (currentIndex + 1) % count
        state.lastPressAt = now
        shortcutCycleStates[cycleKey] = state
        lastFiredPlacementShortcutID = shortcut.id

        let shouldCapture = (currentIndex == 0) && shortcut.resetBeforeFirstStep
        return .placement(shortcut.placements[currentIndex], capturePreFirstStepFrame: shouldCapture)
    }

    func nextPlacement(for shortcut: ShortcutConfig, targetWindowKey: String? = nil) -> PlacementStep? {
        switch nextShortcutAction(for: shortcut, targetWindowKey: targetWindowKey) {
        case .placement(let step, _):
            return step
        case .reset, .none:
            return nil
        }
    }

    func shortcutDisplayOffset(cycleKey: String) -> Int {
        shortcutCycleStates[cycleKey]?.displayOffset ?? 0
    }

    /// Storage key used by the shared per-window pre-sequence frame map.
    /// Falls back to the cycleKey itself when no window component is present
    /// (e.g. shortcut had no resolvable target window) so the legacy
    /// single-shortcut behavior still works.
    func preSequenceFrameStorageKey(cycleKey: String) -> String {
        if let pipeIndex = cycleKey.firstIndex(of: "|") {
            let suffix = cycleKey[cycleKey.index(after: pipeIndex)...]
            if !suffix.isEmpty {
                return String(suffix)
            }
        }
        return cycleKey
    }

    func shortcutPreFirstStepFrame(cycleKey: String) -> CGRect? {
        let key = preSequenceFrameStorageKey(cycleKey: cycleKey)
        guard let entry = preSequenceFrameByWindowKey[key] else { return nil }
        if Date().timeIntervalSince(entry.lastTouchedAt) >= shortcutCycleResetTimeout {
            preSequenceFrameByWindowKey.removeValue(forKey: key)
            return nil
        }
        return entry.frame
    }

    /// Stores the pre-sequence recovery frame for a cycle key.
    ///
    /// Default (forceOverwrite: false): first-write-wins — subsequent reset-enabled shortcuts
    /// firing on the same window inherit the original capture rather than overwriting with an
    /// intermediate frame.
    ///
    /// When forceOverwrite is true (used when +moveCursor is also enabled): always captures the
    /// current window position at sequence start so the recovery point is always fresh — after a
    /// reset restores the window, the next cycle's recovery point is the restored position, not
    /// the one from the first-ever cycle.
    func storeShortcutPreFirstStepFrame(
        cycleKey: String,
        frame: CGRect,
        cursorPosition: CGPoint? = nil,
        forceOverwrite: Bool = false
    ) {
        let key = preSequenceFrameStorageKey(cycleKey: cycleKey)
        let now = Date()
        if var existing = preSequenceFrameByWindowKey[key] {
            if forceOverwrite {
                preSequenceFrameByWindowKey[key] = PreSequenceFrameEntry(
                    frame: frame,
                    cursorPosition: cursorPosition,
                    lastTouchedAt: now
                )
            } else {
                // Refresh the touch timestamp so the shared entry stays alive
                // while the user keeps cycling, but keep the original frame.
                existing.lastTouchedAt = now
                preSequenceFrameByWindowKey[key] = existing
            }
            return
        }
        preSequenceFrameByWindowKey[key] = PreSequenceFrameEntry(
            frame: frame,
            cursorPosition: cursorPosition,
            lastTouchedAt: now
        )
    }

    func shortcutPreFirstStepCursorPosition(cycleKey: String) -> CGPoint? {
        let key = preSequenceFrameStorageKey(cycleKey: cycleKey)
        return preSequenceFrameByWindowKey[key]?.cursorPosition
    }

    /// Mark the shared pre-sequence frame as touched without changing it.
    /// Called on every reset-enabled shortcut press so the entry doesn't go
    /// stale while the user is actively cycling.
    func touchPreSequenceFrame(cycleKey: String) {
        let key = preSequenceFrameStorageKey(cycleKey: cycleKey)
        guard var entry = preSequenceFrameByWindowKey[key] else { return }
        entry.lastTouchedAt = Date()
        preSequenceFrameByWindowKey[key] = entry
    }

    /// Called after a wrap-reset is consumed. Clears the shared frame for the
    /// window and resets cycle state of every other reset-enabled shortcut
    /// targeting the same window so the next press of any of them is treated
    /// as a fresh capture round.
    func clearSharedPreSequenceState(cycleKey consumingCycleKey: String) {
        let key = preSequenceFrameStorageKey(cycleKey: consumingCycleKey)
        preSequenceFrameByWindowKey.removeValue(forKey: key)

        // Only meaningful when we actually have a windowKey component;
        // otherwise the storage key collides with the consuming shortcut's ID
        // and there's nothing to fan out to.
        guard consumingCycleKey.contains("|") else { return }
        let suffix = "|" + key
        for (otherCycleKey, _) in shortcutCycleStates where otherCycleKey != consumingCycleKey
            && otherCycleKey.hasSuffix(suffix) {
            // Extract the shortcutID portion to check resetBeforeFirstStep.
            let shortcutID = String(otherCycleKey.dropLast(suffix.count))
            guard let other = shortcutsByID[shortcutID], other.resetBeforeFirstStep else {
                continue
            }
            shortcutCycleStates[otherCycleKey] = ShortcutCycleState()
        }
    }

    /// Live cursor position to stash at capture time. Captured unconditionally
    /// (even when the cursor is outside the focused window's frame) so that the
    /// reset-with-warp restore returns the cursor to wherever it actually was
    /// before the sequence started.
    func cursorPositionToCapture() -> CGPoint {
        NSEvent.mouseLocation
    }

    /// Warp the cursor to `cocoaPoint`. Converts from Cocoa (bottom-left) to
    /// Quartz (top-left) using the multi-display desktop frame.
    func warpCursorToCocoaPoint(_ cocoaPoint: CGPoint) {
        let desktop = desktopFrame
        guard !desktop.isNull, !desktop.isEmpty else { return }
        let quartz = CGPoint(
            x: min(max(cocoaPoint.x, desktop.minX + 1), desktop.maxX - 1),
            y: desktop.maxY - min(max(cocoaPoint.y, desktop.minY + 1), desktop.maxY - 1)
        )
        _ = CGWarpMouseCursorPosition(quartz)
        CGAssociateMouseAndMouseCursorPosition(1)
    }

    /// If the restored cursor position landed inside the Control Center
    /// window, bring the Control Center back to key/front. The shortcut may
    /// have moved focus to the manipulated window; without this, the user is
    /// looking at their cursor over the Control Center but typing into the
    /// previously-focused app.
    func refocusControlCenterIfCursorIsOverIt(cocoaPoint: CGPoint) {
        guard let window = NSApp.windows.first(where: isControlCenterWindow),
              window.isVisible,
              !window.isMiniaturized,
              window.frame.contains(cocoaPoint),
              !window.isKeyWindow else {
            return
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
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
        if excludeControlCenter, isMoveEverythingActive, config.settings.moveEverythingExcludePinnedWindows {
            let pinnedFrames = allPinnedWindowFrames()
            for pinnedFrame in pinnedFrames {
                let edgeTolerance: CGFloat = moveEverythingNarrowMode
                    ? max(pinnedFrame.width, 24)
                    : 24
                available = MoveEverythingRetileLayout.availableFrame(
                    within: available,
                    excluding: pinnedFrame,
                    edgeTolerance: edgeTolerance
                )
            }
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

    func activeDisplayAnchor(cycleKey: String, focusedWindowRect: CGRect?) -> NSScreen? {
        let screens = sortedScreens()
        guard !screens.isEmpty else {
            return nil
        }

        if let anchoredIndex = shortcutCycleStates[cycleKey]?.activeDisplayAnchorIndex,
           anchoredIndex >= 0,
           anchoredIndex < screens.count {
            return screens[anchoredIndex]
        }

        let anchor = focusedWindowRect.flatMap(screenIntersecting(rect:)) ??
            screenContaining(point: NSEvent.mouseLocation) ??
            NSScreen.main ??
            screens.first
        if let anchor, let index = screens.firstIndex(of: anchor) {
            var state = shortcutCycleStates[cycleKey] ?? ShortcutCycleState()
            state.activeDisplayAnchorIndex = index
            shortcutCycleStates[cycleKey] = state
        }
        return anchor
    }
}

#endif
