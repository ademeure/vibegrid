#if os(macOS)
import AppKit
import ApplicationServices
import Foundation

// MARK: - Accessibility (AX) helpers

extension WindowManagerEngine {
    private static let firefoxBundleIdentifiers: Set<String> = [
        "org.mozilla.firefox",
        "org.mozilla.firefoxdeveloperedition",
        "org.mozilla.nightly",
    ]

    enum AXFrameWriteOrder: String {
        case sizeThenPosition = "size->position"
        case positionThenSize = "position->size"
    }

    // MARK: - AX element queries

    func copyWindowList(from appElement: AXUIElement) -> [AXUIElement]? {
        applyAXMessagingTimeout(to: appElement)
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &value)
        guard status == .success, let windows = value as? [AXUIElement], !windows.isEmpty else {
            return nil
        }
        return windows
    }

    func focusedWindow() -> AXUIElement? {
        if let focusedApp = focusedApplicationFromSystemWide(),
           let focusedWindow = preferredFocusedWindow(from: focusedApp) {
            return focusedWindow
        }

        guard let frontmostApp = frontmostApplicationElement() else {
            return nil
        }

        return preferredFocusedWindow(from: frontmostApp)
    }

    func preferredFocusedWindow(from appElement: AXUIElement) -> AXUIElement? {
        if let focused = copyAXElementAttribute(from: appElement, attribute: kAXFocusedWindowAttribute),
           let resolved = resolvedMovableWindowElement(from: focused) {
            return resolved
        }
        if let main = copyAXElementAttribute(from: appElement, attribute: kAXMainWindowAttribute),
           let resolved = resolvedMovableWindowElement(from: main) {
            return resolved
        }
        return firstUsableWindow(from: appElement)
    }

    func resolvedMovableWindowElement(from element: AXUIElement) -> AXUIElement? {
        if currentWindowRect(for: element) != nil {
            return element
        }

        let candidateAttributes = [
            kAXWindowAttribute as String,
            kAXTopLevelUIElementAttribute as String,
        ]
        for attribute in candidateAttributes {
            if let candidate = copyAXElementAttribute(from: element, attribute: attribute),
               currentWindowRect(for: candidate) != nil {
                return candidate
            }
        }

        var visitedHashes: Set<UInt> = [CFHash(element)]
        var current: AXUIElement? = element
        var remainingDepth = 7
        while remainingDepth > 0,
              let currentElement = current,
              let parent = copyAXElementAttribute(from: currentElement, attribute: kAXParentAttribute) {
            let parentHash = CFHash(parent)
            if visitedHashes.contains(parentHash) {
                break
            }
            visitedHashes.insert(parentHash)
            if currentWindowRect(for: parent) != nil {
                return parent
            }
            current = parent
            remainingDepth -= 1
        }

        return nil
    }

    func currentWindowRect(for window: AXUIElement) -> CGRect? {
        // Apply timeout once for both attribute reads instead of per-attribute.
        applyAXMessagingTimeout(to: window)
        guard let axPosition = copyCGPointAttributeRaw(window: window, attribute: kAXPositionAttribute),
              let axSize = copyCGSizeAttributeRaw(window: window, attribute: kAXSizeAttribute) else {
            return nil
        }
        return cocoaRect(fromAXPosition: axPosition, size: axSize)
    }

    func rawAXWindowRect(for window: AXUIElement) -> CGRect? {
        // Apply timeout once for both attribute reads instead of per-attribute.
        applyAXMessagingTimeout(to: window)
        guard let axPosition = copyCGPointAttributeRaw(window: window, attribute: kAXPositionAttribute),
              let axSize = copyCGSizeAttributeRaw(window: window, attribute: kAXSizeAttribute) else {
            return nil
        }
        return CGRect(origin: axPosition, size: axSize)
    }

    /// Read position and size once and return both the raw AX rect and the Cocoa rect.
    /// Avoids the double AX reads that happen when calling both currentWindowRect and rawAXWindowRect.
    func bothWindowRects(for window: AXUIElement) -> (cocoa: CGRect, raw: CGRect)? {
        applyAXMessagingTimeout(to: window)
        guard let axPosition = copyCGPointAttributeRaw(window: window, attribute: kAXPositionAttribute),
              let axSize = copyCGSizeAttributeRaw(window: window, attribute: kAXSizeAttribute) else {
            return nil
        }
        let raw = CGRect(origin: axPosition, size: axSize)
        let cocoa = cocoaRect(fromAXPosition: axPosition, size: axSize)
        return (cocoa: cocoa, raw: raw)
    }

    // MARK: - Copy attribute helpers

    func copyCGPointAttribute(window: AXUIElement, attribute: String) -> CGPoint? {
        applyAXMessagingTimeout(to: window)
        return copyCGPointAttributeRaw(window: window, attribute: attribute)
    }

    /// Read a CGPoint attribute without applying messaging timeout (caller must ensure it).
    private func copyCGPointAttributeRaw(window: AXUIElement, attribute: String) -> CGPoint? {
        guard let axValue = copyAXValueAttributeRaw(from: window, attribute: attribute) else {
            return nil
        }
        var point = CGPoint.zero
        guard AXValueGetValue(axValue, .cgPoint, &point) else {
            return nil
        }
        return point
    }

    func copyCGSizeAttribute(window: AXUIElement, attribute: String) -> CGSize? {
        applyAXMessagingTimeout(to: window)
        return copyCGSizeAttributeRaw(window: window, attribute: attribute)
    }

    /// Read a CGSize attribute without applying messaging timeout (caller must ensure it).
    private func copyCGSizeAttributeRaw(window: AXUIElement, attribute: String) -> CGSize? {
        guard let axValue = copyAXValueAttributeRaw(from: window, attribute: attribute) else {
            return nil
        }
        var size = CGSize.zero
        guard AXValueGetValue(axValue, .cgSize, &size) else {
            return nil
        }
        return size
    }

    func copyAXValueAttribute(from element: AXUIElement, attribute: String) -> AXValue? {
        applyAXMessagingTimeout(to: element)
        return copyAXValueAttributeRaw(from: element, attribute: attribute)
    }

    /// Read an AXValue attribute without applying messaging timeout (caller must ensure it).
    private func copyAXValueAttributeRaw(from element: AXUIElement, attribute: String) -> AXValue? {
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard status == .success,
              let value,
              CFGetTypeID(value) == AXValueGetTypeID() else {
            return nil
        }
        return (value as! AXValue)
    }

    func copyIntAttribute(from element: AXUIElement, attribute: String) -> Int? {
        applyAXMessagingTimeout(to: element)
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard status == .success,
              let number = value as? NSNumber else {
            return nil
        }
        return number.intValue
    }

    func copyStringAttribute(from element: AXUIElement, attribute: String) -> String? {
        applyAXMessagingTimeout(to: element)
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard status == .success else {
            return nil
        }
        if let stringValue = value as? String {
            return stringValue
        }
        if let attributedStringValue = value as? NSAttributedString {
            return attributedStringValue.string
        }
        return nil
    }

    func copyAXElementAttribute(from element: AXUIElement, attribute: String) -> AXUIElement? {
        applyAXMessagingTimeout(to: element)
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard status == .success,
              let value,
              CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return nil
        }
        return (value as! AXUIElement)
    }

    func copyAXElementArrayAttribute(from element: AXUIElement, attribute: String) -> [AXUIElement]? {
        applyAXMessagingTimeout(to: element)
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard status == .success,
              let elements = value as? [AXUIElement],
              !elements.isEmpty else {
            return nil
        }
        return elements
    }

    // MARK: - Window manipulation

    func setWindow(_ window: AXUIElement, cocoaRect: CGRect) -> Bool {
        let targetWindow = resolvedMovableWindowElement(from: window) ?? window
        let isFirefoxWindow = isFirefoxWindow(targetWindow)
        if isFirefoxWindow {
            logFirefoxFrameAttempt(
                stage: "begin",
                window: targetWindow,
                targetRect: cocoaRect,
                details: "resolvedTarget=\(targetWindow !== window)"
            )
        }

        let didApply = applyWindowFrame(
            targetWindow,
            cocoaRect: cocoaRect,
            writeOrder: .positionThenSize,
            enableVerboseLogging: isFirefoxWindow
        )
        guard didApply else {
            return false
        }

        if isFirefoxWindow,
           let finalRect = currentWindowRect(for: targetWindow),
           windowFrameNeedsCorrection(finalRect, targetRect: cocoaRect) {
            logFirefoxFrameAttempt(
                stage: "retry-scheduled",
                window: targetWindow,
                targetRect: cocoaRect,
                details: "finalRect=\(describe(rect: finalRect)) delaysMs=[300,600]"
            )
            scheduleFirefoxFrameRetries(window: targetWindow, cocoaRect: cocoaRect)
        }

        return true
    }

    func applyWindowFrame(
        _ targetWindow: AXUIElement,
        cocoaRect: CGRect,
        writeOrder: AXFrameWriteOrder,
        enableVerboseLogging: Bool
    ) -> Bool {
        var axPos = axPosition(fromCocoaRect: cocoaRect)
        var size = cocoaRect.size

        guard let positionValue = AXValueCreate(.cgPoint, &axPos),
              let sizeValue = AXValueCreate(.cgSize, &size) else {
            return false
        }

        applyAXMessagingTimeout(to: targetWindow)
        let sizeStatus: AXError
        let positionStatus: AXError
        switch writeOrder {
        case .sizeThenPosition:
            sizeStatus = AXUIElementSetAttributeValue(targetWindow, kAXSizeAttribute as CFString, sizeValue)
            positionStatus = AXUIElementSetAttributeValue(targetWindow, kAXPositionAttribute as CFString, positionValue)
        case .positionThenSize:
            positionStatus = AXUIElementSetAttributeValue(targetWindow, kAXPositionAttribute as CFString, positionValue)
            sizeStatus = AXUIElementSetAttributeValue(targetWindow, kAXSizeAttribute as CFString, sizeValue)
        }
        if enableVerboseLogging {
            logFirefoxFrameAttempt(
                stage: "initial-write",
                window: targetWindow,
                targetRect: cocoaRect,
                details: "order=\(writeOrder.rawValue) sizeStatus=\(describe(axError: sizeStatus)) positionStatus=\(describe(axError: positionStatus))"
            )
        }

        if positionStatus != .success || sizeStatus != .success {
            let fallbackPositionStatus = AXUIElementSetAttributeValue(
                targetWindow,
                kAXPositionAttribute as CFString,
                positionValue
            )
            let fallbackSizeStatus = AXUIElementSetAttributeValue(
                targetWindow,
                kAXSizeAttribute as CFString,
                sizeValue
            )
            if enableVerboseLogging {
                logFirefoxFrameAttempt(
                    stage: "fallback-write",
                    window: targetWindow,
                    targetRect: cocoaRect,
                    details: "order=\(writeOrder.rawValue) sizeStatus=\(describe(axError: fallbackSizeStatus)) positionStatus=\(describe(axError: fallbackPositionStatus))"
                )
            }
            guard fallbackPositionStatus == .success, fallbackSizeStatus == .success else {
                return false
            }
        }

        let tolerance: CGFloat = 1
        if let initialRect = currentWindowRect(for: targetWindow) {
            if enableVerboseLogging {
                logFirefoxFrameAttempt(
                    stage: "post-initial-read",
                    window: targetWindow,
                    targetRect: cocoaRect,
                    details: "rect=\(describe(rect: initialRect))"
                )
            }
            let initialSizeDrifted =
                abs(initialRect.width - cocoaRect.width) > tolerance ||
                abs(initialRect.height - cocoaRect.height) > tolerance

            if initialSizeDrifted {
                let retrySizeStatus = AXUIElementSetAttributeValue(
                    targetWindow,
                    kAXSizeAttribute as CFString,
                    sizeValue
                )
                if enableVerboseLogging {
                    logFirefoxFrameAttempt(
                        stage: "size-correction",
                        window: targetWindow,
                        targetRect: cocoaRect,
                        details: "status=\(describe(axError: retrySizeStatus))"
                    )
                }
            }
        }

        if let correctedRect = currentWindowRect(for: targetWindow) {
            if enableVerboseLogging {
                logFirefoxFrameAttempt(
                    stage: "post-size-read",
                    window: targetWindow,
                    targetRect: cocoaRect,
                    details: "rect=\(describe(rect: correctedRect))"
                )
            }
            let correctedPositionDrifted =
                abs(correctedRect.minX - cocoaRect.minX) > tolerance ||
                abs(correctedRect.minY - cocoaRect.minY) > tolerance

            if correctedPositionDrifted {
                let retryPositionStatus = AXUIElementSetAttributeValue(
                    targetWindow,
                    kAXPositionAttribute as CFString,
                    positionValue
                )
                if enableVerboseLogging {
                    logFirefoxFrameAttempt(
                        stage: "position-correction",
                        window: targetWindow,
                        targetRect: cocoaRect,
                        details: "status=\(describe(axError: retryPositionStatus))"
                    )
                }
            }
        }

        if enableVerboseLogging, let finalRect = currentWindowRect(for: targetWindow) {
            logFirefoxFrameAttempt(
                stage: "final-read",
                window: targetWindow,
                targetRect: cocoaRect,
                details: "rect=\(describe(rect: finalRect))"
            )
        }

        return true
    }

    func setOwnWindow(_ window: NSWindow, cocoaRect: CGRect) -> Bool {
        guard window.isVisible else {
            return false
        }
        window.setFrame(cocoaRect, display: true, animate: false)
        return true
    }

    func setMoveEverythingWindowFrame(
        _ managedWindow: MoveEverythingManagedWindow,
        cocoaRect: CGRect
    ) -> Bool {
        if managedWindow.pid == ProcessInfo.processInfo.processIdentifier,
           let ownWin = ownWindow(for: managedWindow) {
            return setOwnWindow(ownWin, cocoaRect: cocoaRect)
        }
        return setWindow(managedWindow.window, cocoaRect: cocoaRect)
    }

    // MARK: - Application AX elements

    func applicationAXElement(for pid: pid_t) -> AXUIElement {
        let appElement = AXUIElementCreateApplication(pid)
        applyAXMessagingTimeout(to: appElement)
        return appElement
    }

    func systemWideAXElement() -> AXUIElement {
        let systemWide = AXUIElementCreateSystemWide()
        applyAXMessagingTimeout(to: systemWide)
        return systemWide
    }

    func focusedApplicationFromSystemWide() -> AXUIElement? {
        copyAXElementAttribute(from: systemWideAXElement(), attribute: kAXFocusedApplicationAttribute)
    }

    func frontmostApplicationElement() -> AXUIElement? {
        guard let app = NSWorkspace.shared.frontmostApplication else {
            return nil
        }
        return applicationAXElement(for: app.processIdentifier)
    }

    // MARK: - Coordinate conversion

    var desktopFrame: CGRect {
        if let cached = cachedDesktopFrame,
           cachedDesktopFrameScreenCount == NSScreen.screens.count {
            return cached
        }
        let frame = NSScreen.screens.reduce(CGRect.null) { partial, screen in
            partial.union(screen.frame)
        }
        cachedDesktopFrame = frame
        cachedDesktopFrameScreenCount = NSScreen.screens.count
        return frame
    }

    func cocoaRect(fromAXPosition position: CGPoint, size: CGSize) -> CGRect {
        let desktop = desktopFrame
        let y = desktop.maxY - position.y - size.height
        return CGRect(x: position.x, y: y, width: size.width, height: size.height)
    }

    func axPosition(fromCocoaRect rect: CGRect) -> CGPoint {
        let desktop = desktopFrame
        return CGPoint(x: rect.minX, y: desktop.maxY - rect.maxY)
    }

    // MARK: - Screen management

    func screenIntersecting(rect: CGRect) -> NSScreen? {
        let intersections = NSScreen.screens.map { screen -> (NSScreen, CGFloat) in
            let area = rect.intersection(screen.frame).area
            return (screen, area)
        }

        if let best = intersections.max(by: { $0.1 < $1.1 }), best.1 > 0 {
            return best.0
        }

        return screenContaining(point: CGPoint(x: rect.midX, y: rect.midY))
    }

    func screenContaining(point: CGPoint) -> NSScreen? {
        NSScreen.screens.first { screen in
            screen.frame.contains(point)
        }
    }

    func sortedScreens() -> [NSScreen] {
        NSScreen.screens.sorted {
            if $0.frame.minX == $1.frame.minX {
                return $0.frame.minY < $1.frame.minY
            }
            return $0.frame.minX < $1.frame.minX
        }
    }

    func screenByOffset(baseScreen: NSScreen, offset: Int, in screens: [NSScreen]) -> NSScreen {
        guard !screens.isEmpty, let baseIndex = screens.firstIndex(of: baseScreen), offset > 0 else {
            return baseScreen
        }
        let resolved = (baseIndex + offset) % screens.count
        return screens[resolved]
    }

    // MARK: - AX timeout

    func applyAXMessagingTimeout(to element: AXUIElement, timeout: Float? = nil) {
        _ = AXUIElementSetMessagingTimeout(element, timeout ?? axMessagingTimeout)
    }

    // MARK: - Window queries

    func firstUsableWindow(from appElement: AXUIElement) -> AXUIElement? {
        applyAXMessagingTimeout(to: appElement)
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &value)
        guard status == .success, let windows = value as? [AXUIElement], !windows.isEmpty else {
            return nil
        }

        for window in windows {
            if isWindowMinimized(window) {
                continue
            }
            if currentWindowRect(for: window) != nil {
                return window
            }
        }

        return windows.first
    }

    func isWindowMinimized(_ window: AXUIElement) -> Bool {
        applyAXMessagingTimeout(to: window)
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &value)
        guard status == .success, let boolValue = value as? Bool else {
            return false
        }
        return boolValue
    }

    func frontmostOwnWindow() -> NSWindow? {
        let currentPID = ProcessInfo.processInfo.processIdentifier
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == currentPID else {
            return nil
        }
        return NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first { $0.isVisible }
    }

    func scheduleFirefoxFrameRetries(window: AXUIElement, cocoaRect: CGRect) {
        let retryKey = firefoxFrameRetryKey(for: window)
        firefoxFrameRetryWorkItemsByKey[retryKey]?.forEach { $0.cancel() }

        let retryPlan: [(Int, AXFrameWriteOrder)] = [
            (300, .sizeThenPosition),
            (600, .positionThenSize),
        ]
        let workItems: [DispatchWorkItem] = retryPlan.map { delayMs, writeOrder in
            let workItem = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.logFirefoxFrameAttempt(
                    stage: "retry-fired",
                    window: window,
                    targetRect: cocoaRect,
                    details: "delayMs=\(delayMs) order=\(writeOrder.rawValue)"
                )
                _ = self.applyWindowFrame(
                    window,
                    cocoaRect: cocoaRect,
                    writeOrder: writeOrder,
                    enableVerboseLogging: true
                )
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(delayMs), execute: workItem)
            return workItem
        }
        firefoxFrameRetryWorkItemsByKey[retryKey] = workItems
    }

    func firefoxFrameRetryKey(for window: AXUIElement) -> String {
        let pidDescription = processIdentifier(for: window).map(String.init) ?? "?"
        return "\(pidDescription)-\(CFHash(window))"
    }

    func processIdentifier(for window: AXUIElement) -> pid_t? {
        var pid: pid_t = 0
        let status = AXUIElementGetPid(window, &pid)
        guard status == .success, pid > 0 else {
            return nil
        }
        return pid
    }

    func bundleIdentifier(for window: AXUIElement) -> String? {
        guard let pid = processIdentifier(for: window) else {
            return nil
        }
        return NSRunningApplication(processIdentifier: pid)?.bundleIdentifier?.lowercased()
    }

    func isFirefoxWindow(_ window: AXUIElement) -> Bool {
        guard let bundleIdentifier = bundleIdentifier(for: window) else {
            return false
        }
        return Self.firefoxBundleIdentifiers.contains(bundleIdentifier)
    }

    func windowFrameNeedsCorrection(_ currentRect: CGRect, targetRect: CGRect) -> Bool {
        let tolerance: CGFloat = 1
        return abs(currentRect.minX - targetRect.minX) > tolerance ||
            abs(currentRect.minY - targetRect.minY) > tolerance ||
            abs(currentRect.width - targetRect.width) > tolerance ||
            abs(currentRect.height - targetRect.height) > tolerance
    }

    func describe(axError: AXError) -> String {
        switch axError {
        case .success: return "success"
        case .failure: return "failure"
        case .illegalArgument: return "illegalArgument"
        case .invalidUIElement: return "invalidUIElement"
        case .invalidUIElementObserver: return "invalidUIElementObserver"
        case .cannotComplete: return "cannotComplete"
        case .attributeUnsupported: return "attributeUnsupported"
        case .actionUnsupported: return "actionUnsupported"
        case .notificationUnsupported: return "notificationUnsupported"
        case .notImplemented: return "notImplemented"
        case .notificationAlreadyRegistered: return "notificationAlreadyRegistered"
        case .notificationNotRegistered: return "notificationNotRegistered"
        case .apiDisabled: return "apiDisabled"
        case .noValue: return "noValue"
        case .parameterizedAttributeUnsupported: return "parameterizedAttributeUnsupported"
        case .notEnoughPrecision: return "notEnoughPrecision"
        @unknown default: return "unknown(\(axError.rawValue))"
        }
    }

    func describe(rect: CGRect) -> String {
        String(
            format: "{x=%.1f y=%.1f w=%.1f h=%.1f}",
            rect.minX,
            rect.minY,
            rect.width,
            rect.height
        )
    }

    func logFirefoxFrameAttempt(
        stage: String,
        window: AXUIElement,
        targetRect: CGRect,
        details: String?
    ) {
        let pidDescription = processIdentifier(for: window).map(String.init) ?? "?"
        let bundleDescription = bundleIdentifier(for: window) ?? "unknown"
        let currentRectDescription = currentWindowRect(for: window).map(describe(rect:)) ?? "nil"
        let extra = details.map { " \($0)" } ?? ""
        NSLog(
            "VibeGrid Firefox frame %@ pid=%@ bundle=%@ target=%@ current=%@%@",
            stage,
            pidDescription,
            bundleDescription,
            describe(rect: targetRect),
            currentRectDescription,
            extra
        )
    }

    // MARK: - Close/hide accessibility windows

    func closeAccessibilityWindow(_ window: AXUIElement) -> Bool {
        applyAXMessagingTimeout(to: window)
        let closeStatus = AXUIElementPerformAction(window, "AXClose" as CFString)
        if closeStatus == .success {
            return true
        }

        if let closeButton = copyAXElementAttribute(from: window, attribute: kAXCloseButtonAttribute) {
            applyAXMessagingTimeout(to: closeButton)
            let pressStatus = AXUIElementPerformAction(closeButton, kAXPressAction as CFString)
            if pressStatus == .success {
                return true
            }
            NSLog(
                "VibeGrid: failed to close window (close=%d press=%d)",
                closeStatus.rawValue,
                pressStatus.rawValue
            )
            return false
        }

        NSLog("VibeGrid: failed to close window (close=%d no close button)", closeStatus.rawValue)
        return false
    }

    func hideAccessibilityWindow(_ window: AXUIElement, pid: pid_t) -> Bool {
        applyAXMessagingTimeout(to: window)
        let minimizeStatus = AXUIElementSetAttributeValue(
            window,
            kAXMinimizedAttribute as CFString,
            kCFBooleanTrue
        )
        if minimizeStatus == .success {
            return true
        }

        if let app = NSRunningApplication(processIdentifier: pid) {
            return app.hide()
        }

        return false
    }

}

#endif
