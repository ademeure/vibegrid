#if os(macOS)
import AppKit
import ApplicationServices
import Foundation

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

        guard let overlayFrame = currentWindowRect(for: managedWindow.window) else {
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
        guard let managedWindow = moveEverythingOverlayTargetWindow(from: runState) else {
            hideMoveEverythingOverlayVisualOnly()
            return
        }
        guard let overlayPresentation = moveEverythingOverlayPresentation(for: managedWindow) else {
            hideMoveEverythingOverlayVisualOnly()
            return
        }

        guard let frame = currentWindowRect(for: managedWindow.window) else {
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
