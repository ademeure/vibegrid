#if os(macOS)
import AppKit
import ApplicationServices
import Foundation

// CGS private API for z-order manipulation of pinned overlays.
@_silgen_name("CGSMainConnectionID")
private func _CGSMainConnectionID_Overlays() -> Int32

@_silgen_name("CGSGetWindowLevel")
private func _CGSGetWindowLevel_Overlays(_ connection: Int32, _ windowID: UInt32, _ level: UnsafeMutablePointer<Int32>) -> Int32

@_silgen_name("CGSSetWindowLevel")
private func _CGSSetWindowLevel_Overlays(_ connection: Int32, _ windowID: UInt32, _ level: Int32) -> Int32

@_silgen_name("CGSOrderWindow")
private func _CGSOrderWindow_Overlays(_ connection: Int32, _ windowID: UInt32, _ ordering: Int32, _ relativeToWindow: UInt32) -> Int32

// MARK: - Overlay presentation, sync, and management

extension WindowManagerEngine {

    // MARK: - Overlay presentation logic

    func moveEverythingOverlayPresentation(
        for managedWindow: MoveEverythingManagedWindow
    ) -> PlacementPreviewOverlayController.Style? {
        guard isMoveEverythingActive else {
            return nil
        }

        guard moveEverythingShowOverlays else {
            return nil
        }

        guard !isMoveEverythingControlCenterWindow(managedWindow) else {
            return nil
        }

        if let hoveredKey = moveEverythingHoveredWindowKey,
           hoveredKey == managedWindow.key {
            return .moveEverythingHover
        }

        return nil
    }

    func normalizedMoveEverythingOverlayDuration() -> TimeInterval {
        min(max(config.settings.moveEverythingOverlayDuration, 0.2), 8)
    }

    func clearMoveEverythingExternalFocusOverlayState() {
    }

    // MARK: - Show/hide overlay methods

    func showMoveEverythingOverlay(for managedWindow: MoveEverythingManagedWindow) {
        startMoveEverythingOverlaySyncTimerIfNeeded()

        guard let overlayPresentation = moveEverythingOverlayPresentation(for: managedWindow) else {
            hideMoveEverythingOverlayVisualOnly()
            return
        }

        // Use fast timeout for hover overlays to avoid stalling the main thread
        // when the target app is slow to respond to AX queries.
        let isHover = overlayPresentation == .moveEverythingHover
        guard let overlayFrame = currentWindowRect(
            for: managedWindow.window,
            timeout: isHover ? axFocusMessagingTimeout : nil
        ) else {
            hideMoveEverythingOverlayVisualOnly()
            return
        }
        let normalizedOverlayFrame = overlayFrame.integral
        let useTimedOverlay = overlayPresentation == .moveEverythingHover
            ? false
            : (config.settings.moveEverythingOverlayMode == .timed)

        if useTimedOverlay {
            moveEverythingOverlayLastFrame = normalizedOverlayFrame
            moveEverythingOverlay.show(
                frame: normalizedOverlayFrame,
                style: overlayPresentation,
                duration: normalizedMoveEverythingOverlayDuration()
            )
            refreshMoveEverythingSupplementalOverlays(for: managedWindow)
            return
        }

        moveEverythingOverlayLastFrame = normalizedOverlayFrame
        moveEverythingOverlay.showPersistent(frame: normalizedOverlayFrame, style: overlayPresentation)
        refreshMoveEverythingSupplementalOverlays(for: managedWindow)
        startMoveEverythingOverlaySyncTimerIfNeeded()
    }

    func hideMoveEverythingOverlayVisualOnly() {
        moveEverythingOverlayLastFrame = nil
        moveEverythingOverlay.hide()
        hideMoveEverythingSupplementalOverlays()
    }

    func hideMoveEverythingOverlay() {
        stopMoveEverythingOverlaySyncTimer()
        moveEverythingOverlayLastFrame = nil
        moveEverythingOverlay.hide()
        hideMoveEverythingSupplementalOverlays()
        hideAllMoveEverythingPinnedOverlays()
    }

    func hideMoveEverythingSupplementalOverlays() {
        moveEverythingBottomOverlayLastFrame = nil
        moveEverythingOriginalPositionOverlayLastFrame = nil
        moveEverythingBottomOverlay.hide()
        moveEverythingOriginalPositionOverlay.hide()
    }

