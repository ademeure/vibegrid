#if os(macOS)
import AppKit
import Foundation

extension WindowManagerEngine {

    @discardableResult
    func setProxyHover(
        gatingFocusPid: pid_t,
        gatingFocusWindowNumber: Int?,
        gatingFocusITermWindowID: String?,
        targetPid: pid_t?,
        targetWindowNumber: Int?,
        targetITermWindowID: String?,
        targetITermTTY: String?,
        durationSeconds: TimeInterval
    ) -> ProxyHoverSetResult {
        let clampedDuration = min(
            max(durationSeconds, ProxyHoverAPIServer.minDurationSeconds),
            ProxyHoverAPIServer.maxDurationSeconds
        )
        let expiresAt = Date().addingTimeInterval(clampedDuration)
        proxyHoverEntriesByGatingPid[gatingFocusPid] = ProxyHoverEntry(
            gatingFocusPid: gatingFocusPid,
            gatingFocusWindowNumber: gatingFocusWindowNumber,
            gatingFocusITermWindowID: gatingFocusITermWindowID,
            targetPid: targetPid,
            targetWindowNumber: targetWindowNumber,
            targetITermWindowID: targetITermWindowID,
            targetITermTTY: targetITermTTY,
            expiresAt: expiresAt
        )
        startProxyHoverEvaluationIfNeeded()
        evaluateProxyHover()
        let applied = proxyHoverActiveGatingPid == gatingFocusPid
            && proxyHoverActiveWindowKey != nil
        return ProxyHoverSetResult(
            accepted: true,
            applied: applied,
            reason: applied ? nil : explainInactiveReason(
                gatingFocusPid: gatingFocusPid,
                gatingFocusWindowNumber: gatingFocusWindowNumber,
                gatingFocusITermWindowID: gatingFocusITermWindowID
            ),
            expiresAt: expiresAt,
            resolvedWindowKey: applied ? proxyHoverActiveWindowKey : nil
        )
    }

    @discardableResult
    func clearProxyHover(gatingFocusPid: pid_t) -> Bool {
        let wasPresent = proxyHoverEntriesByGatingPid.removeValue(forKey: gatingFocusPid) != nil
        evaluateProxyHover()
        return wasPresent
    }

    func clearAllProxyHover() {
        proxyHoverEntriesByGatingPid.removeAll()
        evaluateProxyHover()
    }

    func currentProxyHoverSnapshot() -> [[String: Any]] {
        let now = Date()
        return proxyHoverEntriesByGatingPid.values.compactMap { entry -> [String: Any]? in
            guard entry.expiresAt > now else { return nil }
            var dict: [String: Any] = [
                "gatingFocusPid": Int(entry.gatingFocusPid),
                "expiresAt": ISO8601DateFormatter().string(from: entry.expiresAt),
                "remainingSeconds": max(0, entry.expiresAt.timeIntervalSince(now)),
                "active": entry.gatingFocusPid == proxyHoverActiveGatingPid
            ]
            if let n = entry.gatingFocusWindowNumber { dict["gatingFocusWindowNumber"] = n }
            if let id = entry.gatingFocusITermWindowID { dict["gatingFocusITermWindowID"] = id }
            if let n = entry.targetPid { dict["targetPid"] = Int(n) }
            if let n = entry.targetWindowNumber { dict["targetWindowNumber"] = n }
            if let id = entry.targetITermWindowID { dict["targetITermWindowID"] = id }
            if let tty = entry.targetITermTTY { dict["targetITermTTY"] = tty }
            return dict
        }
    }

