#if os(macOS)
import AppKit
import ApplicationServices
import Foundation

// CGS private API for manipulating window levels of other apps' windows.
@_silgen_name("CGSMainConnectionID")
private func CGSMainConnectionID() -> Int32

@_silgen_name("CGSGetWindowLevel")
private func CGSGetWindowLevel(_ connection: Int32, _ windowID: UInt32, _ level: UnsafeMutablePointer<Int32>) -> Int32

@_silgen_name("CGSSetWindowLevel")
private func CGSSetWindowLevel(_ connection: Int32, _ windowID: UInt32, _ level: Int32) -> Int32

@_silgen_name("CGSOrderWindow")
private func CGSOrderWindow(_ connection: Int32, _ windowID: UInt32, _ ordering: Int32, _ relativeToWindow: UInt32) -> Int32

private let kCGSOrderAbove: Int32 = 1

// kCGModalPanelWindowLevel (8) is above floating (3) and torn-off menus (3),
// but below status bar (25) where the control center can live.
private let kCGSHoverRaiseWindowLevel: Int32 = 8


// MARK: - Move Everything core workflow

extension WindowManagerEngine {
        func moveEverythingControlCenterFocused() -> Bool {
            isMoveEverythingActive && isMoveEverythingControlCenterInteractionFocused()
        }
        func moveEverythingFocusedWindowKeySnapshot() -> String? {
            guard isMoveEverythingActive else {
                return nil
            }
            refreshMoveEverythingFocusedWindowKeyIfNeeded(force: false)
            return moveEverythingFocusedWindowKey
        }
        func moveEverythingWindowInventory() -> MoveEverythingWindowInventory {
            let liveInventory = resolveMoveEverythingWindowInventory()
            let suppressedHiddenKeys = activeMoveEverythingSuppressedHiddenWindowKeys()
            let hiddenCoreGraphicsFallbackSnapshots = liveInventory.hiddenCoreGraphicsFallback
                .filter { !suppressedHiddenKeys.contains($0.key) }
                .map { fallbackWindow in
                    moveEverythingSnapshot(for: fallbackWindow)
                }
            let fallbackStyleHiddenKeys = moveEverythingFallbackStyleHiddenWindowKeys
            guard isMoveEverythingActive else {
                let visibleSnapshots = liveInventory.visible.map { managedWindow in
                    moveEverythingSnapshot(for: managedWindow)
                }
                let regularHiddenSnapshots = liveInventory.hidden
                    .filter { !fallbackStyleHiddenKeys.contains($0.key) && !suppressedHiddenKeys.contains($0.key) }
                    .map { managedWindow in
                        moveEverythingSnapshot(for: managedWindow)
                    }
                let fallbackStyleHiddenSnapshots = liveInventory.hidden
                    .filter { fallbackStyleHiddenKeys.contains($0.key) && !suppressedHiddenKeys.contains($0.key) }
                    .map { managedWindow in
                        moveEverythingSnapshot(for: managedWindow, isCoreGraphicsFallback: true)
                    }
                return MoveEverythingWindowInventory(
                    visible: visibleSnapshots,
                    hidden: regularHiddenSnapshots + fallbackStyleHiddenSnapshots + hiddenCoreGraphicsFallbackSnapshots
                )
            }

            pruneMoveEverythingWindows(liveInventory: liveInventory)
            guard let runState = moveEverythingRunState else {
                let regularHiddenSnapshots = liveInventory.hidden
                    .filter { !fallbackStyleHiddenKeys.contains($0.key) && !suppressedHiddenKeys.contains($0.key) }
                    .map { managedWindow in
                        moveEverythingSnapshot(for: managedWindow)
                    }
                let fallbackStyleHiddenSnapshots = liveInventory.hidden
                    .filter { fallbackStyleHiddenKeys.contains($0.key) && !suppressedHiddenKeys.contains($0.key) }
                    .map { managedWindow in
                        moveEverythingSnapshot(for: managedWindow, isCoreGraphicsFallback: true)
                    }
                return MoveEverythingWindowInventory(
                    visible: [],
                    hidden: regularHiddenSnapshots + fallbackStyleHiddenSnapshots + hiddenCoreGraphicsFallbackSnapshots
                )
            }
            let visibleWindowKeys = Set(runState.windows.map(\.key))

            let visibleSnapshots = runState.windows.map { managedWindow in
                moveEverythingSnapshot(for: managedWindow)
            }

            let hiddenManagedWindows = liveInventory.hidden
                .filter { !visibleWindowKeys.contains($0.key) && !suppressedHiddenKeys.contains($0.key) }
            let regularHiddenSnapshots = hiddenManagedWindows
                .filter { !fallbackStyleHiddenKeys.contains($0.key) }
                .map { managedWindow in
                    moveEverythingSnapshot(for: managedWindow)
                }
            let fallbackStyleHiddenSnapshots = hiddenManagedWindows
                .filter { fallbackStyleHiddenKeys.contains($0.key) }
                .map { managedWindow in
                    moveEverythingSnapshot(for: managedWindow, isCoreGraphicsFallback: true)
                }

            return MoveEverythingWindowInventory(
                visible: visibleSnapshots,
                hidden: regularHiddenSnapshots + fallbackStyleHiddenSnapshots + hiddenCoreGraphicsFallbackSnapshots
            )
        }
        func focusMoveEverythingWindowForExplicitSelection(
            _ managedWindow: MoveEverythingManagedWindow,
            timeout: TimeInterval
        ) -> Bool {
            let clampedTimeout = max(0, timeout)
            let deadline = Date().addingTimeInterval(clampedTimeout)
            let fastVerificationWindow = min(0.12, clampedTimeout)

            return withTemporarilyDemotedControlCenterWindowLevel {
                var didDeactivateControlCenterApp = false

                if !didDeactivateControlCenterApp {
                    NSApp.deactivate()
                    didDeactivateControlCenterApp = true
                }

                // Fast path: request focus once without forcing strict verification,
                // then verify briefly before entering the slower retry loop.
                if focusMoveEverythingWindow(
                    managedWindow,
                    allowAppActivation: true,
                    requireActualFocus: false
                ) && waitForMoveEverythingWindowToBecomeFocused(
                    managedWindow,
                    timeout: fastVerificationWindow
                ) {
                    return true
                }

                while true {
                    if !didDeactivateControlCenterApp {
                        NSApp.deactivate()
                        didDeactivateControlCenterApp = true
                    }

                    if focusMoveEverythingWindow(
                        managedWindow,
                        allowAppActivation: true,
                        requireActualFocus: true
                    ) || isMoveEverythingWindowFocused(managedWindow) {
                        return true
                    }

                    if Date() >= deadline {
                        break
                    }
                    _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.03))
                }

