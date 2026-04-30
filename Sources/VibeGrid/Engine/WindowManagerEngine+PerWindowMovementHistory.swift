#if os(macOS)
import AppKit
import ApplicationServices
import Foundation

// MARK: - Per-window movement history (focused/hovered scoped undo/redo)
//
// This is a separate system from the global `hotkeyWindowMovement{Undo,Redo}History`
// stack. The global stack is a single linear list of every VibeGrid-led move
// across all windows; "undo" rewinds whichever window was moved last.
//
// The per-window timeline below is keyed by `"{pid}:{windowNumber}"` and tracks
// each window's history independently. The user's `undoWindowMovementForFocusedWindow`
// hotkey rewinds whichever window is currently hovered (in MoveEverything mode)
// or focused. While MoveEverything is active, externally-initiated moves are
// also captured opportunistically via `backgroundInventoryRefresh`, throttled
// to one polled sample per window per 10s.

extension WindowManagerEngine {

    enum PerWindowMovementSource {
        case vibegrid
        case external
    }

    struct PerWindowMovementEntry {
        let frame: CGRect
        let source: PerWindowMovementSource
        let capturedAt: Date
    }

    final class PerWindowMovementTimeline {
        static let entryLimit = 100
        static let polledSampleMinInterval: TimeInterval = 10

        var entries: [PerWindowMovementEntry] = []
        /// Index of the entry the window is currently positioned at. -1 when empty.
        var cursor: Int = -1
        var lastPolledSampleAt: Date?

        var canUndo: Bool { cursor > 0 }
        var canRedo: Bool { cursor >= 0 && cursor < entries.count - 1 }

        /// Append a VibeGrid-led move. Captures `from` as a waypoint when it
        /// differs from the entry currently at the cursor (i.e. the window
        /// was moved by something non-VibeGrid since the last record).
        func appendVibeGridMove(from: CGRect, to: CGRect, now: Date) {
            // If the cursor isn't at the tail (e.g. user undid then made a new
            // move), drop the redo branch — this move starts a new history line.
            if cursor >= 0, cursor < entries.count - 1 {
                entries.removeSubrange((cursor + 1)...)
            }

            let lastFrame = entries.last?.frame
            if let lastFrame {
                if !framesApproxEqual(lastFrame, from) {
                    entries.append(PerWindowMovementEntry(frame: from, source: .external, capturedAt: now))
                }
            } else {
                entries.append(PerWindowMovementEntry(frame: from, source: .external, capturedAt: now))
            }
            entries.append(PerWindowMovementEntry(frame: to, source: .vibegrid, capturedAt: now))
            cursor = entries.count - 1
            cap()
        }

        /// Append a polled (external) sample. Returns true if the sample was
        /// actually appended. The caller is expected to gate on:
        /// - the cursor being at the tail (we never extend a redo branch);
        /// - the per-window 10s minimum interval;
        /// - dedup against the last two entries.
        @discardableResult
        func appendPolledSample(frame: CGRect, now: Date) -> Bool {
            // Cursor not at tail → user has an active redo branch; don't pollute it.
            if cursor >= 0, cursor < entries.count - 1 { return false }
            if let last = lastPolledSampleAt,
               now.timeIntervalSince(last) < PerWindowMovementTimeline.polledSampleMinInterval {
                return false
            }
            let count = entries.count
            if count >= 1, framesApproxEqual(entries[count - 1].frame, frame) { return false }
            if count >= 2, framesApproxEqual(entries[count - 2].frame, frame) { return false }
            entries.append(PerWindowMovementEntry(frame: frame, source: .external, capturedAt: now))
            cursor = entries.count - 1
            lastPolledSampleAt = now
            cap()
            return true
        }

        func undo() -> CGRect? {
            guard canUndo else { return nil }
            cursor -= 1
            return entries[cursor].frame
        }

        func redo() -> CGRect? {
            guard canRedo else { return nil }
            cursor += 1
            return entries[cursor].frame
        }

