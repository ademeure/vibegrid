#if os(macOS)
import AppKit
import Foundation

@_silgen_name("CGSMainConnectionID")
private func _CGSMainConnectionID() -> Int32

@_silgen_name("CGSOrderWindow")
private func _CGSOrderWindow(_ connection: Int32, _ windowID: UInt32, _ ordering: Int32, _ relativeToWindow: UInt32) -> Int32

@_silgen_name("CGSGetWindowLevel")
private func _CGSGetWindowLevel(_ connection: Int32, _ windowID: UInt32, _ level: UnsafeMutablePointer<Int32>) -> Int32

@_silgen_name("CGSSetWindowLevel")
private func _CGSSetWindowLevel(_ connection: Int32, _ windowID: UInt32, _ level: Int32) -> Int32

private let kCGSOrderAbove: Int32 = 1

/// Manages a pool of transparent overlay windows that show activity status
/// (green = active, red = idle) on top of iTerm windows running Claude Code or Codex.
final class ITermActivityOverlayController {
    private static let moveGracePeriod: TimeInterval = 0.7
    private static let activeHoldDuration: TimeInterval = 7.0

    struct TrackedWindow {
        let key: String
        let frame: CGRect
        let isActive: Bool
        let hasRecentUserInput: Bool
        let windowNumber: Int?
        let overlayOpacity: Double
    }

    private var overlaysByKey: [String: PlacementPreviewOverlayController] = [:]
    private var lastMovedAt: [String: Date] = [:]
    private var previousFrames: [String: CGRect] = [:]
    private var lastActiveAt: [String: Date] = [:]

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
        for key in lastActiveAt.keys where !activeKeys.contains(key) {
            lastActiveAt.removeValue(forKey: key)
        }

        // Track frame changes and active timestamps
        for window in windows {
            if let prev = previousFrames[window.key], !prev.equalTo(window.frame) {
                lastMovedAt[window.key] = now
            }
            previousFrames[window.key] = window.frame

            if window.isActive {
                lastActiveAt[window.key] = now
            }
        }

        // Show/update overlays
        let conn = _CGSMainConnectionID()
        for window in windows {
            if window.overlayOpacity <= 0 || isSuppressed(window: window, now: now) {
                overlaysByKey[window.key]?.hide()
                overlaysByKey.removeValue(forKey: window.key)
                continue
            }

            let overlay = overlaysByKey[window.key] ?? PlacementPreviewOverlayController()
            overlaysByKey[window.key] = overlay

            // Active if currently active OR was active within the hold duration
            let isEffectivelyActive = window.isActive ||
                (lastActiveAt[window.key].map { now.timeIntervalSince($0) < Self.activeHoldDuration } ?? false)

            let baseColor: NSColor = isEffectivelyActive ? .systemGreen : .systemRed
            let borderAlpha = CGFloat(window.overlayOpacity)
            let fillAlpha = CGFloat(window.overlayOpacity * 0.23)
            overlay.applyFrameAndColors(
                frame: window.frame,
                borderColor: baseColor.withAlphaComponent(borderAlpha),
                fillColor: baseColor.withAlphaComponent(fillAlpha)
            )

            // Match the overlay's window level to the target's level + 1,
            // so it stays above the target even when hover-elevated.
            if let targetWindowNumber = window.windowNumber,
               let overlayWindowNumber = overlay.nsWindowNumber {
                var targetLevel: Int32 = 0
                _ = _CGSGetWindowLevel(conn, UInt32(targetWindowNumber), &targetLevel)
                _ = _CGSSetWindowLevel(conn, UInt32(overlayWindowNumber), targetLevel + 1)
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
        lastActiveAt.removeAll()
    }

    private func isSuppressed(window: TrackedWindow, now: Date) -> Bool {
        if window.hasRecentUserInput {
            return true
        }

        if let movedAt = lastMovedAt[window.key],
           now.timeIntervalSince(movedAt) < Self.moveGracePeriod {
            return true
        }

        return false
    }
}

#endif
