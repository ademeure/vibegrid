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

        let focusedWindowRect = ownFocusedWindow?.frame ?? focusedWindowElement.flatMap(currentWindowRect(for:))
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
        if let ownFocusedWindow {
            didMove = setOwnWindow(ownFocusedWindow, cocoaRect: targetRect)
        } else if let focusedWindowElement {
            didMove = setWindow(focusedWindowElement, cocoaRect: targetRect)
        } else {
            didMove = false
        }

        if !didMove {
            NSLog("VibeGrid: failed to move focused window for shortcut '%@'", shortcutID)
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
        if isMoveEverythingActive {
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
        }
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
