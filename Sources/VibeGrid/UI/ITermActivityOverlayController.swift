#if os(macOS)
import AppKit
import Foundation

// CGS private API for ordering overlay windows relative to iTerm windows.
@_silgen_name("CGSMainConnectionID")
private func _CGSMainConnectionID() -> Int32

@_silgen_name("CGSOrderWindow")
private func _CGSOrderWindow(_ connection: Int32, _ windowID: UInt32, _ ordering: Int32, _ relativeToWindow: UInt32) -> Int32

private let kCGSOrderAbove: Int32 = 1

/// Manages a pool of transparent overlay windows that show activity status
/// (green = active, red = idle) on top of iTerm windows running Claude Code or Codex.
/// Each overlay is z-ordered just above its target iTerm window so that any other
/// window naturally sits on top.
final class ITermActivityOverlayController {
    private static let moveGracePeriod: TimeInterval = 0.7

    struct TrackedWindow {
        let key: String
        let frame: CGRect  // Cocoa coordinates (bottom-left origin)
        let isActive: Bool
        let hasRecentUserInput: Bool  // user typed into this window within 15s
        let windowNumber: Int?  // macOS window number of the target iTerm window
    }

    private var overlaysByKey: [String: PlacementPreviewOverlayController] = [:]
    private var lastMovedAt: [String: Date] = [:]
    private var previousFrames: [String: CGRect] = [:]

    func update(windows: [TrackedWindow]) {
        let now = Date()
        let activeKeys = Set(windows.map(\.key))

        // Clean up state for removed windows
        for key in overlaysByKey.keys where !activeKeys.contains(key) {
            overlaysByKey[key]?.hide()
            overlaysByKey.removeValue(forKey: key)
        }
        for key in lastMovedAt.keys where !activeKeys.contains(key) {
            lastMovedAt.removeValue(forKey: key)
        }
        for key in previousFrames.keys where !activeKeys.contains(key) {
            previousFrames.removeValue(forKey: key)
        }

        // Track frame changes
        for window in windows {
            if let prev = previousFrames[window.key], !prev.equalTo(window.frame) {
                lastMovedAt[window.key] = now
            }
            previousFrames[window.key] = window.frame
        }

        // Show/update overlays
        let conn = _CGSMainConnectionID()
        for window in windows {
            if isSuppressed(window: window, now: now) {
                overlaysByKey[window.key]?.hide()
                overlaysByKey.removeValue(forKey: window.key)
                continue
            }

            let overlay = overlaysByKey[window.key] ?? PlacementPreviewOverlayController()
            overlaysByKey[window.key] = overlay
            let style: PlacementPreviewOverlayController.Style = window.isActive
                ? .activityActive
                : .activityIdle

            let justOrderedIn = overlay.applyFrameAndStyle(frame: window.frame, style: style)

            // CGS-order above the target iTerm window. We do this every cycle
            // because focusing the iTerm window raises it above the overlay.
            // Unlike orderFrontRegardless, CGSOrderWindow only positions
            // relative to the target — it won't push above unrelated windows.
            if let targetWindowNumber = window.windowNumber,
               let overlayWindowNumber = overlay.nsWindowNumber {
                _ = _CGSOrderWindow(
                    conn,
                    UInt32(overlayWindowNumber),
                    kCGSOrderAbove,
                    UInt32(targetWindowNumber)
                )
            }
        }
    }

    func hideAll() {
        for overlay in overlaysByKey.values {
            overlay.hide()
        }
        overlaysByKey.removeAll()
        lastMovedAt.removeAll()
        previousFrames.removeAll()
    }

    private func isSuppressed(window: TrackedWindow, now: Date) -> Bool {
        // Suppress if user recently typed into this window
        if window.hasRecentUserInput {
            return true
        }

        // Grace period after window moved
        if let movedAt = lastMovedAt[window.key],
           now.timeIntervalSince(movedAt) < Self.moveGracePeriod {
            return true
        }

        return false
    }
}

#endif