    // MARK: - Supplemental overlay management

    func moveEverythingSupplementalOverlayFrames(
        for managedWindow: MoveEverythingManagedWindow
    ) -> (bottom: CGRect, original: CGRect)? {
        guard isMoveEverythingActive,
              moveEverythingShowOverlays,
              shouldApplyMoveEverythingAdvancedHoverLayout(to: managedWindow),
              let hoveredKey = moveEverythingHoveredWindowKey,
              hoveredKey == managedWindow.key,
              let originalFrame = moveEverythingHoverAdvancedOriginalFrameByWindowKey[managedWindow.key] else {
            return nil
        }

        let bottomFrame = (currentWindowRect(for: managedWindow.window) ??
            moveEverythingAdvancedHoverRect(for: originalFrame))?.integral
        guard let bottomFrame else {
            return nil
        }

        return (bottom: bottomFrame, original: originalFrame.integral)
    }

    func refreshMoveEverythingSupplementalOverlays(for managedWindow: MoveEverythingManagedWindow) {
        guard let frames = moveEverythingSupplementalOverlayFrames(for: managedWindow) else {
            hideMoveEverythingSupplementalOverlays()
            return
        }

        let didUpdateBottom = moveEverythingBottomOverlayLastFrame != frames.bottom
        if didUpdateBottom {
            moveEverythingBottomOverlayLastFrame = frames.bottom
            moveEverythingBottomOverlay.showPersistent(
                frame: frames.bottom,
                style: .moveEverythingHoverBottom
            )
        }

        let shouldRefreshOriginal = didUpdateBottom ||
            moveEverythingOriginalPositionOverlayLastFrame != frames.original
        if shouldRefreshOriginal {
            moveEverythingOriginalPositionOverlayLastFrame = frames.original
            moveEverythingOriginalPositionOverlay.showPersistent(
                frame: frames.original,
                style: .moveEverythingHoverOriginal
            )
        }
    }

    func refreshMoveEverythingOverlayPresentation() {
        guard isMoveEverythingActive else {
            hideMoveEverythingOverlay()
            return
        }

        guard let runState = moveEverythingRunState,
              let targetWindow = moveEverythingOverlayTargetWindow(from: runState) else {
            hideMoveEverythingOverlay()
            return
        }

        startMoveEverythingOverlaySyncTimerIfNeeded()
        showMoveEverythingOverlay(for: targetWindow)
    }

    // MARK: - Pinned window overlays

    func refreshMoveEverythingPinnedOverlays() {
        guard isMoveEverythingActive, moveEverythingPinMode else {
            hideAllMoveEverythingPinnedOverlays()
            return
        }

        guard let runState = moveEverythingRunState else {
            hideAllMoveEverythingPinnedOverlays()
            return
        }

        var activeKeys = Set<String>()

        // Show overlays for CC if pinned
        if moveEverythingDontMoveVibeGrid,
           let ccFrame = currentControlCenterFrameForMoveEverything() {
            let ccKey = "__controlCenter__"
            activeKeys.insert(ccKey)
            let overlay = moveEverythingPinnedOverlaysByKey[ccKey] ?? PlacementPreviewOverlayController()
            moveEverythingPinnedOverlaysByKey[ccKey] = overlay
            overlay.showPersistent(frame: ccFrame.integral, style: .moveEverythingPinned)
        }

        // Show overlays for pinned windows
        for key in moveEverythingPinnedWindowKeys {
            guard let window = runState.windows.first(where: { $0.key == key }),
                  let frame = currentWindowRect(for: window.window),
                  frame.width > 0, frame.height > 0 else {
                continue
            }
            activeKeys.insert(key)
            let overlay = moveEverythingPinnedOverlaysByKey[key] ?? PlacementPreviewOverlayController()
            moveEverythingPinnedOverlaysByKey[key] = overlay
            overlay.showPersistent(frame: frame.integral, style: .moveEverythingPinned)

            // Position overlay just above the target window using CGS
            if let windowNumber = window.windowNumber,
               let overlayWindowNumber = overlay.nsWindowNumber {
                positionPinnedOverlay(overlayWindowNumber, above: windowNumber)
            }
        }

        // Clean up overlays for windows no longer pinned
        for key in moveEverythingPinnedOverlaysByKey.keys where !activeKeys.contains(key) {
            moveEverythingPinnedOverlaysByKey[key]?.hide()
            moveEverythingPinnedOverlaysByKey.removeValue(forKey: key)
        }
    }