        private func cap() {
            let limit = PerWindowMovementTimeline.entryLimit
            if entries.count > limit {
                let drop = entries.count - limit
                entries.removeFirst(drop)
                cursor = max(cursor - drop, 0)
            }
        }
    }

    // MARK: - Storage helpers

    fileprivate func perWindowTimelineKey(pid: pid_t, windowNumber: Int) -> String {
        "\(pid):\(windowNumber)"
    }

    fileprivate func perWindowTimelineKey(forTarget target: HotkeyWindowMovementTarget) -> String? {
        guard let windowNumber = target.windowNumber else { return nil }
        return perWindowTimelineKey(pid: target.pid, windowNumber: windowNumber)
    }

    /// Records a VibeGrid-led movement on the per-window timeline. Called from
    /// `recordHotkeyWindowMovement` so every existing placement path picks this
    /// up automatically — separate from (and additive to) the global stack.
    func recordPerWindowMovement(
        target: HotkeyWindowMovementTarget,
        from: CGRect,
        to: CGRect
    ) {
        guard let key = perWindowTimelineKey(forTarget: target) else { return }
        let timeline = perWindowMovementTimelinesByKey[key] ?? PerWindowMovementTimeline()
        timeline.appendVibeGridMove(from: from, to: to, now: Date())
        perWindowMovementTimelinesByKey[key] = timeline
    }

    // MARK: - Polling capture (MoveEverything-only)

    /// Hook called from `backgroundInventoryRefresh` after the inventory cache
    /// has been refreshed. Walks visible/hidden managed windows and records
    /// external positions for any window that already has a timeline entry.
    /// We deliberately don't *create* timelines from polling — a window only
    /// gets a per-window history once VibeGrid touches it.
    func capturePerWindowPollingSamples(from inventory: MoveEverythingManagedWindowInventory) {
        guard isMoveEverythingActive else { return }
        let now = Date()
        var seen: Set<String> = []
        for managed in inventory.visible {
            guard let windowNumber = managed.windowNumber else { continue }
            let key = perWindowTimelineKey(pid: managed.pid, windowNumber: windowNumber)
            seen.insert(key)
            guard let timeline = perWindowMovementTimelinesByKey[key] else { continue }
            guard let frame = currentWindowRect(for: managed.window) else { continue }
            timeline.appendPolledSample(frame: frame, now: now)
        }
        for managed in inventory.hidden {
            guard let windowNumber = managed.windowNumber else { continue }
            seen.insert(perWindowTimelineKey(pid: managed.pid, windowNumber: windowNumber))
        }
        prunePerWindowMovementTimelines(retainedKeys: seen, livePids: livePidSet(from: inventory))
    }

    private func livePidSet(from inventory: MoveEverythingManagedWindowInventory) -> Set<pid_t> {
        var pids: Set<pid_t> = []
        for window in inventory.visible { pids.insert(window.pid) }
        for window in inventory.hidden { pids.insert(window.pid) }
        for window in inventory.hiddenCoreGraphicsFallback { pids.insert(window.pid) }
        return pids
    }

    private func prunePerWindowMovementTimelines(
        retainedKeys: Set<String>,
        livePids: Set<pid_t>
    ) {
        for key in Array(perWindowMovementTimelinesByKey.keys) {
            if retainedKeys.contains(key) { continue }
            // Drop only when the underlying process is gone. A window may
            // briefly disappear from the inventory snapshot (e.g. minimised
            // out-of-band) and we don't want to forget its history then.
            guard let colon = key.firstIndex(of: ":"),
                  let pid = pid_t(key[key.startIndex..<colon]) else {
                perWindowMovementTimelinesByKey.removeValue(forKey: key)
                continue
            }
            if !livePids.contains(pid) {
                perWindowMovementTimelinesByKey.removeValue(forKey: key)
            }
        }
    }

    // MARK: - Undo / redo for the currently-targeted window