                return isMoveEverythingWindowFocused(managedWindow)
            }
        }
        func warpMousePointerToMoveEverythingWindowTopMiddle(
            _ managedWindow: MoveEverythingManagedWindow
        ) -> Bool {
            guard let frame = currentWindowRect(for: managedWindow.window),
                  frame.width > 1,
                  frame.height > 1 else {
                return false
            }

            let desktop = desktopFrame
            guard !desktop.isNull, !desktop.isEmpty else {
                return false
            }

            let topInset: CGFloat = min(6, frame.height - 1)
            let targetCocoaPoint = CGPoint(
                x: min(max(frame.midX, desktop.minX + 1), desktop.maxX - 1),
                y: min(max(frame.maxY - topInset, desktop.minY + 1), desktop.maxY - 1)
            )
            let targetQuartzPoint = CGPoint(
                x: targetCocoaPoint.x,
                y: desktop.maxY - targetCocoaPoint.y
            )
            return CGWarpMouseCursorPosition(targetQuartzPoint) == .success
        }
        func withTemporarilyDemotedControlCenterWindowLevel<T>(_ body: () -> T) -> T {
            guard let controlCenterWindow = NSApp.windows.first(where: isControlCenterWindow) else {
                return body()
            }

            let originalLevel = controlCenterWindow.level
            let shouldDemote = originalLevel.rawValue > NSWindow.Level.normal.rawValue
            if shouldDemote {
                controlCenterWindow.level = .normal
            }
            defer {
                if shouldDemote {
                    controlCenterWindow.level = originalLevel
                }
            }
            return body()
        }
        func ensureMoveEverythingActiveForDirectAction() -> Bool {
            if isMoveEverythingActive {
                return true
            }

            let result = startMoveEverythingMode()
            switch result {
            case .started:
                return true
            case .stopped:
                return isMoveEverythingActive
            case .failed:
                return false
            }
        }
        func setMoveEverythingLastDirectActionError(_ message: String?) {
            let normalized = message?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let normalized, !normalized.isEmpty {
                moveEverythingLastDirectActionErrorMessage = normalized
            } else {
                moveEverythingLastDirectActionErrorMessage = nil
            }
        }
        func moveEverythingLastDirectActionError() -> String? {
            let message = moveEverythingLastDirectActionErrorMessage
            setMoveEverythingLastDirectActionError(nil)
            return message
        }
        func closeMoveEverythingWindow(withKey key: String) -> Bool {
            guard ensureMoveEverythingActiveForDirectAction() else {
                return false
            }

            pruneMoveEverythingWindows(forceRefreshInventory: true)
            if let runState = moveEverythingRunState,
               let targetIndex = runState.windows.firstIndex(where: { $0.key == key }) {
                return closeMoveEverythingWindow(at: targetIndex)
            }

            let inventory = resolveMoveEverythingWindowInventory(forceRefresh: true)
            if let hiddenWindow = inventory.hidden.first(where: { $0.key == key }) {
                guard closeMoveEverythingWindow(hiddenWindow) else {
                    return false
                }
                moveEverythingFallbackStyleHiddenWindowKeys.remove(key)
                suppressMoveEverythingHiddenWindowVisibility(forKey: key)
                invalidateMoveEverythingResolvedInventoryCache()
                pruneMoveEverythingWindows(forceRefreshInventory: true)
                return true
            }

            let derivedCoreGraphicsFallbackKey = derivedCoreGraphicsFallbackWindowKey(from: key)
            if let hiddenCoreGraphicsFallbackWindow = inventory.hiddenCoreGraphicsFallback.first(
                where: { $0.key == key || $0.key == derivedCoreGraphicsFallbackKey }
            ) {
                guard closeMoveEverythingCoreGraphicsFallbackWindow(hiddenCoreGraphicsFallbackWindow) else {
                    return false
                }
                moveEverythingFallbackStyleHiddenWindowKeys.remove(key)
                moveEverythingFallbackStyleHiddenWindowKeys.remove(hiddenCoreGraphicsFallbackWindow.key)
                suppressMoveEverythingHiddenWindowVisibility(forKey: key)
                suppressMoveEverythingHiddenWindowVisibility(forKey: hiddenCoreGraphicsFallbackWindow.key)
                invalidateMoveEverythingResolvedInventoryCache()
                pruneMoveEverythingWindows(forceRefreshInventory: true)
                return true
            }

            return false
        }
        func hideMoveEverythingWindow(withKey key: String) -> Bool {
            guard ensureMoveEverythingActiveForDirectAction() else {
                return false
            }

            pruneMoveEverythingWindows(forceRefreshInventory: true)
            let runStateLookup = moveEverythingRunState
            let targetIndex = runStateLookup?.windows.firstIndex(where: { $0.key == key })
            guard var runState = runStateLookup,
                  let targetIndex else {
                return false
            }

            let managedWindow = runState.windows[targetIndex]
            guard hideMoveEverythingWindow(managedWindow) else {
                return false
            }
            moveEverythingFallbackStyleHiddenWindowKeys.insert(managedWindow.key)
            moveEverythingHiddenWindowVisibilitySuppressionByKey.removeValue(forKey: managedWindow.key)
            invalidateMoveEverythingResolvedInventoryCache()

            let preservedState = runState.statesByWindowKey[managedWindow.key] ??
                MoveEverythingWindowState(
                    originalFrame: currentWindowRect(for: managedWindow.window) ?? .zero,
                    hasVisited: true,
                    isCentered: false
                )
            let restoreFrame = currentWindowRect(for: managedWindow.window) ?? preservedState.originalFrame
            removeMoveEverythingWindowFromRunState(&runState, at: targetIndex)
            runState.statesByWindowKey[managedWindow.key] = preservedState
            runState.hiddenWindowRestoreByKey[managedWindow.key] = MoveEverythingHiddenWindowRestore(
                frame: restoreFrame,
                state: preservedState
            )
            moveEverythingRunState = runState
            notifyMoveEverythingModeChanged()

            if runState.windows.indices.contains(runState.currentIndex) {
                _ = focusMoveEverythingCurrentWindow(showOverlay: true, applyFirstVisitCenter: true)
            } else {
                hideMoveEverythingOverlay()
            }

            return true
        }
        func showHiddenMoveEverythingWindow(withKey key: String) -> Bool {
            return showHiddenMoveEverythingWindow(withKey: key, centerOnShow: false, maximizeOnShow: false)
        }
        @discardableResult
        func showHiddenMoveEverythingWindow(
            withKey key: String,
            centerOnShow: Bool,
            maximizeOnShow: Bool
        ) -> Bool {
            guard ensureMoveEverythingActiveForDirectAction() else {
                return false
            }

            pruneMoveEverythingWindows()
            guard var runState = moveEverythingRunState else {
                return false
            }

            if let existingIndex = runState.windows.firstIndex(where: { $0.key == key }) {
                runState.currentIndex = existingIndex
                if let previousHoveredKey = moveEverythingHoveredWindowKey {
                    restoreMoveEverythingAdvancedHoverLayoutSilentlyIfNeeded(
                        forKey: previousHoveredKey,
                        in: runState
                    )
                    if previousHoveredKey == key {
                        moveEverythingHoveredWindowKey = previousHoveredKey
                        lockMoveEverythingHoveredWindow(previousHoveredKey)
                    } else {
                        moveEverythingHoveredWindowKey = nil
                        clearMoveEverythingHoveredWindowLock()
                    }
                }
                moveEverythingRunState = runState
                moveEverythingFallbackStyleHiddenWindowKeys.remove(key)
                moveEverythingHiddenWindowVisibilitySuppressionByKey.removeValue(forKey: key)
                notifyMoveEverythingModeChanged()
                let didFocus = focusMoveEverythingCurrentWindow(
                    showOverlay: true,
                    applyFirstVisitCenter: true,
                    skipPrune: true,
                    requireActualFocus: centerOnShow || maximizeOnShow
                )
                if !didFocus {
                    pruneMoveEverythingWindows()
                }
                return didFocus
            }

            let inventory = resolveMoveEverythingWindowInventory(forceRefresh: true)
            guard let hiddenWindow = inventory.hidden.first(where: { $0.key == key }) else {
                let derivedCoreGraphicsFallbackKey = derivedCoreGraphicsFallbackWindowKey(from: key)
                guard let hiddenCoreGraphicsFallbackWindow = inventory.hiddenCoreGraphicsFallback.first(
                    where: { $0.key == key || $0.key == derivedCoreGraphicsFallbackKey }
                ) else {
                    return false
                }
                guard revealMoveEverythingCoreGraphicsFallbackWindow(hiddenCoreGraphicsFallbackWindow) else {
                    return false
                }
                moveEverythingFallbackStyleHiddenWindowKeys.remove(key)
                moveEverythingFallbackStyleHiddenWindowKeys.remove(hiddenCoreGraphicsFallbackWindow.key)
                moveEverythingHiddenWindowVisibilitySuppressionByKey.removeValue(forKey: key)
                moveEverythingHiddenWindowVisibilitySuppressionByKey.removeValue(forKey: hiddenCoreGraphicsFallbackWindow.key)
                invalidateMoveEverythingResolvedInventoryCache()
                pruneMoveEverythingWindows(forceRefreshInventory: true)
                return true
            }

            let restoreContext = runState.hiddenWindowRestoreByKey[key]
            let shouldRestorePreviousPosition = !centerOnShow && !maximizeOnShow && restoreContext != nil
            let revealTargetFrame: CGRect?
            if maximizeOnShow {
                let referenceFrame = currentWindowRect(for: hiddenWindow.window) ??
                    restoreContext?.frame ??
                    defaultMoveEverythingCenterRect()
                revealTargetFrame = referenceFrame.flatMap(maximizedMoveEverythingRect(for:))
            } else if centerOnShow {
                let referenceFrame = currentWindowRect(for: hiddenWindow.window) ??
                    restoreContext?.frame ??
                    defaultMoveEverythingCenterRect()
                revealTargetFrame = referenceFrame.flatMap(centeredMoveEverythingRect(for:))
            } else if shouldRestorePreviousPosition {
                revealTargetFrame = restoreContext?.frame
            } else {
                revealTargetFrame = nil
            }

            guard revealMoveEverythingHiddenWindow(hiddenWindow, targetFrame: revealTargetFrame) else {
                return false
            }
            moveEverythingFallbackStyleHiddenWindowKeys.remove(key)
            moveEverythingHiddenWindowVisibilitySuppressionByKey.removeValue(forKey: key)
            invalidateMoveEverythingResolvedInventoryCache()

            let refreshedInventory = resolveMoveEverythingWindowInventory(forceRefresh: true)
            let resolvedWindow = refreshedInventory.visible.first(where: { $0.key == key }) ?? hiddenWindow
            runState.windows.append(resolvedWindow)
            runState.currentIndex = runState.windows.count - 1

            if var state = restoreContext?.state ?? runState.statesByWindowKey[resolvedWindow.key] {
                if state.originalFrame == .zero {
                    state.originalFrame = restoreContext?.frame ??
                        currentWindowRect(for: resolvedWindow.window) ??
                        .zero
                }
                state.hasVisited = true
                state.isCentered = centerOnShow
                runState.statesByWindowKey[resolvedWindow.key] = state
            } else {
                runState.statesByWindowKey[resolvedWindow.key] = MoveEverythingWindowState(
                    originalFrame: currentWindowRect(for: resolvedWindow.window) ?? .zero,
                    hasVisited: true,
                    isCentered: centerOnShow
                )
            }
            runState.hiddenWindowRestoreByKey.removeValue(forKey: resolvedWindow.key)

            moveEverythingRunState = runState
            notifyMoveEverythingModeChanged()
            let didFocus = focusMoveEverythingCurrentWindow(
                showOverlay: true,
                applyFirstVisitCenter: false,
                skipPrune: true,
                requireActualFocus: centerOnShow || maximizeOnShow
            )
            if !didFocus {
                pruneMoveEverythingWindows()
            }
            return didFocus
        }
        func focusMoveEverythingWindow(
            withKey key: String,
            movePointerToTopMiddle: Bool = false
        ) -> Bool {
            guard ensureMoveEverythingActiveForDirectAction() else {
                return false
            }

            guard var runState = moveEverythingRunState,
                  let existingIndex = runState.windows.firstIndex(where: { $0.key == key }),
                  runState.windows.indices.contains(existingIndex) else {
                return false
            }

            let managedWindow = runState.windows[existingIndex]
            guard !isMoveEverythingControlCenterWindow(managedWindow) else {
                return false
            }

            if let previousHoveredKey = moveEverythingHoveredWindowKey,
               previousHoveredKey != key {
                restoreMoveEverythingAdvancedHoverLayoutSilentlyIfNeeded(
                    forKey: previousHoveredKey,
                    in: runState
                )
            }

            runState.currentIndex = existingIndex
            moveEverythingRunState = runState

            clearMoveEverythingExternalFocusOverlayState()
            let didFocus = withTemporarilyDemotedControlCenterWindowLevel {
                if focusMoveEverythingWindow(
                    managedWindow,
                    allowAppActivation: true,
                    requireActualFocus: false
                ) {
                    return true
                }
                return isMoveEverythingWindowFocused(managedWindow)
            }
            if didFocus {
                moveEverythingSelectionSyncSuppressedUntil = Date().addingTimeInterval(
                    moveEverythingSelectionSyncSuppressionInterval
                )
                moveEverythingFocusedWindowKey = managedWindow.key
                moveEverythingFocusedWindowLastCheckAt = Date()
                moveEverythingHoveredWindowKey = managedWindow.key
                lockMoveEverythingHoveredWindow(managedWindow.key)
                if movePointerToTopMiddle {
                    _ = warpMousePointerToMoveEverythingWindowTopMiddle(managedWindow)
                }
                showMoveEverythingOverlay(for: managedWindow)
                return true
            }

            moveEverythingFocusedWindowLastCheckAt = nil
            clearMoveEverythingHoveredWindowLock()
            return false
        }
        func centerMoveEverythingWindow(withKey key: String) -> Bool {
            guard ensureMoveEverythingActiveForDirectAction() else {
                return false
            }

            pruneMoveEverythingWindows(forceRefreshInventory: true)
            guard var runState = moveEverythingRunState else {
                return false
            }

            if let existingIndex = runState.windows.firstIndex(where: { $0.key == key }) {
                runState.currentIndex = existingIndex
                guard runState.windows.indices.contains(existingIndex) else {
                    return false
                }

                if let previousHoveredKey = moveEverythingHoveredWindowKey {
                    restoreMoveEverythingAdvancedHoverLayoutSilentlyIfNeeded(
                        forKey: previousHoveredKey,
                        in: runState
                    )
                    if previousHoveredKey == key {
                        moveEverythingHoveredWindowKey = previousHoveredKey
                        lockMoveEverythingHoveredWindow(previousHoveredKey)
                    } else {
                        moveEverythingHoveredWindowKey = nil
                        clearMoveEverythingHoveredWindowLock()
                    }
                }

                let managedWindow = runState.windows[existingIndex]
                let referenceFrame = currentWindowRect(for: managedWindow.window) ??
                    runState.statesByWindowKey[managedWindow.key]?.originalFrame ??
                    defaultMoveEverythingCenterRect()
                guard let referenceFrame,
                      let centeredFrame = centeredMoveEverythingRect(for: referenceFrame) else {
                    return false
                }
                guard setMoveEverythingWindowFrame(managedWindow, cocoaRect: centeredFrame) else {
                    return false
                }

                var windowState = runState.statesByWindowKey[managedWindow.key] ??
                    MoveEverythingWindowState(
                        originalFrame: referenceFrame,
                        hasVisited: true,
                        isCentered: true
                    )
                if windowState.originalFrame == .zero {
                    windowState.originalFrame = referenceFrame
                }
                windowState.hasVisited = true
                windowState.isCentered = true
                runState.statesByWindowKey[managedWindow.key] = windowState

                moveEverythingRunState = runState
                notifyMoveEverythingModeChanged()
                let didFocus = focusMoveEverythingCurrentWindow(
                    showOverlay: true,
                    applyFirstVisitCenter: false,
                    skipPrune: true,
                    requireActualFocus: true
                )
                if !didFocus {
                    pruneMoveEverythingWindows()
                }
                return didFocus
            }

            return showHiddenMoveEverythingWindow(withKey: key, centerOnShow: true, maximizeOnShow: false)
        }
        func maximizeMoveEverythingWindow(withKey key: String) -> Bool {
            guard ensureMoveEverythingActiveForDirectAction() else {
                return false
            }

            pruneMoveEverythingWindows()
            guard var runState = moveEverythingRunState else {
                return false
            }

            if let existingIndex = runState.windows.firstIndex(where: { $0.key == key }) {
                runState.currentIndex = existingIndex
                guard runState.windows.indices.contains(existingIndex) else {
                    return false
                }

                if let previousHoveredKey = moveEverythingHoveredWindowKey {
                    restoreMoveEverythingAdvancedHoverLayoutSilentlyIfNeeded(
                        forKey: previousHoveredKey,
                        in: runState
                    )
                    if previousHoveredKey == key {
                        moveEverythingHoveredWindowKey = previousHoveredKey
                        lockMoveEverythingHoveredWindow(previousHoveredKey)
                    } else {
                        moveEverythingHoveredWindowKey = nil
                        clearMoveEverythingHoveredWindowLock()
                    }
                }

                let managedWindow = runState.windows[existingIndex]
                let referenceFrame = currentWindowRect(for: managedWindow.window) ??
                    runState.statesByWindowKey[managedWindow.key]?.originalFrame ??
                    defaultMoveEverythingCenterRect()
                guard let referenceFrame,
                      let maximizedFrame = maximizedMoveEverythingRect(for: referenceFrame) else {
                    return false
                }
                guard setMoveEverythingWindowFrame(managedWindow, cocoaRect: maximizedFrame) else {
                    return false
                }

                var windowState = runState.statesByWindowKey[managedWindow.key] ??
                    MoveEverythingWindowState(
                        originalFrame: referenceFrame,
                        hasVisited: true,
                        isCentered: false
                    )
                if windowState.originalFrame == .zero {
                    windowState.originalFrame = referenceFrame
                }
                windowState.hasVisited = true
                windowState.isCentered = false
                runState.statesByWindowKey[managedWindow.key] = windowState

                moveEverythingRunState = runState
                notifyMoveEverythingModeChanged()
                let didFocus = focusMoveEverythingCurrentWindow(
                    showOverlay: true,
                    applyFirstVisitCenter: false,
                    skipPrune: true,
                    requireActualFocus: true
                )
                if !didFocus {
                    pruneMoveEverythingWindows()
                }
                return didFocus
            }

            return showHiddenMoveEverythingWindow(withKey: key, centerOnShow: false, maximizeOnShow: true)
        }
        func retileVisibleMoveEverythingWindows() -> Bool {
            retileVisibleMoveEverythingWindows(
                widthFraction: 1,
                aspectRatio: 1,  // square tiles
                successVerb: "Retiled"
            )
        }
        func miniRetileVisibleMoveEverythingWindows() -> Bool {
            let widthPercent = min(max(config.settings.moveEverythingMiniRetileWidthPercent, 5), 100)
            return retileVisibleMoveEverythingWindows(
                widthFraction: CGFloat(widthPercent / 100),
                aspectRatio: 1,
                successVerb: "Mini retiled"
            )
        }
        func retileVisibleMoveEverythingWindows(
            widthFraction: CGFloat,
            aspectRatio: CGFloat,
            successVerb: String
        ) -> Bool {
            guard ensureMoveEverythingActiveForDirectAction() else {
                return false
            }

            pruneMoveEverythingWindows(forceRefreshInventory: true)
            guard var runState = moveEverythingRunState else {
                moveEverythingLastDirectActionErrorMessage = "No visible windows were found."
                return false
            }

            if let previousHoveredKey = moveEverythingHoveredWindowKey {
                restoreMoveEverythingAdvancedHoverLayoutSilentlyIfNeeded(
                    forKey: previousHoveredKey,
                    in: runState
                )
            }
            moveEverythingHoveredWindowKey = nil
            clearMoveEverythingHoveredWindowLock()

            let managedWindows = runState.windows
                .filter { !isMoveEverythingControlCenterWindow($0) }
                .sorted(by: moveEverythingRetileSortPredicate)
            guard !managedWindows.isEmpty else {
                moveEverythingLastDirectActionErrorMessage = "No visible windows were found."
                moveEverythingRunState = runState
                return false
            }

            let referenceFrame = currentControlCenterFrameForMoveEverything() ??
                currentWindowRect(for: managedWindows[0].window) ??
                defaultMoveEverythingCenterRect()
            guard let referenceFrame,
                  let fullAvailableFrame = moveEverythingRetileAvailableFrame(for: referenceFrame) else {
                moveEverythingLastDirectActionErrorMessage = "Unable to determine a target display."
                return false
            }

            let availableFrame: CGRect
            if widthFraction >= 0.999 {
                availableFrame = fullAvailableFrame
            } else {
                let controlCenterIsOnRight: Bool
                if let ccFrame = currentControlCenterFrameForMoveEverything() {
                    controlCenterIsOnRight = ccFrame.midX > fullAvailableFrame.midX
                } else {
                    controlCenterIsOnRight = false
                }
                availableFrame = controlCenterIsOnRight
                    ? MoveEverythingRetileLayout.leadingHorizontalSlice(
                        of: fullAvailableFrame,
                        widthFraction: widthFraction
                    )
                    : MoveEverythingRetileLayout.trailingHorizontalSlice(
                        of: fullAvailableFrame,
                        widthFraction: widthFraction
                    )
            }

            let gap = max(CGFloat(config.settings.gap), 0)
            let targetFrames = moveEverythingTiledFrames(
                count: managedWindows.count,
                availableFrame: availableFrame,
                aspectRatio: aspectRatio,
                gap: gap
            )
            guard targetFrames.count == managedWindows.count else {
                moveEverythingLastDirectActionErrorMessage = "Unable to compute a valid grid for the visible windows."
                return false
            }

            var movedCount = 0
            var skippedWindowTitles: [String] = []
            for (managedWindow, targetFrame) in zip(managedWindows, targetFrames) {
                let referenceFrame = currentWindowRect(for: managedWindow.window) ?? targetFrame
                guard setMoveEverythingWindowFrame(managedWindow, cocoaRect: targetFrame) else {
                    skippedWindowTitles.append(moveEverythingWindowTitle(for: managedWindow))
                    continue
                }

                var windowState = runState.statesByWindowKey[managedWindow.key] ??
                    MoveEverythingWindowState(
                        originalFrame: referenceFrame,
                        hasVisited: true,
                        isCentered: false
                    )
                if windowState.originalFrame == .zero {
                    windowState.originalFrame = referenceFrame
                }
                windowState.hasVisited = true
                windowState.isCentered = false
                runState.statesByWindowKey[managedWindow.key] = windowState
                movedCount += 1
            }

            guard movedCount > 0 else {
                moveEverythingLastDirectActionErrorMessage = "Unable to move or resize any of the visible windows."
                return false
            }

            if !skippedWindowTitles.isEmpty {
                let skippedSummary = skippedWindowTitles.prefix(3).joined(separator: ", ")
                let suffix = skippedWindowTitles.count > 3 ? "…" : ""
                moveEverythingLastDirectActionErrorMessage =
                    "\(successVerb) \(movedCount) window\(movedCount == 1 ? "" : "s"). " +
                    "Skipped \(skippedWindowTitles.count): \(skippedSummary)\(suffix)"
                NSLog(
                    "VibeGrid: retile skipped windows: %@",
                    skippedWindowTitles.joined(separator: " | ")
                )
            } else {
                moveEverythingLastDirectActionErrorMessage = nil
            }

            moveEverythingRunState = runState
            invalidateMoveEverythingResolvedInventoryCache()
            requestMoveEverythingInventoryRefreshIfNeeded(force: true)
            notifyMoveEverythingModeChanged()
            return true
        }
        func toggleMoveEverythingMode() -> MoveEverythingToggleResult {
            if isMoveEverythingActive {
                stopMoveEverythingMode(notify: true)
                return .stopped
            }
            return startMoveEverythingMode()
        }
        func setMoveEverythingShowOverlays(_ enabled: Bool) {
            moveEverythingShowOverlays = enabled
            if enabled {
                refreshMoveEverythingOverlayPresentation()
            } else {
                hideMoveEverythingOverlayVisualOnly()
            }
        }
        func setMoveEverythingMoveToBottom(_ enabled: Bool) {
            let effective = enabled && isMoveEverythingActive
            guard effective != moveEverythingMoveToBottom else {
                return
            }

            moveEverythingMoveToBottom = effective
            if !moveEverythingMoveToBottom {
                restoreAllMoveEverythingAdvancedHoverLayoutsIfNeeded(in: moveEverythingRunState)
                refreshMoveEverythingOverlayPresentation()
                return
            }

            guard let runState = moveEverythingRunState,
                  let hoveredKey = moveEverythingHoveredWindowKey,
                  let hoveredWindow = runState.windows.first(where: { $0.key == hoveredKey }) else {
                refreshMoveEverythingOverlayPresentation()
                return
            }
            applyMoveEverythingAdvancedHoverLayoutIfNeeded(to: hoveredWindow)
            refreshMoveEverythingOverlayPresentation()
        }
        func setMoveEverythingDontMoveVibeGrid(_ enabled: Bool) {
            moveEverythingDontMoveVibeGrid = enabled
            guard enabled else {
                return
            }
            focusMoveEverythingControlCenterForStickyHoverIfNeeded()
        }
        func setMoveEverythingNarrowMode(_ enabled: Bool) {
            guard moveEverythingNarrowMode != enabled else {
                return
            }
            moveEverythingNarrowMode = enabled

            guard isMoveEverythingActive,
                  moveEverythingMoveToBottom,
                  let runState = moveEverythingRunState,
                  let hoveredKey = moveEverythingHoveredWindowKey,
                  let hoveredWindow = runState.windows.first(where: { $0.key == hoveredKey }) else {
                refreshMoveEverythingOverlayPresentation()
                return
            }

            restoreMoveEverythingAdvancedHoverLayoutSilentlyIfNeeded(forKey: hoveredKey, in: runState)
            applyMoveEverythingAdvancedHoverLayoutIfNeeded(to: hoveredWindow)
            refreshMoveEverythingOverlayPresentation()
        }
        func setMoveEverythingHoveredWindow(withKey key: String?) -> Bool {
            let startedAt = DispatchTime.now().uptimeNanoseconds
            defer {
                let normalizedKey = key?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                logMoveEverythingPerfIfSlow(
                    "hover.update key=\(normalizedKey.isEmpty ? "<none>" : normalizedKey)",
                    startedAt: startedAt,
                    thresholdMs: 18
                )
            }

            guard isMoveEverythingActive else {
                restoreAllHoverElevatedWindowLevels()
                moveEverythingHoverAdvancedOriginalFrameByWindowKey.removeAll()
                clearMoveEverythingExternalFocusOverlayState()
                moveEverythingHoveredWindowKey = nil
                clearMoveEverythingHoveredWindowLock()
                return false
            }

            guard let runState = moveEverythingRunState else {
                restoreAllHoverElevatedWindowLevels()
                moveEverythingHoverAdvancedOriginalFrameByWindowKey.removeAll()
                clearMoveEverythingExternalFocusOverlayState()
                moveEverythingHoveredWindowKey = nil
                clearMoveEverythingHoveredWindowLock()
                return false
            }

            let normalizedKey = key?.trimmingCharacters(in: .whitespacesAndNewlines)
            let requestedHoverKey: String? = (normalizedKey?.isEmpty == false) ? normalizedKey : nil
            if let lockedKey = currentMoveEverythingHoveredWindowLockKey(),
               let requestedHoverKey,
               requestedHoverKey != lockedKey {
                return true
            }

            if normalizedKey?.isEmpty != false {
                clearMoveEverythingHoveredWindowState(in: runState)
                return true
            }

            guard let hoveredKey = normalizedKey,
                  let hoveredWindow = runState.windows.first(where: { $0.key == hoveredKey }),
                  !isMoveEverythingControlCenterWindow(hoveredWindow) else {
                clearMoveEverythingHoveredWindowState(in: runState)
                return false
            }

            if moveEverythingHoveredWindowKey == hoveredWindow.key {
                return true
            }

            let previousHoveredKey = moveEverythingHoveredWindowKey
            // Save the focused key before hover starts so we can restore it
            // when hover ends (hover-raise changes OS focus as a side-effect).
            if previousHoveredKey == nil {
                moveEverythingFocusedKeyBeforeHover = moveEverythingFocusedWindowKey
            }
            moveEverythingHoveredWindowKey = hoveredWindow.key
            let didPerformSmoothTransition = transitionMoveEverythingAdvancedHoverLayout(
                from: previousHoveredKey,
                to: hoveredWindow,
                in: runState
            )
            if !didPerformSmoothTransition {
                if let previousHoveredKey {
                    restoreMoveEverythingAdvancedHoverLayoutSilentlyIfNeeded(forKey: previousHoveredKey, in: runState)
                }
                applyMoveEverythingAdvancedHoverLayoutIfNeeded(to: hoveredWindow)
                pulseMoveEverythingHoveredWindowToFront(hoveredWindow)
            }
            WindowListDebugLogger.log(
                "hover-raise",
                "hover key=\(hoveredWindow.key) app=\(hoveredWindow.appName) smooth=\(didPerformSmoothTransition)"
            )
            refreshMoveEverythingOverlayPresentation()
            return true
        }
        func clearMoveEverythingHoveredWindowState(in runState: MoveEverythingRunState) {
            guard moveEverythingHoveredWindowKey != nil ||
                  !moveEverythingHoverAdvancedOriginalFrameByWindowKey.isEmpty else {
                return
            }
            restoreAllMoveEverythingAdvancedHoverLayoutsSilentlyIfNeeded(in: runState)
            restoreAllHoverElevatedWindowLevels()
            moveEverythingHoveredWindowKey = nil
            // Restore the focused key from before hover so the focused window
            // highlight doesn't stick to whatever was last hovered.
            if let saved = moveEverythingFocusedKeyBeforeHover {
                moveEverythingFocusedWindowKey = saved
                moveEverythingFocusedKeyBeforeHover = nil
            }
            clearMoveEverythingHoveredWindowLock()
            refreshMoveEverythingOverlayPresentation()
        }
        func consumeMoveEverythingHoveredWindowForHotkeyAction() -> String? {
            guard isMoveEverythingActive else {
                return nil
            }

            requestMoveEverythingInventoryRefreshIfNeeded(force: false)
            guard var runState = moveEverythingRunState,
                  let hoveredKey = moveEverythingHoveredWindowKey,
                  let targetIndex = runState.windows.firstIndex(where: { $0.key == hoveredKey }) else {
                return nil
            }

            let targetWindow = runState.windows[targetIndex]
            guard !isMoveEverythingControlCenterWindow(targetWindow) else {
                clearMoveEverythingHoveredWindowState(in: runState)
                return nil
            }

            temporarilyPinControlCenterWindowOnTopForMoveEverything()

            // Hotkeys consume hover: restore hover layout and clear hover state before selecting.
            clearMoveEverythingHoveredWindowState(in: runState)

            runState.currentIndex = targetIndex
            moveEverythingRunState = runState
            notifyMoveEverythingModeChanged()

            clearMoveEverythingExternalFocusOverlayState()
            moveEverythingSelectionSyncSuppressedUntil = Date().addingTimeInterval(
                moveEverythingSelectionSyncSuppressionInterval
            )
            moveEverythingFocusedWindowKey = targetWindow.key
            moveEverythingFocusedWindowLastCheckAt = Date()
            moveEverythingHoveredWindowKey = targetWindow.key
            lockMoveEverythingHoveredWindow(targetWindow.key)
            refreshMoveEverythingOverlayPresentation()
            return targetWindow.key
        }
        func startMoveEverythingMode() -> MoveEverythingToggleResult {
            ensureControlCenterWindowVisibleForMoveEverything()
            invalidateMoveEverythingResolvedInventoryCache()
            let managedWindows = resolveMoveEverythingWindowInventory(forceRefresh: true).visible
            guard !managedWindows.isEmpty else {
                return .failed("No visible windows were found.")
            }

            var statesByWindowKey: [String: MoveEverythingWindowState] = [:]
            for managedWindow in managedWindows {
                guard let frame = currentWindowRect(for: managedWindow.window) else {
                    continue
                }
                statesByWindowKey[managedWindow.key] = MoveEverythingWindowState(
                    originalFrame: frame,
                    hasVisited: false,
                    isCentered: false
                )
            }

            let windowsWithState = managedWindows.filter { statesByWindowKey[$0.key] != nil }
            guard !windowsWithState.isEmpty else {
                return .failed("No movable windows were found.")
            }

            moveEverythingRunState = MoveEverythingRunState(
                windows: windowsWithState,
                currentIndex: 0,
                statesByWindowKey: statesByWindowKey,
                hiddenWindowRestoreByKey: [:]
            )
            moveEverythingHoverAdvancedOriginalFrameByWindowKey.removeAll()
            clearMoveEverythingExternalFocusOverlayState()
            moveEverythingHoveredWindowKey = nil
            clearMoveEverythingHoveredWindowLock()
            moveEverythingFocusedWindowKey = nil
            moveEverythingFocusedWindowLastCheckAt = nil
            moveEverythingSelectionSyncSuppressedUntil = nil
            moveEverythingHoverFocusTransitionDepth = 0
            isMoveEverythingActive = true
            moveEverythingControlCenterFocusedLastKnown = isMoveEverythingControlCenterFocused()

            if !hotkeysSuspendedForCapture {
                registerEnabledHotkeys()
            }
            notifyMoveEverythingModeChanged()
            startMoveEverythingBackgroundInventoryTimer()

            moveEverythingOverlay.prepare()
            moveEverythingBottomOverlay.prepare()
            moveEverythingOriginalPositionOverlay.prepare()
            refreshMoveEverythingOverlayPresentation()
            guard focusMoveEverythingCurrentWindow(showOverlay: true, applyFirstVisitCenter: true) else {
                stopMoveEverythingMode(notify: true)
                return .failed("Unable to focus a visible window.")
            }

            return .started
        }
        func stopMoveEverythingMode(notify: Bool) {
            guard isMoveEverythingActive else {
                return
            }

            moveEverythingTemporaryControlCenterTopRestoreWorkItem?.cancel()
            moveEverythingTemporaryControlCenterTopRestoreWorkItem = nil

            if let runState = moveEverythingRunState {
                restoreAllMoveEverythingAdvancedHoverLayoutsIfNeeded(in: runState)
            }
            isMoveEverythingActive = false
            stopMoveEverythingBackgroundInventoryTimer()
            moveEverythingRunState = nil
            moveEverythingIconDataURLByPID.removeAll()
            moveEverythingResolvedWindowNumberByKey.removeAll()
            moveEverythingHoverAdvancedOriginalFrameByWindowKey.removeAll()
            clearMoveEverythingExternalFocusOverlayState()
            restoreAllHoverElevatedWindowLevels()
            moveEverythingHoverOriginalLevelByWindowNumber.removeAll()
            moveEverythingHoveredWindowKey = nil
            clearMoveEverythingHoveredWindowLock()
            moveEverythingFocusedWindowKey = nil
            moveEverythingFocusedWindowLastCheckAt = nil
            moveEverythingSelectionSyncSuppressedUntil = nil
            moveEverythingHoverFocusTransitionDepth = 0
            moveEverythingControlCenterFocusedLastKnown = false
            moveEverythingMoveToBottom = false
            hideMoveEverythingOverlay()
            invalidateMoveEverythingResolvedInventoryCache(clearCachedWindows: true)

            if !hotkeysSuspendedForCapture {
                registerEnabledHotkeys()
            }

            if notify {
                notifyMoveEverythingModeChanged()
            }
        }
        func notifyMoveEverythingModeChanged() {
            onMoveEverythingModeChanged?(isMoveEverythingActive)
        }
        func waitForMoveEverythingWindowToBecomeFocused(
            _ managedWindow: MoveEverythingManagedWindow,
            timeout: TimeInterval
        ) -> Bool {
            if isMoveEverythingWindowFocused(managedWindow) {
                return true
            }

            let deadline = Date().addingTimeInterval(max(0, timeout))
            while Date() < deadline {
                _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
                if isMoveEverythingWindowFocused(managedWindow) {
                    return true
                }
            }

            return isMoveEverythingWindowFocused(managedWindow)
        }
        func waitForMoveEverythingApplicationToBecomeFrontmost(
            pid: pid_t,
            timeout: TimeInterval
        ) -> Bool {
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == pid {
                return true
            }

            let deadline = Date().addingTimeInterval(max(0, timeout))
            while Date() < deadline {
                _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
                if NSWorkspace.shared.frontmostApplication?.processIdentifier == pid {
                    return true
                }
            }

            return NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
        }
        func toggleMoveEverythingCurrentWindowPosition() {
            guard isMoveEverythingActive else {
                return
            }

            pruneMoveEverythingWindows()
            guard var runState = moveEverythingRunState,
                  runState.windows.indices.contains(runState.currentIndex) else {
                return
            }

            let managedWindow = runState.windows[runState.currentIndex]
            guard var state = runState.statesByWindowKey[managedWindow.key] else {
                return
            }

            let targetRect: CGRect
            if state.isCentered {
                targetRect = state.originalFrame
                state.isCentered = false
            } else {
                let referenceFrame = currentWindowRect(for: managedWindow.window) ?? state.originalFrame
                guard let centeredRect = centeredMoveEverythingRect(for: referenceFrame) else {
                    return
                }
                targetRect = centeredRect
                state.isCentered = true
                if !state.hasVisited {
                    state.hasVisited = true
                }
            }

            guard setMoveEverythingWindowFrame(managedWindow, cocoaRect: targetRect) else {
                return
            }

            runState.statesByWindowKey[managedWindow.key] = state
            moveEverythingRunState = runState
            clearMoveEverythingExternalFocusOverlayState()
            _ = focusMoveEverythingWindow(managedWindow, allowAppActivation: false)
            showMoveEverythingOverlay(for: managedWindow)
        }
        func closeMoveEverythingCurrentWindow() {
            guard isMoveEverythingActive else {
                return
            }

            pruneMoveEverythingWindows()
            guard let runState = moveEverythingRunState,
                  runState.windows.indices.contains(runState.currentIndex) else {
                return
            }
            _ = closeMoveEverythingWindow(at: runState.currentIndex)
        }
        func hideMoveEverythingCurrentWindow() {
            guard isMoveEverythingActive else {
                return
            }

            pruneMoveEverythingWindows()
            guard let runState = moveEverythingRunState,
                  runState.windows.indices.contains(runState.currentIndex) else {
                return
            }
            _ = hideMoveEverythingWindow(withKey: runState.windows[runState.currentIndex].key)
        }
        @discardableResult
        func closeMoveEverythingWindow(at index: Int) -> Bool {
            guard var runState = moveEverythingRunState,
                  runState.windows.indices.contains(index) else {
                return false
            }

            let managedWindow = runState.windows[index]
            guard closeMoveEverythingWindow(managedWindow) else {
                return false
            }
            invalidateMoveEverythingResolvedInventoryCache()

            removeMoveEverythingWindowFromRunState(&runState, at: index)
            moveEverythingRunState = runState
            notifyMoveEverythingModeChanged()

            if runState.windows.indices.contains(runState.currentIndex) {
                _ = focusMoveEverythingCurrentWindow(showOverlay: true, applyFirstVisitCenter: true)
            } else {
                hideMoveEverythingOverlay()
            }

            return true
        }
        func removeMoveEverythingWindowFromRunState(_ runState: inout MoveEverythingRunState, at index: Int) {
            guard runState.windows.indices.contains(index) else {
                return
            }

            let removedKey = runState.windows[index].key
            runState.windows.remove(at: index)
            runState.statesByWindowKey.removeValue(forKey: removedKey)
            runState.hiddenWindowRestoreByKey.removeValue(forKey: removedKey)
            moveEverythingHoverAdvancedOriginalFrameByWindowKey.removeValue(forKey: removedKey)
            moveEverythingFallbackStyleHiddenWindowKeys.remove(removedKey)
            moveEverythingHiddenWindowVisibilitySuppressionByKey.removeValue(forKey: removedKey)

            guard !runState.windows.isEmpty else {
                runState.currentIndex = -1
                return
            }

            if index < runState.currentIndex {
                runState.currentIndex -= 1
                return
            }

            runState.currentIndex = min(runState.currentIndex, runState.windows.count - 1)
        }
        func currentMoveEverythingProgress(_ runState: MoveEverythingRunState?) -> (current: Int, total: Int)? {
            guard let runState,
                  !runState.windows.isEmpty,
                  runState.currentIndex >= 0,
                  runState.currentIndex < runState.windows.count else {
                return nil
            }

            return (
                current: runState.currentIndex + 1,
                total: runState.windows.count
            )
        }
        func pruneMoveEverythingWindows(
            liveInventory: MoveEverythingManagedWindowInventory? = nil,
            forceRefreshInventory: Bool = false
        ) {
            guard var runState = moveEverythingRunState else {
                return
            }

            let previousProgress = currentMoveEverythingProgress(runState)
            let currentKey = runState.windows.indices.contains(runState.currentIndex)
                ? runState.windows[runState.currentIndex].key
                : nil

            let resolvedInventory = liveInventory ??
                resolveMoveEverythingWindowInventory(forceRefresh: forceRefreshInventory)
            let liveVisibleByKey = Dictionary(uniqueKeysWithValues: resolvedInventory.visible.map { ($0.key, $0) })
            let liveHiddenKeys = Set(
                resolvedInventory.hidden.map(\.key) +
                resolvedInventory.hiddenCoreGraphicsFallback.map(\.key)
            )
            let liveKeys = Set(
                resolvedInventory.visible.map(\.key) +
                Array(liveHiddenKeys)
            )

            runState.windows = runState.windows.compactMap { managedWindow in
                guard runState.statesByWindowKey[managedWindow.key] != nil else {
                    return nil
                }
                return liveVisibleByKey[managedWindow.key]
            }

            let keepStateKeys = liveKeys.union(Set(runState.hiddenWindowRestoreByKey.keys))
            runState.statesByWindowKey = runState.statesByWindowKey.filter { keepStateKeys.contains($0.key) }
            runState.hiddenWindowRestoreByKey = runState.hiddenWindowRestoreByKey.filter {
                liveKeys.contains($0.key)
            }
            moveEverythingHoverAdvancedOriginalFrameByWindowKey = moveEverythingHoverAdvancedOriginalFrameByWindowKey
                .filter { liveKeys.contains($0.key) }
            moveEverythingFallbackStyleHiddenWindowKeys = Set(
                moveEverythingFallbackStyleHiddenWindowKeys.filter { liveHiddenKeys.contains($0) }
            )
            let suppressionNow = Date()
            moveEverythingHiddenWindowVisibilitySuppressionByKey = moveEverythingHiddenWindowVisibilitySuppressionByKey.filter {
                liveHiddenKeys.contains($0.key) && $0.value > suppressionNow
            }

            var existingWindowKeys = Set(runState.windows.map(\.key))
            for managedWindow in resolvedInventory.visible where !existingWindowKeys.contains(managedWindow.key) {
                runState.windows.append(managedWindow)
                if runState.statesByWindowKey[managedWindow.key] == nil {
                    runState.statesByWindowKey[managedWindow.key] = MoveEverythingWindowState(
                        originalFrame: currentWindowRect(for: managedWindow.window) ?? .zero,
                        hasVisited: false,
                        isCentered: false
                    )
                }
                existingWindowKeys.insert(managedWindow.key)
            }

            if runState.windows.isEmpty {
                runState.currentIndex = -1
            } else if let currentKey,
                      let updatedIndex = runState.windows.firstIndex(where: { $0.key == currentKey }) {
                runState.currentIndex = updatedIndex
            } else if runState.currentIndex < 0 {
                runState.currentIndex = 0
            } else {
                runState.currentIndex = min(runState.currentIndex, runState.windows.count - 1)
            }

            let previousSelectedKey: String? = {
                guard let previousRunState = moveEverythingRunState,
                      previousRunState.windows.indices.contains(previousRunState.currentIndex) else {
                    return nil
                }
                return previousRunState.windows[previousRunState.currentIndex].key
            }()
            if let hoveredKey = moveEverythingHoveredWindowKey,
               !runState.windows.contains(where: { $0.key == hoveredKey }) {
                moveEverythingHoveredWindowKey = nil
                clearMoveEverythingHoveredWindowLock()
            }
            moveEverythingRunState = runState
            let nextProgress = currentMoveEverythingProgress(runState)
            let nextSelectedKey = runState.windows.indices.contains(runState.currentIndex)
                ? runState.windows[runState.currentIndex].key
                : nil

            if runState.windows.isEmpty {
                hideMoveEverythingOverlay()
            } else {
                refreshMoveEverythingOverlayPresentation()
            }

            if previousProgress?.current != nextProgress?.current ||
                previousProgress?.total != nextProgress?.total ||
                previousSelectedKey != nextSelectedKey {
                notifyMoveEverythingModeChanged()
            }
        }
        func focusMoveEverythingCurrentWindow(
            showOverlay: Bool,
            applyFirstVisitCenter: Bool,
            skipPrune: Bool = false,
            clearExternalFocusOverlayState: Bool = true,
            requireActualFocus: Bool = false
        ) -> Bool {
            if clearExternalFocusOverlayState {
                clearMoveEverythingExternalFocusOverlayState()
            }
            if !skipPrune {
                pruneMoveEverythingWindows()
            }

            guard var runState = moveEverythingRunState,
                  runState.windows.indices.contains(runState.currentIndex) else {
                hideMoveEverythingOverlay()
                return false
            }

            let managedWindow = runState.windows[runState.currentIndex]
            guard var state = runState.statesByWindowKey[managedWindow.key] else {
                return false
            }

            if applyFirstVisitCenter {
                let shouldCenterOnSelection: Bool
                let shouldApplyMiniControlCenterLayout: Bool
                switch config.settings.moveEverythingMoveOnSelection {
                case .never:
                    shouldCenterOnSelection = false
                    shouldApplyMiniControlCenterLayout = false
                case .miniControlCenterOnTop:
                    shouldCenterOnSelection = false
                    shouldApplyMiniControlCenterLayout = isMoveEverythingControlCenterWindow(managedWindow) &&
                        !state.hasVisited &&
                        !moveEverythingDontMoveVibeGrid
                case .firstSelection:
                    shouldCenterOnSelection = !state.hasVisited
                    shouldApplyMiniControlCenterLayout = false
                case .always:
                    shouldCenterOnSelection = true
                    shouldApplyMiniControlCenterLayout = false
                }

                if shouldApplyMiniControlCenterLayout {
                    let referenceFrame = currentWindowRect(for: managedWindow.window) ?? state.originalFrame
                    if let miniRect = miniControlCenterMoveEverythingRect(for: referenceFrame) {
                        _ = setMoveEverythingWindowFrame(managedWindow, cocoaRect: miniRect)
                        state.isCentered = true
                    }
                }

                if shouldCenterOnSelection {
                    let referenceFrame = currentWindowRect(for: managedWindow.window) ?? state.originalFrame
                    if let centeredRect = centeredMoveEverythingRect(for: referenceFrame) {
                        _ = setMoveEverythingWindowFrame(managedWindow, cocoaRect: centeredRect)
                        state.isCentered = true
                    }
                }
                if !state.hasVisited {
                    state.hasVisited = true
                }
            }

            runState.statesByWindowKey[managedWindow.key] = state
            moveEverythingRunState = runState

            let didFocus = focusMoveEverythingWindow(
                managedWindow,
                allowAppActivation: true,
                requireActualFocus: requireActualFocus
            )
            if didFocus {
                moveEverythingFocusedWindowLastCheckAt = nil
            }

            if showOverlay {
                showMoveEverythingOverlay(for: managedWindow)
            }

            return didFocus
        }
        func isMoveEverythingControlCenterFocused() -> Bool {
            guard let controlCenterWindow = NSApp.windows.first(where: isControlCenterWindow) else {
                return false
            }
            guard NSApp.isActive else {
                return false
            }
            if controlCenterWindow.isKeyWindow {
                return true
            }
            guard let keyWindow = NSApp.keyWindow else {
                return false
            }
            return keyWindow === controlCenterWindow && keyWindow.isKeyWindow
        }
        func isMoveEverythingControlCenterInteractionFocused() -> Bool {
            isMoveEverythingHoverFocusTransitionInProgress || isMoveEverythingControlCenterFocused()
        }
        func isMoveEverythingWindowFocused(_ managedWindow: MoveEverythingManagedWindow) -> Bool {
            guard !isMoveEverythingControlCenterWindow(managedWindow) else {
                return false
            }

            if let ownWindow = ownWindow(for: managedWindow), ownWindow.isKeyWindow {
                return true
            }

            if let identity = frontmostLayerZeroWindowIdentity(),
               identity.pid == managedWindow.pid {
                if let managedNumber = managedWindow.windowNumber {
                    return identity.windowNumber == managedNumber
                }
                if let focused = focusedWindow(),
                   moveEverythingManagedWindow(managedWindow, matchesFocusedWindow: focused) {
                    return true
                }
                return false
            }

            if let focused = focusedWindow(),
               moveEverythingManagedWindow(managedWindow, matchesFocusedWindow: focused) {
                return true
            }

            return false
        }
        func moveEverythingManagedWindow(
            _ managedWindow: MoveEverythingManagedWindow,
            matchesFocusedWindow focusedWindow: AXUIElement
        ) -> Bool {
            var focusedWindowPID: pid_t = 0
            AXUIElementGetPid(focusedWindow, &focusedWindowPID)
            guard focusedWindowPID == managedWindow.pid else {
                return false
            }

            let focusedWindowNumber = copyIntAttribute(from: focusedWindow, attribute: "AXWindowNumber")
            if let focusedWindowNumber,
               let managedWindowNumber = managedWindow.windowNumber {
                return focusedWindowNumber == managedWindowNumber
            }

            if CFEqual(focusedWindow, managedWindow.window) {
                return true
            }

            return false
        }
        func frontmostLayerZeroWindowIdentity() -> (pid: pid_t, windowNumber: Int?)? {
            let infoList = CGWindowListCopyWindowInfo(
                [.optionOnScreenOnly, .excludeDesktopElements],
                kCGNullWindowID
            ) as? [[String: Any]] ?? []

            for info in infoList {
                guard let layer = info[kCGWindowLayer as String] as? Int, layer == 0 else {
                    continue
                }
                guard let ownerPIDNumber = info[kCGWindowOwnerPID as String] as? NSNumber else {
                    continue
                }

                let pid = pid_t(ownerPIDNumber.int32Value)
                let windowNumber = (info[kCGWindowNumber as String] as? NSNumber).map { Int(truncating: $0) }
                return (pid, windowNumber)
            }

            return nil
        }
        func moveEverythingOverlayTargetWindow(from runState: MoveEverythingRunState) -> MoveEverythingManagedWindow? {
            if let hoveredKey = moveEverythingHoveredWindowKey,
               let hoveredWindow = runState.windows.first(where: { $0.key == hoveredKey }) {
                return hoveredWindow
            }

            guard runState.windows.indices.contains(runState.currentIndex) else {
                return nil
            }
            return runState.windows[runState.currentIndex]
        }
        func pulseMoveEverythingHoveredWindowToFront(_ managedWindow: MoveEverythingManagedWindow) {
            guard isMoveEverythingActive,
                  moveEverythingShowOverlays,
                  !isMoveEverythingControlCenterWindow(managedWindow) else {
                return
            }

            // Restore ALL previously-elevated windows before elevating the new one.
            // This ensures that rapidly switching between hovers doesn't leave
            // stale elevated windows blocking the newly-hovered one.
            restoreAllHoverElevatedWindowLevels()

            // Suppress selection sync while we temporarily shift OS focus to the
            // target app and back — without this, the 20ms overlay sync timer
            // picks up the transient focus change and bounces the selection.
            suppressMoveEverythingSelectionSyncForProgrammaticFocus()

            // Pin the control center above everything so it stays interactive
            // even after we activate another app to bring its window to front.
            temporarilyPinControlCenterWindowOnTopForMoveEverything()

            // Activate the target app so its windows come above all other
            // normal-level windows, then raise the specific window within it.
            // Use fast timeout to avoid main-thread stalls on slow apps.
            if let app = NSRunningApplication(processIdentifier: managedWindow.pid) {
                app.activate(options: [])
            }
            let hoveredWindow = managedWindow.window
            applyAXMessagingTimeout(to: hoveredWindow, timeout: axFocusMessagingTimeout)
            let raiseResult = AXUIElementPerformAction(hoveredWindow, kAXRaiseAction as CFString)

            // Re-activate VibeGrid so the control center remains key for input.
            NSApp.activate(ignoringOtherApps: true)
            elevateWindowForHover(managedWindow)

            WindowListDebugLogger.log(
                "hover-raise",
                "pulse key=\(managedWindow.key) app=\(managedWindow.appName) raise=\(raiseResult == .success ? "ok" : "err:\(raiseResult.rawValue)") elevated=\(moveEverythingHoverElevatedWindows.count)"
            )
        }

        func restoreAllHoverElevatedWindowLevels() {
            guard !moveEverythingHoverElevatedWindows.isEmpty else { return }
            let conn = CGSMainConnectionID()
            for entry in moveEverythingHoverElevatedWindows {
                let result = CGSSetWindowLevel(conn, UInt32(entry.windowNumber), entry.originalLevel)
                WindowListDebugLogger.log(
                    "hover-raise",
                    "restore wid=\(entry.windowNumber) toLevel=\(entry.originalLevel) result=\(result)"
                )
            }
            moveEverythingHoverElevatedWindows.removeAll()
        }

        /// Resolve the CGWindowNumber for a managed window. Tries cached value,
        /// then AXWindowNumber, then falls back to matching via PID + frame in CGWindowList.
        func resolveCGWindowNumber(for managedWindow: MoveEverythingManagedWindow) -> Int? {
            if let wn = managedWindow.windowNumber { return wn }
            if let cached = moveEverythingResolvedWindowNumberByKey[managedWindow.key] { return cached }
            // Use fast timeout — this is called during hover and must not stall.
            applyAXMessagingTimeout(to: managedWindow.window, timeout: axFocusMessagingTimeout)
            if let wn = copyIntAttribute(from: managedWindow.window, attribute: "AXWindowNumber") {
                moveEverythingResolvedWindowNumberByKey[managedWindow.key] = wn
                return wn
            }

            // Fallback: match by PID + frame in the CoreGraphics window list.
            guard let axFrame = rawAXWindowRect(for: managedWindow.window) else { return nil }
            guard let infoList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return nil }
            for info in infoList {
                guard let pid = info[kCGWindowOwnerPID as String] as? pid_t,
                      pid == managedWindow.pid,
                      let bounds = info[kCGWindowBounds as String] as? [String: Any],
                      let x = bounds["X"] as? CGFloat, let y = bounds["Y"] as? CGFloat,
                      let w = bounds["Width"] as? CGFloat, let h = bounds["Height"] as? CGFloat,
                      let wn = info[kCGWindowNumber as String] as? Int else { continue }
                if abs(x - axFrame.origin.x) <= 2 && abs(y - axFrame.origin.y) <= 2 &&
                   abs(w - axFrame.size.width) <= 2 && abs(h - axFrame.size.height) <= 2 {
                    moveEverythingResolvedWindowNumberByKey[managedWindow.key] = wn
                    return wn
                }
            }
            return nil
        }

        /// Elevate a window to floating level so it stays above other windows
        /// during hover. Called after NSApp.activate to avoid reordering.
        func elevateWindowForHover(_ managedWindow: MoveEverythingManagedWindow) {
            guard let windowNumber = resolveCGWindowNumber(for: managedWindow) else {
                WindowListDebugLogger.log(
                    "hover-raise",
                    "elevate: NO windowNumber for key=\(managedWindow.key)"
                )
                return
            }
            let conn = CGSMainConnectionID()
            let wid = UInt32(windowNumber)

            // Use the saved original level if we've elevated this window before,
            // so that a window stuck at level 8 doesn't poison its "original" record.
            let originalLevel: Int32
            if let saved = moveEverythingHoverOriginalLevelByWindowNumber[windowNumber] {
                originalLevel = saved
            } else {
                var currentLevel: Int32 = 0
                let getResult = CGSGetWindowLevel(conn, wid, &currentLevel)
                guard getResult == 0 else {
                    WindowListDebugLogger.log(
                        "hover-raise",
                        "elevate: CGSGetWindowLevel failed conn=\(conn) wid=\(wid) err=\(getResult)"
                    )
                    return
                }
                // If the window is already at our hover level, it was likely
                // stuck from a previous hover — treat its true original as normal (0).
                originalLevel = (currentLevel == kCGSHoverRaiseWindowLevel) ? 0 : currentLevel
                moveEverythingHoverOriginalLevelByWindowNumber[windowNumber] = originalLevel
            }

            moveEverythingHoverElevatedWindows.append(
                (windowNumber: windowNumber, originalLevel: originalLevel)
            )
            let setResult = CGSSetWindowLevel(conn, wid, kCGSHoverRaiseWindowLevel)
            // Reorder the window above all others at this level so it actually
            // appears on top even when another window is already at level 8.
            let orderResult = CGSOrderWindow(conn, wid, kCGSOrderAbove, 0)
            WindowListDebugLogger.log(
                "hover-raise",
                "elevate: wid=\(wid) origLevel=\(originalLevel) to=\(kCGSHoverRaiseWindowLevel) set=\(setResult) order=\(orderResult)"
            )
        }

        func shouldApplyMoveEverythingAdvancedHoverLayout(
            to managedWindow: MoveEverythingManagedWindow
        ) -> Bool {
            guard isMoveEverythingActive else {
                return false
            }
            guard moveEverythingMoveToBottom else {
                return false
            }
            guard config.settings.moveEverythingMoveOnSelection == .miniControlCenterOnTop else {
                return false
            }
            return !isMoveEverythingControlCenterWindow(managedWindow)
        }
        func applyMoveEverythingAdvancedHoverLayoutIfNeeded(to managedWindow: MoveEverythingManagedWindow) {
            guard shouldApplyMoveEverythingAdvancedHoverLayout(to: managedWindow) else {
                return
            }
            guard moveEverythingHoverAdvancedOriginalFrameByWindowKey[managedWindow.key] == nil else {
                return
            }
            // Use the fast hover timeout to avoid main-thread stalls on slow apps.
            guard let originalFrame = currentWindowRect(for: managedWindow.window, timeout: axFocusMessagingTimeout),
                  let hoverFrame = moveEverythingAdvancedHoverRect(for: originalFrame) else {
                return
            }

            moveEverythingHoverAdvancedOriginalFrameByWindowKey[managedWindow.key] = originalFrame
            beginMoveEverythingHoverFocusTransition()
            suppressMoveEverythingSelectionSyncForProgrammaticFocus()
            _ = focusMoveEverythingWindow(
                managedWindow,
                allowAppActivation: true,
                requireActualFocus: false
            )
            guard setMoveEverythingWindowFrame(managedWindow, cocoaRect: hoverFrame) else {
                moveEverythingHoverAdvancedOriginalFrameByWindowKey.removeValue(forKey: managedWindow.key)
                endMoveEverythingHoverFocusTransition()
                return
            }
            pulseMoveEverythingHoveredWindowToFront(managedWindow)
            ensureControlCenterWindowVisibleForMoveEverything()
            endMoveEverythingHoverFocusTransition()
        }
        func transitionMoveEverythingAdvancedHoverLayout(
            from previousHoveredKey: String?,
            to hoveredWindow: MoveEverythingManagedWindow,
            in runState: MoveEverythingRunState
        ) -> Bool {
            guard isMoveEverythingActive else {
                return false
            }

            let previousKey = (previousHoveredKey == hoveredWindow.key) ? nil : previousHoveredKey
            var didHandleTransition = false
            beginMoveEverythingHoverFocusTransition()

            // Restore previous hover layout without focusing that window.
            if let previousKey {
                restoreMoveEverythingAdvancedHoverLayoutSilentlyIfNeeded(forKey: previousKey, in: runState)
                didHandleTransition = true
            }

            // Focus new hovered window, apply layout, then return focus to control center.
            // Use the fast hover timeout to avoid main-thread stalls on slow apps.
            if shouldApplyMoveEverythingAdvancedHoverLayout(to: hoveredWindow),
               moveEverythingHoverAdvancedOriginalFrameByWindowKey[hoveredWindow.key] == nil,
               let originalFrame = currentWindowRect(for: hoveredWindow.window, timeout: axFocusMessagingTimeout),
               let hoverFrame = moveEverythingAdvancedHoverRect(for: originalFrame) {
                moveEverythingHoverAdvancedOriginalFrameByWindowKey[hoveredWindow.key] = originalFrame
                suppressMoveEverythingSelectionSyncForProgrammaticFocus()
                _ = focusMoveEverythingWindow(
                    hoveredWindow,
                    allowAppActivation: true,
                    requireActualFocus: false
                )
                didHandleTransition = true
                if !setMoveEverythingWindowFrame(hoveredWindow, cocoaRect: hoverFrame) {
                    moveEverythingHoverAdvancedOriginalFrameByWindowKey.removeValue(forKey: hoveredWindow.key)
                } else {
                    pulseMoveEverythingHoveredWindowToFront(hoveredWindow)
                }
            } else {
                raiseMoveEverythingWindowWithoutFocus(hoveredWindow)
                didHandleTransition = true
            }

            guard didHandleTransition else {
                endMoveEverythingHoverFocusTransition()
                return false
            }

            // Immediately return focus to control center (no delayed callback).
            ensureControlCenterWindowVisibleForMoveEverything()
            endMoveEverythingHoverFocusTransition()

            return true
        }
        func raiseMoveEverythingWindowWithoutFocus(_ managedWindow: MoveEverythingManagedWindow) {
            guard isMoveEverythingActive,
                  !isMoveEverythingControlCenterWindow(managedWindow) else {
                return
            }

            restoreAllHoverElevatedWindowLevels()
            suppressMoveEverythingSelectionSyncForProgrammaticFocus()
            temporarilyPinControlCenterWindowOnTopForMoveEverything()

            if let app = NSRunningApplication(processIdentifier: managedWindow.pid) {
                app.activate(options: [])
            }
            let hoveredWindow = managedWindow.window
            applyAXMessagingTimeout(to: hoveredWindow, timeout: axFocusMessagingTimeout)
            let raiseResult = AXUIElementPerformAction(hoveredWindow, kAXRaiseAction as CFString)
            WindowListDebugLogger.log(
                "hover-raise",
                "noFocus key=\(managedWindow.key) app=\(managedWindow.appName) raise=\(raiseResult == .success ? "ok" : "err:\(raiseResult.rawValue)")"
            )

            NSApp.activate(ignoringOtherApps: true)
            elevateWindowForHover(managedWindow)
        }
        func restoreMoveEverythingAdvancedHoverLayoutIfNeeded(
            forKey key: String,
            in runState: MoveEverythingRunState
        ) {
            guard let originalFrame = moveEverythingHoverAdvancedOriginalFrameByWindowKey.removeValue(forKey: key),
                  let managedWindow = runState.windows.first(where: { $0.key == key }) else {
                return
            }
            beginMoveEverythingHoverFocusTransition()
            suppressMoveEverythingSelectionSyncForProgrammaticFocus()
            _ = focusMoveEverythingWindow(managedWindow, allowAppActivation: false)
            _ = setMoveEverythingWindowFrame(managedWindow, cocoaRect: originalFrame)
            ensureControlCenterWindowVisibleForMoveEverything()
            endMoveEverythingHoverFocusTransition()
        }
        func restoreMoveEverythingAdvancedHoverLayoutSilentlyIfNeeded(
            forKey key: String,
            in runState: MoveEverythingRunState
        ) {
            guard let originalFrame = moveEverythingHoverAdvancedOriginalFrameByWindowKey.removeValue(forKey: key),
                  let managedWindow = runState.windows.first(where: { $0.key == key }) else {
                return
            }
            _ = setMoveEverythingWindowFrame(managedWindow, cocoaRect: originalFrame)
        }
        func restoreAllMoveEverythingAdvancedHoverLayoutsIfNeeded(in runState: MoveEverythingRunState?) {
            guard !moveEverythingHoverAdvancedOriginalFrameByWindowKey.isEmpty else {
                return
            }
            guard let runState else {
                moveEverythingHoverAdvancedOriginalFrameByWindowKey.removeAll()
                return
            }

            let keys = Array(moveEverythingHoverAdvancedOriginalFrameByWindowKey.keys)
            for key in keys {
                restoreMoveEverythingAdvancedHoverLayoutIfNeeded(forKey: key, in: runState)
            }
        }
        func restoreAllMoveEverythingAdvancedHoverLayoutsSilentlyIfNeeded(in runState: MoveEverythingRunState) {
            guard !moveEverythingHoverAdvancedOriginalFrameByWindowKey.isEmpty else {
                return
            }

            let keys = Array(moveEverythingHoverAdvancedOriginalFrameByWindowKey.keys)
            for key in keys {
                restoreMoveEverythingAdvancedHoverLayoutSilentlyIfNeeded(forKey: key, in: runState)
            }
        }
        func restoreMoveEverythingAdvancedHoverLayoutsSilentlyIfNeeded(
            in runState: MoveEverythingRunState,
            excludingWindowKey excludedKey: String?
        ) {
            guard !moveEverythingHoverAdvancedOriginalFrameByWindowKey.isEmpty else {
                return
            }

            let keys = Array(moveEverythingHoverAdvancedOriginalFrameByWindowKey.keys)
            for key in keys {
                if key == excludedKey {
                    // Keep selected window at its current hover-applied position.
                    moveEverythingHoverAdvancedOriginalFrameByWindowKey.removeValue(forKey: key)
                    continue
                }
                restoreMoveEverythingAdvancedHoverLayoutSilentlyIfNeeded(forKey: key, in: runState)
            }
        }
        func beginMoveEverythingHoverFocusTransition() {
            moveEverythingHoverFocusTransitionDepth += 1
            suppressMoveEverythingSelectionSyncForProgrammaticFocus(interval: 0.2)
        }
        func endMoveEverythingHoverFocusTransition() {
            guard moveEverythingHoverFocusTransitionDepth > 0 else {
                return
            }
            moveEverythingHoverFocusTransitionDepth -= 1
            if moveEverythingHoverFocusTransitionDepth == 0 {
                moveEverythingFocusedWindowLastCheckAt = nil
            }
        }
        func suppressMoveEverythingSelectionSyncForProgrammaticFocus(interval: TimeInterval? = nil) {
            let suppressionDuration = max(interval ?? moveEverythingSelectionSyncSuppressionInterval, 0)
            let deadline = Date().addingTimeInterval(suppressionDuration)
            if let existing = moveEverythingSelectionSyncSuppressedUntil, existing > deadline {
                return
            }
            moveEverythingSelectionSyncSuppressedUntil = deadline
        }
        func isMoveEverythingSelectionSyncSuppressed() -> Bool {
            guard let suppressedUntil = moveEverythingSelectionSyncSuppressedUntil else {
                return false
            }
            if Date() <= suppressedUntil {
                return true
            }
            moveEverythingSelectionSyncSuppressedUntil = nil
            return false
        }
        func lockMoveEverythingHoveredWindow(
            _ key: String,
            interval: TimeInterval? = nil
        ) {
            let duration = max(interval ?? moveEverythingHoverRetentionInterval, 0)
            guard duration > 0 else {
                clearMoveEverythingHoveredWindowLock()
                return
            }
            moveEverythingHoveredWindowLockKey = key
            moveEverythingHoveredWindowLockUntil = Date().addingTimeInterval(duration)
        }
        func clearMoveEverythingHoveredWindowLock() {
            moveEverythingHoveredWindowLockKey = nil
            moveEverythingHoveredWindowLockUntil = nil
        }
        func currentMoveEverythingHoveredWindowLockKey() -> String? {
            guard let lockKey = moveEverythingHoveredWindowLockKey,
                  let lockUntil = moveEverythingHoveredWindowLockUntil else {
                return nil
            }
            if Date() <= lockUntil {
                return lockKey
            }
            clearMoveEverythingHoveredWindowLock()
            return nil
        }
        func syncMoveEverythingControlCenterFocusStateIfNeeded(notifyOnChange: Bool) -> Bool {
            if isMoveEverythingHoverFocusTransitionInProgress {
                if moveEverythingControlCenterFocusedLastKnown != true {
                    moveEverythingControlCenterFocusedLastKnown = true
                    if notifyOnChange {
                        notifyMoveEverythingModeChanged()
                    }
                }
                return true
            }

            focusMoveEverythingControlCenterForStickyHoverIfNeeded()

            let focused = isMoveEverythingControlCenterFocused()
            guard focused != moveEverythingControlCenterFocusedLastKnown else {
                return focused
            }

            moveEverythingControlCenterFocusedLastKnown = focused
            if !focused,
               let hoveredKey = moveEverythingHoveredWindowKey,
               let runState = moveEverythingRunState {
                let lockedKey = currentMoveEverythingHoveredWindowLockKey()
                if lockedKey != hoveredKey {
                    restoreMoveEverythingAdvancedHoverLayoutSilentlyIfNeeded(forKey: hoveredKey, in: runState)
                    moveEverythingHoveredWindowKey = nil
                    clearMoveEverythingHoveredWindowLock()
                }
            }

            if notifyOnChange {
                notifyMoveEverythingModeChanged()
            }
            return focused
        }
        func focusMoveEverythingControlCenterForStickyHoverIfNeeded() {
            guard config.settings.moveEverythingStickyHoverStealFocus,
                  moveEverythingDontMoveVibeGrid,
                  isMoveEverythingActive,
                  let controlCenterWindow = NSApp.windows.first(where: isControlCenterWindow),
                  controlCenterWindow.isVisible,
                  !controlCenterWindow.isMiniaturized,
                  controlCenterWindow.frame.contains(NSEvent.mouseLocation),
                  !isMoveEverythingControlCenterFocused() else {
                return
            }

            ensureControlCenterWindowVisibleForMoveEverything()
        }
        func syncMoveEverythingSelectionToFocusedWindowIfNeeded(
            forceFocusedWindowRefresh: Bool = false
        ) {
            _ = syncMoveEverythingControlCenterFocusStateIfNeeded(notifyOnChange: true)

            if isMoveEverythingHoverFocusTransitionInProgress {
                return
            }

            if !forceFocusedWindowRefresh && isMoveEverythingSelectionSyncSuppressed() {
                return
            }

            guard isMoveEverythingActive,
                  var runState = moveEverythingRunState,
                  !runState.windows.isEmpty else {
                return
            }

            refreshMoveEverythingFocusedWindowKeyIfNeeded(force: forceFocusedWindowRefresh)

            // If the focused window wasn't found and this is a forced refresh
            // (hotkey press), check whether we're missing a brand-new window.
            // Refreshing on a cache miss lets newly-opened windows be moved on
            // the very first hotkey press instead of requiring a second one.
            if moveEverythingFocusedWindowKey == nil && forceFocusedWindowRefresh {
                let hasUnmatchedFocusedWindow: Bool = {
                    guard let focused = focusedWindow() else { return false }
                    var pid: pid_t = 0
                    AXUIElementGetPid(focused, &pid)
                    return pid != ProcessInfo.processInfo.processIdentifier
                }()
                if hasUnmatchedFocusedWindow {
                    invalidateMoveEverythingResolvedInventoryCache()
                    pruneMoveEverythingWindows(forceRefreshInventory: true)
                    if let refreshedRunState = moveEverythingRunState,
                       !refreshedRunState.windows.isEmpty {
                        runState = refreshedRunState
                    }
                    refreshMoveEverythingFocusedWindowKeyIfNeeded(force: true)
                }
            }

            guard let focusedKey = moveEverythingFocusedWindowKey,
                  let focusedIndex = runState.windows.firstIndex(where: { $0.key == focusedKey }),
                  focusedIndex != runState.currentIndex else {
                return
            }

            runState.currentIndex = focusedIndex
            moveEverythingRunState = runState
            refreshMoveEverythingOverlayPresentation()
            notifyMoveEverythingModeChanged()
        }
        func refreshMoveEverythingFocusedWindowKeyIfNeeded(force: Bool) {
            guard isMoveEverythingActive,
                  let runState = moveEverythingRunState,
                  !runState.windows.isEmpty else {
                moveEverythingFocusedWindowKey = nil
                moveEverythingFocusedWindowLastCheckAt = nil
                return
            }

            let now = Date()
            if !force,
               let lastCheck = moveEverythingFocusedWindowLastCheckAt,
               now.timeIntervalSince(lastCheck) < moveEverythingFocusedWindowPollingInterval {
                return
            }

            moveEverythingFocusedWindowLastCheckAt = now
            // While a window is hovered (and for 7s after), the hover-raise
            // changes OS focus to the raised window. Don't update the tracked
            // focused key so the focused highlight doesn't jump to whatever
            // was last hovered.
            // While hovering, don't update the focused key — the hover-raise
            // changes OS focus as a side-effect. The pre-hover key is restored
            // when hover ends, and normal polling resumes immediately.
            if moveEverythingHoveredWindowKey != nil { return }
            moveEverythingFocusedWindowKey = moveEverythingFocusedWindowKey(in: runState.windows)
        }
        func moveEverythingFocusedWindowKey(in windows: [MoveEverythingManagedWindow]) -> String? {
            if let focusedAXWindow = focusedWindow() {
                var focusedPID: pid_t = 0
                AXUIElementGetPid(focusedAXWindow, &focusedPID)
                let focusedCandidates = windows.filter { managedWindow in
                    !isMoveEverythingControlCenterWindow(managedWindow) && managedWindow.pid == focusedPID
                }
                if !focusedCandidates.isEmpty {
                    if let focusedWindowNumber = copyIntAttribute(from: focusedAXWindow, attribute: "AXWindowNumber") {
                        let numberedMatches = focusedCandidates.filter { $0.windowNumber == focusedWindowNumber }
                        if let exactNumberedMatch = numberedMatches.first {
                            return exactNumberedMatch.key
                        }
                    }

                    let elementMatches = focusedCandidates.filter { CFEqual($0.window, focusedAXWindow) }
                    if let exactElementMatch = elementMatches.first {
                        return exactElementMatch.key
                    }

                    if let focusedFrame = currentWindowRect(for: focusedAXWindow)?.integral {
                        let frameMatches = focusedCandidates.filter { managedWindow in
                            currentWindowRect(for: managedWindow.window)?.integral == focusedFrame
                        }
                        if frameMatches.count == 1 {
                            return frameMatches[0].key
                        }
                    }
                }
            }

            guard let identity = frontmostLayerZeroWindowIdentity() else {
                return nil
            }
            let identityCandidates = windows.filter { managedWindow in
                !isMoveEverythingControlCenterWindow(managedWindow) && managedWindow.pid == identity.pid
            }
            guard !identityCandidates.isEmpty else {
                return nil
            }

            if let identityWindowNumber = identity.windowNumber {
                return identityCandidates.first(where: { $0.windowNumber == identityWindowNumber })?.key
            }

            if identityCandidates.count == 1 {
                return identityCandidates[0].key
            }

            return nil
        }
        func centeredMoveEverythingRect(for referenceFrame: CGRect) -> CGRect? {
            let screens = sortedScreens()
            guard !screens.isEmpty else {
                return nil
            }

            let screen = screenIntersecting(rect: referenceFrame) ??
                screenContaining(point: CGPoint(x: referenceFrame.midX, y: referenceFrame.midY)) ??
                NSScreen.main ??
                screens.first
            guard let screen else {
                return nil
            }

            let horizontalFraction = min(max(config.settings.moveEverythingCenterWidthPercent / 100, 0.1), 1)
            let verticalFraction = min(max(config.settings.moveEverythingCenterHeightPercent / 100, 0.1), 1)

            let available = screen.visibleFrame
            let width = min(max(available.width * horizontalFraction, 140), available.width)
            let height = min(max(available.height * verticalFraction, 110), available.height)

            let x = available.midX - (width / 2)
            let y = available.midY - (height / 2)
            return CGRect(x: x, y: y, width: width, height: height).integral
        }
        func maximizedMoveEverythingRect(for referenceFrame: CGRect) -> CGRect? {
            let screens = sortedScreens()
            guard !screens.isEmpty else {
                return nil
            }

            let screen = screenIntersecting(rect: referenceFrame) ??
                screenContaining(point: CGPoint(x: referenceFrame.midX, y: referenceFrame.midY)) ??
                NSScreen.main ??
                screens.first
            guard let screen else {
                return nil
            }

            return screen.visibleFrame.integral
        }
        func miniControlCenterMoveEverythingRect(for referenceFrame: CGRect) -> CGRect? {
            let screens = sortedScreens()
            guard !screens.isEmpty else {
                return nil
            }

            let screen = screenIntersecting(rect: referenceFrame) ??
                screenContaining(point: CGPoint(x: referenceFrame.midX, y: referenceFrame.midY)) ??
                NSScreen.main ??
                screens.first
            guard let screen else {
                return nil
            }

            let available = screen.visibleFrame
            let width = min(moveEverythingAdvancedControlCenterWidth, available.width)
            let height = min(moveEverythingAdvancedControlCenterHeight, available.height)
            let x = available.midX - (width / 2)
            let y = available.maxY - height
            return CGRect(x: x, y: y, width: width, height: height).integral
        }
        func moveEverythingAdvancedHoverRect(for referenceFrame: CGRect) -> CGRect? {
            let screens = sortedScreens()
            guard !screens.isEmpty else {
                return nil
            }

            let controlCenterFrame = currentControlCenterFrameForMoveEverything()
            let screen = (controlCenterFrame.flatMap { frame in
                screenIntersecting(rect: frame) ??
                    screenContaining(point: CGPoint(x: frame.midX, y: frame.midY))
            }) ??
                screenIntersecting(rect: referenceFrame) ??
                screenContaining(point: CGPoint(x: referenceFrame.midX, y: referenceFrame.midY)) ??
                NSScreen.main ??
                screens.first
            guard let screen else {
                return nil
            }

            let available = screen.visibleFrame
            if moveEverythingNarrowMode, let controlCenterFrame {
                let clampedMinX = min(max(controlCenterFrame.minX, available.minX), available.maxX)
                let clampedMaxX = max(min(controlCenterFrame.maxX, available.maxX), available.minX)
                let leftWidth = max(clampedMinX - available.minX, 0)
                let rightWidth = max(available.maxX - clampedMaxX, 0)
                let sideWidth = min(
                    max(leftWidth, rightWidth),
                    max(available.width * moveEverythingNarrowModeMaxSideWidthFraction, 1)
                )
                if sideWidth > 0 {
                    let useRightSide = rightWidth >= leftWidth
                    let x = useRightSide ? clampedMaxX : max(available.minX, clampedMinX - sideWidth)
                    return CGRect(
                        x: x,
                        y: available.minY,
                        width: sideWidth,
                        height: available.height
                    ).integral
                }
            }

            let width: CGFloat
            let x: CGFloat
            let topBottomY: CGFloat

            if let controlCenterFrame {
                width = min(max(controlCenterFrame.width, 1), available.width)
                x = min(max(controlCenterFrame.minX, available.minX), available.maxX - width)
                topBottomY = min(max(controlCenterFrame.minY, available.minY), available.maxY)
            } else {
                width = min(moveEverythingAdvancedControlCenterWidth, available.width)
                let topHeight = min(moveEverythingAdvancedControlCenterHeight, available.height)
                topBottomY = available.maxY - topHeight
                x = available.midX - (width / 2)
            }

            let remainingHeight = max(topBottomY - available.minY, 0)
            guard remainingHeight > 0 else {
                return nil
            }

            let y = available.minY
            return CGRect(x: x, y: y, width: width, height: remainingHeight).integral
        }
        func currentControlCenterFrameForMoveEverything() -> CGRect? {
            guard let controlCenterWindow = NSApp.windows.first(where: isControlCenterWindow) else {
                return nil
            }
            let frame = controlCenterWindow.frame
            guard frame.width > 0, frame.height > 0 else {
                return nil
            }
            return frame
        }
        @discardableResult
        func focusMoveEverythingWindow(
            _ managedWindow: MoveEverythingManagedWindow,
            allowAppActivation: Bool = true,
            requireActualFocus: Bool = false
        ) -> Bool {
            if isMoveEverythingControlCenterWindow(managedWindow) {
                ensureControlCenterWindowVisibleForMoveEverything()
                return true
            }

            applyAXMessagingTimeout(to: managedWindow.window, timeout: axFocusMessagingTimeout)
            let raiseStatus = AXUIElementPerformAction(managedWindow.window, kAXRaiseAction as CFString)
            let didRaise = raiseStatus == .success
            if !requireActualFocus && didRaise {
                return true
            }

            let appElement = applicationAXElement(for: managedWindow.pid)
            applyAXMessagingTimeout(to: appElement, timeout: axFocusMessagingTimeout)
            let focusedWindowStatus = AXUIElementSetAttributeValue(
                appElement,
                kAXFocusedWindowAttribute as CFString,
                managedWindow.window
            )
            let didSetFocusedWindow = focusedWindowStatus == .success
            if !requireActualFocus && didSetFocusedWindow {
                return true
            }

            let mainWindowStatus = AXUIElementSetAttributeValue(
                managedWindow.window,
                kAXMainAttribute as CFString,
                kCFBooleanTrue
            )
            let didSetMain = mainWindowStatus == .success
            if !requireActualFocus && didSetMain {
                return true
            }

            let didRequestFocusViaAX = didRaise || didSetFocusedWindow || didSetMain
            if !requireActualFocus && didRequestFocusViaAX {
                return true
            }

            if isMoveEverythingWindowFocused(managedWindow) {
                return true
            }

            guard allowAppActivation,
                  let app = NSRunningApplication(processIdentifier: managedWindow.pid),
                  app.activate(options: [.activateIgnoringOtherApps]) else {
                return false
            }

            if !requireActualFocus {
                return true
            }

            return waitForMoveEverythingWindowToBecomeFocused(managedWindow, timeout: 0.08)
        }
        func resolveMoveEverythingWindowInventory(forceRefresh: Bool = false) -> MoveEverythingManagedWindowInventory {
            let now = Date()
            if let cachedInventory = moveEverythingResolvedInventoryCache {
                if !forceRefresh,
                   let lastRefresh = moveEverythingResolvedInventoryLastRefreshAt,
                   now.timeIntervalSince(lastRefresh) < moveEverythingResolvedInventoryRefreshInterval {
                    return cachedInventory
                }

                if forceRefresh {
                    // If the cache is still fresh (within the normal refresh interval), skip the
                    // expensive synchronous rebuild and let the background timer keep it current.
                    // This prevents main-thread stalls from rapid forceRefresh calls.
                    if let lastRefresh = moveEverythingResolvedInventoryLastRefreshAt,
                       now.timeIntervalSince(lastRefresh) < moveEverythingResolvedInventoryRefreshInterval {
                        requestMoveEverythingInventoryRefreshIfNeeded(force: true)
                        return cachedInventory
                    }
                    let refreshedInventory = resolveMoveEverythingWindowInventorySynchronously(
                        controlCenterWindowNumber: currentControlCenterWindowNumberSnapshot()
                    )
                    moveEverythingResolvedInventoryCache = refreshedInventory
                    moveEverythingResolvedInventoryLastRefreshAt = Date()
                    return refreshedInventory
                }

                requestMoveEverythingInventoryRefreshIfNeeded(force: false)
                return cachedInventory
            }

            if forceRefresh || isMoveEverythingActive {
                let refreshedInventory = resolveMoveEverythingWindowInventorySynchronously(
                    controlCenterWindowNumber: currentControlCenterWindowNumberSnapshot()
                )
                moveEverythingResolvedInventoryCache = refreshedInventory
                moveEverythingResolvedInventoryLastRefreshAt = Date()
                return refreshedInventory
            }

            requestMoveEverythingInventoryRefreshIfNeeded(force: true)
            return MoveEverythingManagedWindowInventory(
                visible: [],
                hidden: [],
                hiddenCoreGraphicsFallback: []
            )
        }
        func requestMoveEverythingInventoryRefreshIfNeeded(force: Bool) {
            let now = Date()
            if !force,
               let lastRefresh = moveEverythingResolvedInventoryLastRefreshAt,
               now.timeIntervalSince(lastRefresh) < moveEverythingResolvedInventoryRefreshInterval {
                return
            }

            if moveEverythingInventoryRefreshInFlight {
                moveEverythingInventoryRefreshQueued = true
                return
            }

            moveEverythingInventoryRefreshInFlight = true
            let revision = moveEverythingInventoryRefreshRevision
            let controlCenterWindowNumber = currentControlCenterWindowNumberSnapshot()

            moveEverythingInventoryRefreshQueue.async { [weak self] in
                guard let self else {
                    return
                }
                let refreshedInventory = self.resolveMoveEverythingWindowInventorySynchronously(
                    controlCenterWindowNumber: controlCenterWindowNumber
                )
                DispatchQueue.main.async { [weak self] in
                    guard let self else {
                        return
                    }

                    self.moveEverythingInventoryRefreshInFlight = false

                    guard revision == self.moveEverythingInventoryRefreshRevision else {
                        let shouldRunQueuedRefresh = self.moveEverythingInventoryRefreshQueued
                        self.moveEverythingInventoryRefreshQueued = false
                        if shouldRunQueuedRefresh {
                            self.requestMoveEverythingInventoryRefreshIfNeeded(force: true)
                        }
                        return
                    }

                    let previousInventory = self.moveEverythingResolvedInventoryCache
                    self.moveEverythingResolvedInventoryCache = refreshedInventory
                    self.moveEverythingResolvedInventoryLastRefreshAt = Date()
                    if !self.moveEverythingManagedWindowInventoryEqual(previousInventory, refreshedInventory) {
                        self.pruneMoveEverythingWindows(liveInventory: refreshedInventory)
                        self.onMoveEverythingInventoryRefreshed?()
                    }

                    let shouldRunQueuedRefresh = self.moveEverythingInventoryRefreshQueued
                    self.moveEverythingInventoryRefreshQueued = false
                    if shouldRunQueuedRefresh {
                        self.requestMoveEverythingInventoryRefreshIfNeeded(force: true)
                    }
                }
            }
        }
        func currentControlCenterWindowNumberSnapshot() -> Int? {
            NSApp.windows.first(where: isControlCenterWindow)?.windowNumber
        }
        func resolveMoveEverythingWindowInventorySynchronously(
            controlCenterWindowNumber: Int?
        ) -> MoveEverythingManagedWindowInventory {
            let startedAt = DispatchTime.now().uptimeNanoseconds
            defer {
                logMoveEverythingPerfIfSlow(
                    "inventory.resolve",
                    startedAt: startedAt,
                    thresholdMs: 70
                )
            }

            let onScreenInfoList = CGWindowListCopyWindowInfo(
                [.optionOnScreenOnly, .excludeDesktopElements],
                kCGNullWindowID
            ) as? [[String: Any]] ?? []
            let allInfoList = CGWindowListCopyWindowInfo(
                [.optionAll, .excludeDesktopElements],
                kCGNullWindowID
            ) as? [[String: Any]] ?? []
            let visibleWindowNumbers: Set<Int> = Set(
                onScreenInfoList.compactMap { info -> Int? in
                    guard let layer = info[kCGWindowLayer as String] as? Int, layer == 0 else {
                        return nil
                    }
                    return info[kCGWindowNumber as String] as? Int
                }
            )
            let hiddenCoreGraphicsFallbackCandidatesByPID = hiddenCoreGraphicsFallbackCandidates(
                from: allInfoList,
                visibleWindowNumbers: visibleWindowNumbers
            )

            var visibleWindowsByNumber: [Int: MoveEverythingManagedWindow] = [:]
            var visibleWindowsWithoutNumber: [MoveEverythingManagedWindow] = []
            var hiddenWindows: [MoveEverythingManagedWindow] = []
            var hiddenCoreGraphicsFallbackWindows: [MoveEverythingCoreGraphicsFallbackWindow] = []
            var hiddenWindowKeys: Set<String> = []
            // Use a short-lived cross-call cache for the osascript iTerm fetch so that
            // multiple rapid inventory rebuilds don't each spawn a new subprocess.
            let iTermFetchCacheValid: Bool = {
                guard let at = moveEverythingITermFetchCacheAt else { return false }
                return Date().timeIntervalSince(at) < moveEverythingITermFetchCacheTTL
            }()
            var cachedITermWindowInventory: [ITermWindowInventoryResolver.WindowDescriptor]? =
                iTermFetchCacheValid ? moveEverythingITermFetchCache : nil

            for app in NSWorkspace.shared.runningApplications {
                if app.isTerminated {
                    continue
                }
                if shouldIgnoreMoveEverythingApplication(app) {
                    continue
                }

                let appName = app.localizedName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                    ? (app.localizedName ?? "App")
                    : "PID \(app.processIdentifier)"
                let bundleIdentifier = app.bundleIdentifier?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let isITermApplication = moveEverythingApplicationLooksLikeITerm(
                    appName: appName,
                    bundleIdentifier: bundleIdentifier
                )
                let iTermWindowInventory: [ITermWindowInventoryResolver.WindowDescriptor] = {
                    guard isITermApplication else {
                        return []
                    }
                    if let cachedITermWindowInventory {
                        return cachedITermWindowInventory
                    }
                    let fetched = ITermWindowInventoryResolver.fetchInventory(
                        debugContext: "inventory pid=\(app.processIdentifier) appName=\(appName)"
                    )
                    cachedITermWindowInventory = fetched
                    moveEverythingITermFetchCache = fetched
                    moveEverythingITermFetchCacheAt = Date()
                    return fetched
                }()
                let appElement = applicationAXElement(for: app.processIdentifier)
                guard let windows = copyWindowList(from: appElement), !windows.isEmpty else {
                    if let fallbackCandidates = hiddenCoreGraphicsFallbackCandidatesByPID[app.processIdentifier] {
                        for candidate in fallbackCandidates {
                            let key = coreGraphicsFallbackWindowKey(
                                pid: app.processIdentifier,
                                windowNumber: candidate.windowNumber
                            )
                            if hiddenWindowKeys.insert(key).inserted {
                                hiddenCoreGraphicsFallbackWindows.append(
                                    MoveEverythingCoreGraphicsFallbackWindow(
                                        key: key,
                                        pid: app.processIdentifier,
                                        windowNumber: candidate.windowNumber,
                                        title: candidate.title,
                                        appName: appName,
                                        bundleIdentifier: bundleIdentifier
                                    )
                                )
                            }
                        }
                    }
                    continue
                }

                for window in windows {
                    let title = copyStringAttribute(from: window, attribute: kAXTitleAttribute)
                    let rects = bothWindowRects(for: window)
                    let frame = rects?.cocoa
                    let rawFrame = rects?.raw
                    let resolvedITermWindow: ITermWindowInventoryResolver.WindowDescriptor? = {
                        guard isITermApplication else {
                            return nil
                        }
                        return ITermWindowInventoryResolver.resolveWindowDescriptor(
                            from: iTermWindowInventory,
                            titleCandidates: [title ?? ""],
                            frame: rawFrame,
                            debugContext:
                                "inventory pid=\(app.processIdentifier) keyCandidate=\(CFHash(window)) " +
                                "title=\(title ?? "") rawFrame=\(rawFrame.map { NSStringFromRect(NSRectFromCGRect($0)) } ?? "nil")"
                        )
                    }()
                    let windowNumber = copyIntAttribute(from: window, attribute: "AXWindowNumber")
                    let iTermWindowID = resolvedITermWindow.map { String($0.id) }
                    let key: String
                    if let windowNumber {
                        key = "\(app.processIdentifier)-\(windowNumber)"
                    } else if let iTermWindowID, !iTermWindowID.isEmpty {
                        key = "\(app.processIdentifier)-iterm-\(iTermWindowID)"
                    } else {
                        // AXWindowNumber is not available for every app; use CFHash(window) as a
                        // stable fallback identifier across repeated AX queries.
                        key = "\(app.processIdentifier)-ax-\(CFHash(window))"
                    }

                    let iTermWindowName: String? = {
                        guard let name = resolvedITermWindow?.name.trimmingCharacters(in: .whitespacesAndNewlines),
                              !name.isEmpty else {
                            return nil
                        }
                        // Only use the iTerm name if it differs from the AX title
                        // (otherwise it's redundant).
                        let normalizedAXTitle = (title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                        return name != normalizedAXTitle ? name : nil
                    }()
                    let managed = MoveEverythingManagedWindow(
                        key: key,
                        pid: app.processIdentifier,
                        windowNumber: windowNumber,
                        iTermWindowID: iTermWindowID,
                        iTermWindowName: iTermWindowName,
                        title: title,
                        appName: appName,
                        bundleIdentifier: bundleIdentifier,
                        window: window
                    )

                    let minimized = isWindowMinimized(window)
                    let hasUsableFrame: Bool = {
                        guard let frame else {
                            return false
                        }
                        return frame.width > 60 && frame.height > 40
                    }()

                    if shouldIgnoreMoveEverythingWindow(managed, frame: frame) {
                        continue
                    }
                    // If the AX window number is present in the CG on-screen set, it's
                    // definitely on screen.  If AXWindowNumber is nil, fall back to
                    // hasUsableFrame.  If the number exists but is NOT in the CG set, also
                    // fall back to hasUsableFrame — some Electron apps (Claude, ChatGPT)
                    // expose an AXWindowNumber that doesn't match any CGWindowNumber, which
                    // would otherwise permanently misclassify them as hidden.
                    let onScreen: Bool
                    if let windowNumber, visibleWindowNumbers.contains(windowNumber) {
                        onScreen = true
                    } else {
                        onScreen = hasUsableFrame
                    }
                    let shouldIncludeInVisible = !app.isHidden && !minimized && hasUsableFrame && onScreen

                    if shouldIncludeInVisible {
                        if let windowNumber {
                            visibleWindowsByNumber[windowNumber] = managed
                        } else {
                            visibleWindowsWithoutNumber.append(managed)
                        }
                    } else {
                        if hiddenWindowKeys.insert(key).inserted {
                            hiddenWindows.append(managed)
                        }
                    }
                }
            }

            let orderedVisible = orderedMoveEverythingVisibleWindows(
                infoList: onScreenInfoList,
                windowsByNumber: visibleWindowsByNumber,
                windowsWithoutNumber: visibleWindowsWithoutNumber,
                controlCenterWindowNumber: controlCenterWindowNumber
            )
            let visibleKeys = Set(orderedVisible.map(\.key))
            hiddenWindows = hiddenWindows.filter { !visibleKeys.contains($0.key) }
            hiddenWindows.sort { left, right in
                let leftApp = left.appName.localizedCaseInsensitiveCompare(right.appName)
                if leftApp != .orderedSame {
                    return leftApp == .orderedAscending
                }
                let leftTitle = (left.title ?? "").localizedCaseInsensitiveCompare(right.title ?? "")
                if leftTitle != .orderedSame {
                    return leftTitle == .orderedAscending
                }
                return left.key < right.key
            }
            hiddenCoreGraphicsFallbackWindows.sort { left, right in
                let leftApp = left.appName.localizedCaseInsensitiveCompare(right.appName)
                if leftApp != .orderedSame {
                    return leftApp == .orderedAscending
                }
                let leftTitle = (left.title ?? "").localizedCaseInsensitiveCompare(right.title ?? "")
                if leftTitle != .orderedSame {
                    return leftTitle == .orderedAscending
                }
                if left.windowNumber != right.windowNumber {
                    return left.windowNumber < right.windowNumber
                }
                return left.key < right.key
            }

            return MoveEverythingManagedWindowInventory(
                visible: orderedVisible,
                hidden: hiddenWindows,
                hiddenCoreGraphicsFallback: hiddenCoreGraphicsFallbackWindows
            )
        }
        func invalidateMoveEverythingResolvedInventoryCache(clearCachedWindows: Bool = false) {
            moveEverythingInventoryRefreshRevision &+= 1
            if clearCachedWindows {
                moveEverythingResolvedInventoryCache = nil
            }
            moveEverythingResolvedInventoryLastRefreshAt = nil
        }
        func startMoveEverythingBackgroundInventoryTimer() {
            guard moveEverythingBackgroundInventoryTimer == nil else {
                return
            }
            let interval = max(config.settings.moveEverythingBackgroundRefreshInterval, 0.5)
            moveEverythingBackgroundInventoryTimer = Timer.scheduledTimer(
                withTimeInterval: interval,
                repeats: true
            ) { [weak self] _ in
                self?.backgroundInventoryRefresh()
            }
        }
        private func backgroundInventoryRefresh() {
            guard isMoveEverythingActive, !moveEverythingInventoryRefreshInFlight else {
                return
            }
            let controlCenterWindowNumber = currentControlCenterWindowNumberSnapshot()
            let revision = moveEverythingInventoryRefreshRevision
            DispatchQueue.global(qos: .utility).async { [weak self] in
                guard let self else { return }
                let refreshedInventory = self.resolveMoveEverythingWindowInventorySynchronously(
                    controlCenterWindowNumber: controlCenterWindowNumber
                )
                DispatchQueue.main.async { [weak self] in
                    guard let self,
                          revision == self.moveEverythingInventoryRefreshRevision else {
                        return
                    }
                    let previousInventory = self.moveEverythingResolvedInventoryCache
                    self.moveEverythingResolvedInventoryCache = refreshedInventory
                    self.moveEverythingResolvedInventoryLastRefreshAt = Date()
                    if !self.moveEverythingManagedWindowInventoryEqual(previousInventory, refreshedInventory) {
                        self.pruneMoveEverythingWindows(liveInventory: refreshedInventory)
                        self.onMoveEverythingInventoryRefreshed?()
                    }
                }
            }
        }
        func stopMoveEverythingBackgroundInventoryTimer() {
            moveEverythingBackgroundInventoryTimer?.invalidate()
            moveEverythingBackgroundInventoryTimer = nil
        }
        func moveEverythingManagedWindowInventoryEqual(
            _ left: MoveEverythingManagedWindowInventory?,
            _ right: MoveEverythingManagedWindowInventory
        ) -> Bool {
            guard let left else {
                return false
            }
            guard left.visible.count == right.visible.count,
                  left.hidden.count == right.hidden.count,
                  left.hiddenCoreGraphicsFallback.count == right.hiddenCoreGraphicsFallback.count else {
                return false
            }

            for (leftWindow, rightWindow) in zip(left.visible, right.visible) {
                if leftWindow.key != rightWindow.key ||
                    leftWindow.title != rightWindow.title {
                    return false
                }
            }
            for (leftWindow, rightWindow) in zip(left.hidden, right.hidden) {
                if leftWindow.key != rightWindow.key ||
                    leftWindow.title != rightWindow.title {
                    return false
                }
            }
            for (leftWindow, rightWindow) in zip(left.hiddenCoreGraphicsFallback, right.hiddenCoreGraphicsFallback) {
                if leftWindow.key != rightWindow.key ||
                    leftWindow.title != rightWindow.title {
                    return false
                }
            }
            return true
        }
        func coreGraphicsFallbackWindowKey(pid: pid_t, windowNumber: Int) -> String {
            "\(pid)-cg-\(windowNumber)"
        }
        func derivedCoreGraphicsFallbackWindowKey(from key: String) -> String? {
            if key.contains("-cg-") {
                return key
            }
            let segments = key.split(separator: "-", omittingEmptySubsequences: false)
            guard segments.count == 2,
                  let pid = Int32(segments[0]),
                  let windowNumber = Int(segments[1]) else {
                return nil
            }
            return coreGraphicsFallbackWindowKey(pid: pid_t(pid), windowNumber: windowNumber)
        }
        func suppressMoveEverythingHiddenWindowVisibility(
            forKey key: String,
            duration: TimeInterval = 2.5
        ) {
            let clampedDuration = max(duration, 0)
            if clampedDuration == 0 {
                moveEverythingHiddenWindowVisibilitySuppressionByKey.removeValue(forKey: key)
                return
            }
            moveEverythingHiddenWindowVisibilitySuppressionByKey[key] = Date().addingTimeInterval(clampedDuration)
        }
        func activeMoveEverythingSuppressedHiddenWindowKeys() -> Set<String> {
            let now = Date()
            moveEverythingHiddenWindowVisibilitySuppressionByKey = moveEverythingHiddenWindowVisibilitySuppressionByKey
                .filter { $0.value > now }
            return Set(moveEverythingHiddenWindowVisibilitySuppressionByKey.keys)
        }
        func hiddenCoreGraphicsFallbackCandidates(
            from infoList: [[String: Any]],
            visibleWindowNumbers: Set<Int>
        ) -> [pid_t: [MoveEverythingCoreGraphicsFallbackCandidate]] {
            var candidatesByPIDAndWindowNumber: [pid_t: [Int: MoveEverythingCoreGraphicsFallbackCandidate]] = [:]

            for info in infoList {
                guard let layer = info[kCGWindowLayer as String] as? Int, layer == 0 else {
                    continue
                }
                guard let ownerPIDNumber = info[kCGWindowOwnerPID as String] as? NSNumber else {
                    continue
                }
                guard let windowNumber = info[kCGWindowNumber as String] as? Int else {
                    continue
                }
                guard !visibleWindowNumbers.contains(windowNumber) else {
                    continue
                }

                let bounds = info[kCGWindowBounds as String] as? [String: Any]
                let width = (bounds?["Width"] as? NSNumber)?.doubleValue ?? 0
                let height = (bounds?["Height"] as? NSNumber)?.doubleValue ?? 0
                guard width > 60, height > 40 else {
                    continue
                }

                let title: String? = {
                    let normalized = (info[kCGWindowName as String] as? String)?
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    return (normalized?.isEmpty == false) ? normalized : nil
                }()

                let pid = pid_t(ownerPIDNumber.int32Value)
                candidatesByPIDAndWindowNumber[pid, default: [:]][windowNumber] =
                    MoveEverythingCoreGraphicsFallbackCandidate(
                        windowNumber: windowNumber,
                        title: title
                    )
            }

            return candidatesByPIDAndWindowNumber.reduce(into: [pid_t: [MoveEverythingCoreGraphicsFallbackCandidate]]()) {
                partialResult,
                item in
                let pid = item.key
                let candidates = item.value.values.sorted { left, right in
                    if left.windowNumber != right.windowNumber {
                        return left.windowNumber < right.windowNumber
                    }
                    return (left.title ?? "") < (right.title ?? "")
                }
                partialResult[pid] = candidates
            }
        }
        func shouldIgnoreMoveEverythingApplication(_ app: NSRunningApplication) -> Bool {
            let currentPID = ProcessInfo.processInfo.processIdentifier
            if app.processIdentifier == currentPID {
                return true
            }

            if app.activationPolicy != .regular {
                return true
            }

            if app.bundleIdentifier == "com.apple.notificationcenterui" {
                return true
            }

            let normalizedName = (app.localizedName ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            return normalizedName == "notification center"
        }
        func moveEverythingApplicationLooksLikeITerm(
            appName: String,
            bundleIdentifier: String?
        ) -> Bool {
            let normalizedAppName = appName
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            let normalizedBundleIdentifier = (bundleIdentifier ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            return normalizedAppName.contains("iterm") ||
                normalizedBundleIdentifier == "com.googlecode.iterm2"
        }
        func shouldManipulateMoveEverythingWindowOnHover(
            _ managedWindow: MoveEverythingManagedWindow
        ) -> Bool {
            !moveEverythingApplicationLooksLikeITerm(
                appName: managedWindow.appName,
                bundleIdentifier: managedWindow.bundleIdentifier
            )
        }
        func shouldIgnoreMoveEverythingWindow(_ managedWindow: MoveEverythingManagedWindow, frame: CGRect?) -> Bool {
            guard managedWindow.appName.caseInsensitiveCompare("Finder") == .orderedSame else {
                return false
            }

            let normalizedTitle = (managedWindow.title ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let isUntitled = normalizedTitle.isEmpty || normalizedTitle.caseInsensitiveCompare("Untitled Window") == .orderedSame
            return isUntitled
        }
        func orderedMoveEverythingVisibleWindows(
            infoList: [[String: Any]],
            windowsByNumber: [Int: MoveEverythingManagedWindow],
            windowsWithoutNumber: [MoveEverythingManagedWindow],
            controlCenterWindowNumber: Int?
        ) -> [MoveEverythingManagedWindow] {
            var ordered: [MoveEverythingManagedWindow] = []
            var seenKeys: Set<String> = []

            for info in infoList {
                guard let ownerPID = info[kCGWindowOwnerPID as String] as? pid_t,
                      let layer = info[kCGWindowLayer as String] as? Int,
                      layer == 0,
                      let windowNumber = info[kCGWindowNumber as String] as? Int,
                      let managed = windowsByNumber[windowNumber],
                      managed.pid == ownerPID else {
                    continue
                }

                if seenKeys.insert(managed.key).inserted {
                    ordered.append(managed)
                }
            }

            for managed in windowsWithoutNumber {
                if seenKeys.insert(managed.key).inserted {
                    ordered.append(managed)
                }
            }

            if let controlCenterIndex = ordered.firstIndex(where: { managedWindow in
                isMoveEverythingControlCenterWindow(
                    managedWindow,
                    controlCenterWindowNumber: controlCenterWindowNumber
                )
            }) {
                let controlCenter = ordered.remove(at: controlCenterIndex)
                ordered.insert(controlCenter, at: 0)
            }

            return ordered
        }
        func isMoveEverythingControlCenterWindow(
            _ managedWindow: MoveEverythingManagedWindow,
            controlCenterWindowNumber: Int? = nil
        ) -> Bool {
            guard managedWindow.pid == ProcessInfo.processInfo.processIdentifier else {
                return false
            }
            if (managedWindow.title ?? "") == "VibeGrid Control Center" {
                return true
            }
            if let controlCenterWindowNumber,
               let managedWindowNumber = managedWindow.windowNumber,
               managedWindowNumber == controlCenterWindowNumber {
                return true
            }
            return false
        }
        func isMoveEverythingControlCenterWindow(_ managedWindow: MoveEverythingManagedWindow) -> Bool {
            guard managedWindow.pid == ProcessInfo.processInfo.processIdentifier else {
                return false
            }
            if (managedWindow.title ?? "") == "VibeGrid Control Center" {
                return true
            }
            if let windowNumber = managedWindow.windowNumber,
               let ownWindow = NSApp.windows.first(where: { $0.windowNumber == windowNumber }) {
                return isControlCenterWindow(ownWindow)
            }
            return false
        }
        func ensureControlCenterWindowVisibleForMoveEverything() {
            guard let window = NSApp.windows.first(where: isControlCenterWindow) else {
                return
            }

            if window.isMiniaturized {
                window.deminiaturize(nil)
            }

            if !window.isVisible {
                window.orderFront(nil)
            }
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
        func closeMoveEverythingWindow(_ managedWindow: MoveEverythingManagedWindow) -> Bool {
            if isMoveEverythingControlCenterWindow(managedWindow) {
                return false
            }

            if managedWindow.pid == ProcessInfo.processInfo.processIdentifier,
               let ownWindow = ownWindow(for: managedWindow) {
                ownWindow.performClose(nil)
                if ownWindow.isVisible {
                    ownWindow.orderOut(nil)
                }
                return true
            }

            return closeAccessibilityWindow(managedWindow.window)
        }
        func hideMoveEverythingWindow(_ managedWindow: MoveEverythingManagedWindow) -> Bool {
            if isMoveEverythingControlCenterWindow(managedWindow) {
                return false
            }

            if managedWindow.pid == ProcessInfo.processInfo.processIdentifier,
               let ownWindow = ownWindow(for: managedWindow) {
                ownWindow.miniaturize(nil)
                return ownWindow.isMiniaturized || !ownWindow.isVisible
            }

            return hideAccessibilityWindow(managedWindow.window, pid: managedWindow.pid)
        }
        func temporarilyPinControlCenterWindowOnTopForMoveEverything() {
            guard isMoveEverythingActive,
                  !(isMoveEverythingAlwaysOnTopEnabledProvider?() ?? false),
                  let window = NSApp.windows.first(where: isControlCenterWindow) else {
                return
            }

            moveEverythingTemporaryControlCenterTopRestoreWorkItem?.cancel()
            moveEverythingTemporaryControlCenterTopRestoreWorkItem = nil

            if window.level.rawValue < NSWindow.Level.statusBar.rawValue {
                window.level = .statusBar
            }

            let workItem = DispatchWorkItem { [weak self, weak window] in
                guard let self else {
                    return
                }
                guard let window else {
                    self.moveEverythingTemporaryControlCenterTopRestoreWorkItem = nil
                    return
                }

                self.moveEverythingTemporaryControlCenterTopRestoreWorkItem = nil
                guard !(self.isMoveEverythingAlwaysOnTopEnabledProvider?() ?? false) else {
                    return
                }
                if window.level.rawValue >= NSWindow.Level.statusBar.rawValue {
                    window.level = .normal
                }
            }

            moveEverythingTemporaryControlCenterTopRestoreWorkItem = workItem
            DispatchQueue.main.asyncAfter(
                deadline: .now() + moveEverythingTemporaryControlCenterTopDuration,
                execute: workItem
            )
        }
        func closeFocusedWindowOutsideMoveEverythingMode() -> Bool {
            if let ownFocusedWindow = frontmostOwnWindow() {
                ownFocusedWindow.performClose(nil)
                if ownFocusedWindow.isVisible {
                    ownFocusedWindow.orderOut(nil)
                }
                return true
            }

            guard let focusedWindow = focusedWindow() else {
                return false
            }
            return closeAccessibilityWindow(focusedWindow)
        }
        func hideFocusedWindowOutsideMoveEverythingMode() -> Bool {
            if let ownFocusedWindow = frontmostOwnWindow() {
                ownFocusedWindow.miniaturize(nil)
                return ownFocusedWindow.isMiniaturized || !ownFocusedWindow.isVisible
            }

            guard let focusedWindow = focusedWindow() else {
                return false
            }

            var pid: pid_t = 0
            AXUIElementGetPid(focusedWindow, &pid)
            return hideAccessibilityWindow(focusedWindow, pid: pid)
        }
        func revealMoveEverythingCoreGraphicsFallbackWindow(
            _ fallbackWindow: MoveEverythingCoreGraphicsFallbackWindow
        ) -> Bool {
            guard let app = NSRunningApplication(processIdentifier: fallbackWindow.pid) else {
                return false
            }

            _ = app.unhide()
            _ = app.activate(options: [.activateIgnoringOtherApps, .activateAllWindows])
            if waitForMoveEverythingCoreGraphicsWindowOnScreen(
                pid: fallbackWindow.pid,
                preferredWindowNumber: fallbackWindow.windowNumber,
                timeout: 0.5
            ) {
                return true
            }

            if requestMoveEverythingApplicationReopen(app),
               let refreshedApp = NSRunningApplication(processIdentifier: fallbackWindow.pid) {
                _ = refreshedApp.unhide()
                _ = refreshedApp.activate(options: [.activateIgnoringOtherApps, .activateAllWindows])
                if waitForMoveEverythingCoreGraphicsWindowOnScreen(
                    pid: fallbackWindow.pid,
                    preferredWindowNumber: nil,
                    timeout: 0.9
                ) {
                    return true
                }
            }

            if NSWorkspace.shared.frontmostApplication?.processIdentifier == fallbackWindow.pid,
               sendMoveEverythingNewWindowShortcut(),
               waitForMoveEverythingCoreGraphicsWindowOnScreen(
                   pid: fallbackWindow.pid,
                   preferredWindowNumber: nil,
                   timeout: 0.9
               ) {
                return true
            }

            return isMoveEverythingCoreGraphicsWindowOnScreen(
                pid: fallbackWindow.pid,
                preferredWindowNumber: nil
            )
        }
        func closeMoveEverythingCoreGraphicsFallbackWindow(
            _ fallbackWindow: MoveEverythingCoreGraphicsFallbackWindow
        ) -> Bool {
            guard let app = NSRunningApplication(processIdentifier: fallbackWindow.pid) else {
                return false
            }
            return app.terminate()
        }
        func waitForMoveEverythingWindowToLoseFocus(
            _ managedWindow: MoveEverythingManagedWindow,
            timeout: TimeInterval
        ) -> Bool {
            let clampedTimeout = max(timeout, 0)
            let deadline = Date().addingTimeInterval(clampedTimeout)
            repeat {
                if !isMoveEverythingWindowFocused(managedWindow) {
                    return true
                }
                _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.03))
            } while Date() < deadline

            return !isMoveEverythingWindowFocused(managedWindow)
        }
        func waitForMoveEverythingCoreGraphicsWindowOnScreen(
            pid: pid_t,
            preferredWindowNumber: Int?,
            timeout: TimeInterval
        ) -> Bool {
            let clampedTimeout = max(timeout, 0)
            let deadline = Date().addingTimeInterval(clampedTimeout)

            repeat {
                if isMoveEverythingCoreGraphicsWindowOnScreen(
                    pid: pid,
                    preferredWindowNumber: preferredWindowNumber
                ) {
                    return true
                }
                _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.06))
            } while Date() < deadline

            return isMoveEverythingCoreGraphicsWindowOnScreen(
                pid: pid,
                preferredWindowNumber: preferredWindowNumber
            )
        }
        func isMoveEverythingCoreGraphicsWindowOnScreen(
            pid: pid_t,
            preferredWindowNumber: Int?
        ) -> Bool {
            let infoList = CGWindowListCopyWindowInfo(
                [.optionOnScreenOnly, .excludeDesktopElements],
                kCGNullWindowID
            ) as? [[String: Any]] ?? []

            var hasAnyLayerZeroWindowForApp = false
            for info in infoList {
                guard let layer = info[kCGWindowLayer as String] as? Int, layer == 0 else {
                    continue
                }
                guard let ownerPIDNumber = info[kCGWindowOwnerPID as String] as? NSNumber,
                      pid_t(ownerPIDNumber.int32Value) == pid else {
                    continue
                }
                guard let windowNumber = info[kCGWindowNumber as String] as? Int else {
                    continue
                }

                hasAnyLayerZeroWindowForApp = true
                if let preferredWindowNumber, windowNumber == preferredWindowNumber {
                    return true
                }
                if preferredWindowNumber == nil {
                    return true
                }
            }

            // If the original window id was recycled but the app now has another layer-0 window
            // on-screen, still treat reopen as successful.
            return hasAnyLayerZeroWindowForApp
        }
        func revealMoveEverythingHiddenWindow(_ managedWindow: MoveEverythingManagedWindow, targetFrame: CGRect?) -> Bool {
            if let app = NSRunningApplication(processIdentifier: managedWindow.pid) {
                _ = app.unhide()
                app.activate(options: [.activateIgnoringOtherApps])
            }

            applyAXMessagingTimeout(to: managedWindow.window)
            let _ = AXUIElementSetAttributeValue(
                managedWindow.window,
                kAXMinimizedAttribute as CFString,
                kCFBooleanFalse
            )

            if let targetFrame {
                _ = setMoveEverythingWindowFrame(managedWindow, cocoaRect: targetFrame)
            }

            _ = focusMoveEverythingWindow(managedWindow)
            return !isWindowMinimized(managedWindow.window)
        }
        func defaultMoveEverythingCenterRect() -> CGRect? {
            guard let screen = NSScreen.main ?? sortedScreens().first else {
                return nil
            }
            return centeredMoveEverythingRect(for: screen.visibleFrame)
        }
        func moveEverythingRetileAvailableFrame(for referenceFrame: CGRect) -> CGRect? {
            let screens = sortedScreens()
            guard !screens.isEmpty else {
                return nil
            }

            let controlCenterFrame = currentControlCenterFrameForMoveEverything()
            let screen = (controlCenterFrame.flatMap { frame in
                screenIntersecting(rect: frame) ??
                    screenContaining(point: CGPoint(x: frame.midX, y: frame.midY))
            }) ??
                screenIntersecting(rect: referenceFrame) ??
                screenContaining(point: CGPoint(x: referenceFrame.midX, y: referenceFrame.midY)) ??
                NSScreen.main ??
                screens.first
            guard let screen else {
                return nil
            }

            let available = screen.visibleFrame.integral
            return MoveEverythingRetileLayout.availableFrame(
                within: available,
                excluding: controlCenterFrame
            )
        }
        func moveEverythingRetileSortPredicate(
            _ left: MoveEverythingManagedWindow,
            _ right: MoveEverythingManagedWindow
        ) -> Bool {
            let appComparison = left.appName.compare(
                right.appName,
                options: [.caseInsensitive, .numeric]
            )
            if appComparison != .orderedSame {
                return appComparison == .orderedAscending
            }

            let leftTitle = moveEverythingWindowTitle(for: left)
            let rightTitle = moveEverythingWindowTitle(for: right)
            let titleComparison = leftTitle.compare(
                rightTitle,
                options: [.caseInsensitive, .numeric]
            )
            if titleComparison != .orderedSame {
                return titleComparison == .orderedAscending
            }

            return left.key.compare(
                right.key,
                options: [.caseInsensitive, .numeric]
            ) == .orderedAscending
        }
        func moveEverythingTiledFrames(
            count: Int,
            availableFrame: CGRect,
            aspectRatio: CGFloat,
            gap: CGFloat
        ) -> [CGRect] {
            guard count > 0,
                  availableFrame.width > 0,
                  availableFrame.height > 0,
                  aspectRatio > 0 else {
                return []
            }

            return MoveEverythingRetileLayout.tiledFrames(
                count: count,
                availableFrame: availableFrame,
                aspectRatio: aspectRatio,
                gap: gap
            )
        }
        func moveEverythingSnapshot(
            for managedWindow: MoveEverythingManagedWindow,
            isCoreGraphicsFallback: Bool = false
        ) -> MoveEverythingWindowSnapshot {
            let rawFrame = rawAXWindowRect(for: managedWindow.window)
            return MoveEverythingWindowSnapshot(
                key: managedWindow.key,
                pid: managedWindow.pid,
                windowNumber: managedWindow.windowNumber,
                iTermWindowID: managedWindow.iTermWindowID,
                frame: rawFrame.map(moveEverythingSnapshotFrame(from:)),
                title: moveEverythingWindowTitle(for: managedWindow),
                appName: managedWindow.appName,
                isControlCenter: isMoveEverythingControlCenterWindow(managedWindow),
                iconDataURL: moveEverythingWindowIconDataURL(for: managedWindow.pid),
                isCoreGraphicsFallback: isCoreGraphicsFallback,
                iTermWindowName: managedWindow.iTermWindowName,
                iTermActivityStatus: nil,
                iTermBadgeText: nil
            )
        }
        func moveEverythingSnapshot(
            for fallbackWindow: MoveEverythingCoreGraphicsFallbackWindow
        ) -> MoveEverythingWindowSnapshot {
            return MoveEverythingWindowSnapshot(
                key: fallbackWindow.key,
                pid: fallbackWindow.pid,
                windowNumber: fallbackWindow.windowNumber,
                iTermWindowID: nil,
                frame: nil,
                title: moveEverythingWindowTitle(for: fallbackWindow),
                appName: fallbackWindow.appName,
                isControlCenter: false,
                iconDataURL: moveEverythingWindowIconDataURL(for: fallbackWindow.pid),
                isCoreGraphicsFallback: true,
                iTermWindowName: nil,
                iTermActivityStatus: nil,
                iTermBadgeText: nil
            )
        }
        func moveEverythingSnapshotFrame(from rect: CGRect) -> MoveEverythingWindowFrameSnapshot {
            MoveEverythingWindowFrameSnapshot(
                x: rect.origin.x,
                y: rect.origin.y,
                width: rect.size.width,
                height: rect.size.height
            )
        }
        func moveEverythingWindowTitle(for managedWindow: MoveEverythingManagedWindow) -> String {
            let normalizedTitle = managedWindow.title?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return normalizedTitle.isEmpty ? "Untitled Window" : normalizedTitle
        }
        func moveEverythingWindowTitle(
            for fallbackWindow: MoveEverythingCoreGraphicsFallbackWindow
        ) -> String {
            let normalizedTitle = fallbackWindow.title?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !normalizedTitle.isEmpty {
                return normalizedTitle
            }
            let normalizedAppName = fallbackWindow.appName.trimmingCharacters(in: .whitespacesAndNewlines)
            if !normalizedAppName.isEmpty {
                return normalizedAppName
            }
            return "Window \(fallbackWindow.windowNumber)"
        }
        func moveEverythingWindowIconDataURL(for pid: pid_t) -> String? {
            if let cached = moveEverythingIconDataURLByPID[pid] {
                return cached
            }

            guard let app = NSRunningApplication(processIdentifier: pid),
                  let icon = app.icon else {
                return nil
            }

            let targetSize = NSSize(width: 20, height: 20)
            let rendered = NSImage(size: targetSize)
            rendered.lockFocus()
            icon.draw(
                in: NSRect(origin: .zero, size: targetSize),
                from: NSRect(origin: .zero, size: icon.size),
                operation: .copy,
                fraction: 1
            )
            rendered.unlockFocus()

            guard let tiff = rendered.tiffRepresentation,
                  let bitmap = NSBitmapImageRep(data: tiff),
                  let pngData = bitmap.representation(using: .png, properties: [:]) else {
                return nil
            }

            let dataURL = "data:image/png;base64,\(pngData.base64EncodedString())"
            moveEverythingIconDataURLByPID[pid] = dataURL
            return dataURL
        }
        func ownWindow(for managedWindow: MoveEverythingManagedWindow) -> NSWindow? {
            if let windowNumber = managedWindow.windowNumber,
               let matchedByNumber = NSApp.windows.first(where: { $0.windowNumber == windowNumber }) {
                return matchedByNumber
            }

            if isMoveEverythingControlCenterWindow(managedWindow) {
                return NSApp.windows.first(where: isControlCenterWindow)
            }

            return nil
        }
        func isControlCenterWindow(_ window: NSWindow) -> Bool {
            window.title == "VibeGrid Control Center"
        }
        var isMoveEverythingHoverFocusTransitionInProgress: Bool {
            moveEverythingHoverFocusTransitionDepth > 0
        }
}

#endif