    func hideAllMoveEverythingPinnedOverlays() {
        for overlay in moveEverythingPinnedOverlaysByKey.values {
            overlay.hide()
        }
        moveEverythingPinnedOverlaysByKey.removeAll()
    }

    private func positionPinnedOverlay(_ overlayWindowNumber: Int, above targetWindowNumber: Int) {
        let conn = _CGSMainConnectionID_Overlays()
        var targetLevel: Int32 = 0
        _ = _CGSGetWindowLevel_Overlays(conn, UInt32(targetWindowNumber), &targetLevel)
        _ = _CGSSetWindowLevel_Overlays(conn, UInt32(overlayWindowNumber), targetLevel + 1)
        _ = _CGSOrderWindow_Overlays(
            conn,
            UInt32(overlayWindowNumber),
            1, // kCGSOrderAbove
            UInt32(targetWindowNumber)
        )
    }

    // MARK: - Overlay sync timer

    func startMoveEverythingOverlaySyncTimerIfNeeded() {
        guard moveEverythingOverlaySyncTimer == nil else {
            return
        }

        let timer = Timer(timeInterval: moveEverythingOverlaySyncInterval, repeats: true) { [weak self] _ in
            self?.syncMoveEverythingOverlayFrameIfNeeded()
        }
        RunLoop.main.add(timer, forMode: .common)
        moveEverythingOverlaySyncTimer = timer
    }

    func stopMoveEverythingOverlaySyncTimer() {
        moveEverythingOverlaySyncTimer?.invalidate()
        moveEverythingOverlaySyncTimer = nil
    }

    func syncMoveEverythingOverlayFrameIfNeeded() {
        syncMoveEverythingSelectionToFocusedWindowIfNeeded()

        guard isMoveEverythingActive,
              let runState = moveEverythingRunState else {
            hideMoveEverythingOverlay()
            return
        }

        // Refresh pinned overlays regardless of whether a primary overlay
        // target exists — pinned windows may have moved even when nothing
        // is hovered.
        if moveEverythingPinMode {
            refreshMoveEverythingPinnedOverlays()
        }

        guard let managedWindow = moveEverythingOverlayTargetWindow(from: runState) else {
            hideMoveEverythingOverlayVisualOnly()
            return
        }
        guard let overlayPresentation = moveEverythingOverlayPresentation(for: managedWindow) else {
            hideMoveEverythingOverlayVisualOnly()
            return
        }

        // Use fast timeout for sync polling — this fires every 20ms and must not
        // stall the main thread if the target app is slow to respond.
        guard let frame = currentWindowRect(for: managedWindow.window, timeout: axFocusMessagingTimeout) else {
            hideMoveEverythingOverlayVisualOnly()
            return
        }
        let normalizedFrame = frame.integral
        let didUpdatePrimaryFrame = moveEverythingOverlayLastFrame != normalizedFrame
        moveEverythingOverlayLastFrame = normalizedFrame
        let useTimedOverlay = overlayPresentation == .moveEverythingHover
            ? false
            : (config.settings.moveEverythingOverlayMode == .timed)

        if didUpdatePrimaryFrame && useTimedOverlay {
            moveEverythingOverlay.show(
                frame: normalizedFrame,
                style: overlayPresentation,
                duration: normalizedMoveEverythingOverlayDuration()
            )
        } else if didUpdatePrimaryFrame {
            switch config.settings.moveEverythingOverlayMode {
            case .persistent:
                moveEverythingOverlay.showPersistent(frame: normalizedFrame, style: overlayPresentation)
            case .timed:
                moveEverythingOverlay.show(
                    frame: normalizedFrame,
                    style: overlayPresentation,
                    duration: normalizedMoveEverythingOverlayDuration()
                )
            }
        }

        refreshMoveEverythingSupplementalOverlays(for: managedWindow)
    }
}

#endif