    enum PerWindowMovementApplyTarget {
        case own(NSWindow)
        case managed(MoveEverythingManagedWindow)
        case ax(AXUIElement)
    }

    private struct ResolvedPerWindowMovementTarget {
        let key: String
        let apply: PerWindowMovementApplyTarget
    }

    /// Resolves the window the per-window undo/redo hotkey should target.
    /// Hover wins inside MoveEverything mode; falls back to focused window
    /// (own-app first, then external AX focused window) in all other cases.
    private func resolvePerWindowMovementTarget() -> ResolvedPerWindowMovementTarget? {
        if isMoveEverythingActive,
           let hoveredKey = moveEverythingHoveredWindowKey,
           let runState = moveEverythingRunState,
           let managed = runState.windows.first(where: { $0.key == hoveredKey }),
           !isMoveEverythingControlCenterWindow(managed),
           let windowNumber = managed.windowNumber {
            return ResolvedPerWindowMovementTarget(
                key: perWindowTimelineKey(pid: managed.pid, windowNumber: windowNumber),
                apply: .managed(managed)
            )
        }

        if let ownWindow = focusedOwnWindowForPlacementShortcut(allowControlCenterTarget: true) {
            let pid = ProcessInfo.processInfo.processIdentifier
            return ResolvedPerWindowMovementTarget(
                key: perWindowTimelineKey(pid: pid, windowNumber: ownWindow.windowNumber),
                apply: .own(ownWindow)
            )
        }

        if let ax = focusedWindow() {
            var pid: pid_t = 0
            AXUIElementGetPid(ax, &pid)
            guard pid != 0, let windowNumber = resolvedAXWindowNumber(for: ax) else {
                return nil
            }
            return ResolvedPerWindowMovementTarget(
                key: perWindowTimelineKey(pid: pid, windowNumber: windowNumber),
                apply: .ax(ax)
            )
        }

        return nil
    }

    @discardableResult
    func undoPerWindowMovementForCurrentTarget() -> Bool {
        guard let resolved = resolvePerWindowMovementTarget() else {
            NSLog("VibeGrid: per-window undo skipped — no resolvable target window")
            return false
        }
        guard let timeline = perWindowMovementTimelinesByKey[resolved.key] else {
            NSLog("VibeGrid: per-window undo skipped — no history for window %@", resolved.key)
            return false
        }
        guard let frame = timeline.undo() else {
            NSLog("VibeGrid: per-window undo skipped — at start of history for %@", resolved.key)
            return false
        }
        return applyPerWindowMovement(frame: frame, to: resolved.apply)
    }

    @discardableResult
    func redoPerWindowMovementForCurrentTarget() -> Bool {
        guard let resolved = resolvePerWindowMovementTarget() else { return false }
        guard let timeline = perWindowMovementTimelinesByKey[resolved.key] else { return false }
        guard let frame = timeline.redo() else { return false }
        return applyPerWindowMovement(frame: frame, to: resolved.apply)
    }

    private func applyPerWindowMovement(frame: CGRect, to apply: PerWindowMovementApplyTarget) -> Bool {
        switch apply {
        case .own(let window):
            return setOwnWindow(window, cocoaRect: frame)
        case .managed(let managed):
            guard setMoveEverythingWindowFrame(managed, cocoaRect: frame) else { return false }
            syncMoveEverythingRunStateAfterHotkeyMovement(managed, targetFrame: frame)
            return true
        case .ax(let ax):
            return setWindow(ax, cocoaRect: frame)
        }
    }
}

private func framesApproxEqual(_ a: CGRect, _ b: CGRect, tolerance: CGFloat = 1) -> Bool {
    abs(a.origin.x - b.origin.x) <= tolerance &&
        abs(a.origin.y - b.origin.y) <= tolerance &&
        abs(a.size.width - b.size.width) <= tolerance &&
        abs(a.size.height - b.size.height) <= tolerance
}
#endif