    private func startProxyHoverEvaluationIfNeeded() {
        if proxyHoverEvaluationTimer == nil {
            let timer = Timer.scheduledTimer(
                withTimeInterval: proxyHoverEvaluationInterval,
                repeats: true
            ) { [weak self] _ in
                self?.evaluateProxyHover()
            }
            RunLoop.main.add(timer, forMode: .common)
            proxyHoverEvaluationTimer = timer
        }
        if proxyHoverFrontmostObserver == nil {
            let observer = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didActivateApplicationNotification,
                object: nil,
                queue: OperationQueue.main
            ) { [weak self] _ in
                self?.evaluateProxyHover()
            }
            proxyHoverFrontmostObserver = observer
        }
    }

    private func stopProxyHoverEvaluationIfIdle() {
        guard proxyHoverEntriesByGatingPid.isEmpty else { return }
        proxyHoverEvaluationTimer?.invalidate()
        proxyHoverEvaluationTimer = nil
        if let observer = proxyHoverFrontmostObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            proxyHoverFrontmostObserver = nil
        }
    }

    func evaluateProxyHover() {
        let now = Date()
        proxyHoverEntriesByGatingPid = proxyHoverEntriesByGatingPid.filter { _, entry in
            entry.expiresAt > now
        }

        let frontmostPid = NSWorkspace.shared.frontmostApplication?.processIdentifier
        if let frontmostPid {
            proxyHoverLastFrontmostByPid[frontmostPid] = now
        }

        let activeEntry: ProxyHoverEntry? = {
            // Find a candidate entry whose gating pid is either the current
            // frontmost OR was frontmost within the recency grace window.
            // The grace window absorbs brief focus blips caused by our own
            // overlay/control-center windows momentarily becoming key.
            let candidatePid: pid_t? = {
                if let frontmostPid, proxyHoverEntriesByGatingPid[frontmostPid] != nil {
                    return frontmostPid
                }
                let cutoff = now.addingTimeInterval(-proxyHoverFrontmostGraceInterval)
                return proxyHoverEntriesByGatingPid.keys.first { pid in
                    if let lastSeen = proxyHoverLastFrontmostByPid[pid], lastSeen >= cutoff {
                        return true
                    }
                    return false
                }
            }()
            guard let candidatePid,
                  let candidate = proxyHoverEntriesByGatingPid[candidatePid] else {
                return nil
            }
            // Gating-window match still uses the current frontmost — only the
            // pid-level check is relaxed by recency. If the user has switched
            // to a wholly different window (no current frontmost or different
            // app entirely), gatingWindowMatches will correctly fail.
            let gateAgainstPid = frontmostPid ?? candidatePid
            guard gatingWindowMatches(candidate, frontmostPid: gateAgainstPid) else {
                return nil
            }
            return candidate
        }()

        if let entry = activeEntry {
            proxyHoverActiveGatingPid = entry.gatingFocusPid
            applyProxyHover(entry: entry)
        } else if proxyHoverActiveGatingPid != nil || proxyHoverActiveWindowKey != nil {
            proxyHoverActiveGatingPid = nil
            releaseProxyHover()
        }

        if proxyHoverEntriesByGatingPid.isEmpty {
            stopProxyHoverEvaluationIfIdle()
        }
    }

    private func gatingWindowMatches(_ entry: ProxyHoverEntry, frontmostPid: pid_t) -> Bool {
        if entry.gatingFocusWindowNumber == nil && entry.gatingFocusITermWindowID == nil {
            return true
        }
        guard let identity = frontmostLayerZeroWindowIdentity(),
              identity.pid == frontmostPid else {
            NSLog("VibeGrid proxy-hover gating: no layer-0 identity for frontmostPid=%d", frontmostPid)
            return false
        }
        if let expected = entry.gatingFocusWindowNumber {
            let ok = identity.windowNumber == expected
            if !ok {
                NSLog("VibeGrid proxy-hover gating: windowNumber mismatch frontmost=%@ expected=%d",
                      identity.windowNumber.map(String.init) ?? "nil", expected)
            }
            return ok
        }
        if let expectedITermID = entry.gatingFocusITermWindowID {
            guard let frontmostNumber = identity.windowNumber else {
                NSLog("VibeGrid proxy-hover gating: frontmost layer-0 has no windowNumber (iTermID=%@)",
                      expectedITermID)
                return false
            }
            if let runState = moveEverythingRunState,
               let match = runState.windows.first(where: { $0.iTermWindowID == expectedITermID }),
               let matchNumber = match.windowNumber {
                let ok = matchNumber == frontmostNumber
                if !ok {
                    NSLog("VibeGrid proxy-hover gating: runState mismatch iTermID=%@ resolved=%d frontmost=%d",
                          expectedITermID, matchNumber, frontmostNumber)
                }
                return ok
            }
            // Fall back to on-demand iTerm lookup when the engine inventory
            // hasn't enumerated iTerm windows yet.
            if let matchedNumber = resolveITermWindowNumber(iTermID: expectedITermID) {
                let ok = matchedNumber == frontmostNumber
                if !ok {
                    let inventory = resolveMoveEverythingWindowInventory(forceRefresh: false)
                    let known = (inventory.visible + inventory.hidden)
                        .compactMap { $0.iTermWindowID }
                        .joined(separator: ",")
                    NSLog("VibeGrid proxy-hover gating: inventory mismatch iTermID=%@ resolved=%d frontmost=%d knownIDs=[%@]",
                          expectedITermID, matchedNumber, frontmostNumber, known)
                }
                return ok
            }
            let inventory = resolveMoveEverythingWindowInventory(forceRefresh: false)
            let known = (inventory.visible + inventory.hidden)
                .compactMap { $0.iTermWindowID }
                .joined(separator: ",")
            NSLog("VibeGrid proxy-hover gating: iTermID=%@ not found in inventory (frontmost=%d knownIDs=[%@])",
                  expectedITermID, frontmostNumber, known)
            return false
        }
        return false
    }

    private func applyProxyHover(entry: ProxyHoverEntry) {
        if !isMoveEverythingActive {
            switch startMoveEverythingModeSilentForProxyHover() {
            case .started:
                proxyHoverStartedMoveEverythingMode = true
            case .failed, .stopped:
                return
            }
        }

        guard let runState = moveEverythingRunState else { return }

        guard let target = resolveTargetWindow(entry: entry, in: runState),
              !isMoveEverythingControlCenterWindow(target) else {
            releaseProxyHover()
            return
        }

        if proxyHoverActiveWindowKey == target.key,
           moveEverythingHoveredWindowKey == target.key {
            return
        }

        clearMoveEverythingHoveredWindowLock()
        // Suppress focus-stealing side effects (NSApp.activate etc.) for the
        // duration of the hover-set + overlay-show. The gating app must keep
        // focus or the very next eval tick will see frontmost != gating pid
        // and release the hover.
        proxyHoverSuppressFocusEffects = true
        _ = setMoveEverythingHoveredWindow(withKey: target.key)
        lockMoveEverythingHoveredWindow(target.key)
        showMoveEverythingOverlay(for: target)
        proxyHoverSuppressFocusEffects = false

        if var runState = moveEverythingRunState,
           let targetIndex = runState.windows.firstIndex(where: { $0.key == target.key }) {
            runState.currentIndex = targetIndex
            moveEverythingRunState = runState
        }

        proxyHoverActiveWindowKey = target.key
        notifyMoveEverythingModeChanged()
    }

    private func resolveTargetWindow(
        entry: ProxyHoverEntry,
        in runState: MoveEverythingRunState
    ) -> MoveEverythingManagedWindow? {
        if let iTermID = entry.targetITermWindowID {
            if let match = runState.windows.first(where: { $0.iTermWindowID == iTermID }) {
                return match
            }
            return nil
        }
        if let tty = entry.targetITermTTY {
            guard let iTermID = resolveITermWindowID(forTTY: tty) else { return nil }
            return runState.windows.first(where: { $0.iTermWindowID == iTermID })
        }
        guard let pid = entry.targetPid else { return nil }
        if let number = entry.targetWindowNumber {
            return runState.windows.first(where: { $0.pid == pid && $0.windowNumber == number })
        }
        return runState.windows.first(where: { $0.pid == pid })
    }

    private func releaseProxyHover() {
        let hadActive = proxyHoverActiveWindowKey != nil
        proxyHoverActiveWindowKey = nil

        if hadActive {
            if let runState = moveEverythingRunState {
                clearMoveEverythingHoveredWindowState(in: runState)
            } else {
                clearMoveEverythingHoveredWindowLock()
                moveEverythingHoveredWindowKey = nil
            }
            hideMoveEverythingOverlayVisualOnly()
        }

        if proxyHoverStartedMoveEverythingMode {
            proxyHoverStartedMoveEverythingMode = false
            let controlCenterVisible = NSApp.windows.first(where: isControlCenterWindow)?.isVisible == true
            if !controlCenterVisible {
                stopMoveEverythingMode(notify: true)
            } else if hadActive {
                notifyMoveEverythingModeChanged()
            }
        } else if hadActive {
            notifyMoveEverythingModeChanged()
        }
    }

    private func explainInactiveReason(
        gatingFocusPid: pid_t,
        gatingFocusWindowNumber: Int?,
        gatingFocusITermWindowID: String?
    ) -> String? {
        guard let frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier else {
            return "no frontmost application"
        }
        if frontmost != gatingFocusPid {
            return "gatingFocusPid is not the frontmost application"
        }
        if gatingFocusWindowNumber != nil || gatingFocusITermWindowID != nil {
            return "frontmost window does not match the requested gating window"
        }
        return "target window not yet resolved in Move Everything inventory"
    }

    /// Equivalent to `startMoveEverythingMode()` but without making the
    /// Control Center visible and without stealing focus from the current
    /// app. Used by the proxy-hover API so a caller can pin a hover on a
    /// target window while the user keeps typing in the gating app.
    func startMoveEverythingModeSilentForProxyHover() -> MoveEverythingToggleResult {
        invalidateMoveEverythingResolvedInventoryCache()
        let managedWindows = resolveMoveEverythingWindowInventory(forceRefresh: true).visible
        guard !managedWindows.isEmpty else {
            return .failed("No visible windows were found.")
        }

        var statesByWindowKey: [String: MoveEverythingWindowState] = [:]
        for managedWindow in managedWindows {
            guard let frame = currentWindowRect(for: managedWindow.window) else { continue }
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
        moveEverythingLastRetileUndoRecord = nil
        moveEverythingPendingHideVisibleSuppressionByKey.removeAll()
        isMoveEverythingActive = true
        moveEverythingControlCenterFocusedLastKnown = isMoveEverythingControlCenterFocused()
        restorePinnedWindowsFromStore()

        if !hotkeysSuspendedForCapture {
            registerEnabledHotkeys()
        }
        notifyMoveEverythingModeChanged()
        startMoveEverythingBackgroundInventoryTimer()

        moveEverythingOverlay.prepare()
        moveEverythingBottomOverlay.prepare()
        moveEverythingOriginalPositionOverlay.prepare()
        refreshMoveEverythingOverlayPresentation()

        return .started
    }

    // MARK: - iTerm TTY lookup

    private static let iTermTTYCacheTTL: TimeInterval = 1.5

    private struct ITermTTYCacheEntry {
        let ttyByITermID: [String: String]
        let iTermIDByTTY: [String: String]
        let capturedAt: Date
    }

    private func currentITermTTYCache() -> ITermTTYCacheEntry? {
        guard let cache = proxyHoverITermTTYCache as? ITermTTYCacheEntry,
              Date().timeIntervalSince(cache.capturedAt) < Self.iTermTTYCacheTTL else {
            return nil
        }
        return cache
    }

    private func refreshITermTTYCache() -> ITermTTYCacheEntry? {
        guard let raw = runITermTTYQueryOSAScript() else { return nil }
        var ttyByID: [String: String] = [:]
        var idByTTY: [String: String] = [:]
        for entry in raw {
            let id = entry.id.trimmingCharacters(in: .whitespacesAndNewlines)
            let tty = entry.tty.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty, !tty.isEmpty else { continue }
            ttyByID[id] = tty
            idByTTY[tty] = id
        }
        let cache = ITermTTYCacheEntry(
            ttyByITermID: ttyByID,
            iTermIDByTTY: idByTTY,
            capturedAt: Date()
        )
        proxyHoverITermTTYCache = cache
        return cache
    }

    private func resolveITermWindowID(forTTY tty: String) -> String? {
        if let cache = currentITermTTYCache(), let id = cache.iTermIDByTTY[tty] {
            return id
        }
        return refreshITermTTYCache()?.iTermIDByTTY[tty]
    }

    private func resolveITermWindowNumber(iTermID: String) -> Int? {
        if let runState = moveEverythingRunState,
           let managed = runState.windows.first(where: { $0.iTermWindowID == iTermID }) {
            return managed.windowNumber
        }
        // Bootstrap fallback: gating runs BEFORE applyProxyHover starts
        // move-everything mode, so on the very first request runState is nil
        // and the inventory cache is cold. forceRefresh:true here ensures the
        // first call builds the inventory synchronously — without it, an empty
        // inventory is returned and async-refreshed, but every subsequent POST
        // races the same cold-cache window and gating never resolves
        // (bootstrap deadlock). The cache makes subsequent calls cheap.
        let inventory = resolveMoveEverythingWindowInventory(forceRefresh: true)
        let allWindows = inventory.visible + inventory.hidden
        return allWindows.first(where: { $0.iTermWindowID == iTermID })?.windowNumber
    }

    private struct ITermTTYRaw {
        let id: String
        let tty: String
    }

    private func runITermTTYQueryOSAScript() -> [ITermTTYRaw]? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = [
            "-e",
            """
            tell application "iTerm2"
              set output to ""
              repeat with w in windows
                try
                  set s to current session of w
                  -- Use (ASCII character 9) instead of `tab`: inside this
                  -- tell block, `tab` resolves to iTerm2's tab class, not
                  -- a tab character, producing the literal string "tab".
                  set output to output & (id of w as text) & (ASCII character 9) & (tty of s as text) & linefeed
                end try
              end repeat
              return output
            end tell
            """
        ]
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        do {
            try process.run()
        } catch {
            NSLog("VibeGrid proxy-hover TTY query failed to launch: %@", error.localizedDescription)
            return nil
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            return nil
        }
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        var rows: [ITermTTYRaw] = []
        for line in text.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            let parts = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            rows.append(ITermTTYRaw(id: String(parts[0]), tty: String(parts[1])))
        }
        return rows
    }
}
#endif
