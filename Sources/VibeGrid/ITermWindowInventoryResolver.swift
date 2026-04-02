import CoreGraphics
import Foundation
import ITermActivityKit

struct ITermWindowInventoryResolver {
    struct WindowDescriptor {
        let id: Int
        let index: Int
        let name: String
        let frame: CGRect
    }

    struct RuntimeWindowDescriptor {
        let windowID: String
        let windowNumber: Int
        let name: String
        let frame: CGRect
    }

    static func fetchInventory(debugContext: String? = nil) -> [WindowDescriptor] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = [
            "-l",
            "JavaScript",
            "-e",
            """
            var app = Application("iTerm2");
            JSON.stringify(app.windows().map(function(w){
              var bounds = w.bounds();
              return {
                id: w.id(),
                index: w.index(),
                name: w.name(),
                bounds: {
                  x: bounds.x,
                  y: bounds.y,
                  width: bounds.width,
                  height: bounds.height
                }
              };
            }));
            """
        ]

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        do {
            try process.run()
        } catch {
            if let debugContext {
                WindowListDebugLogger.log(
                    "iterm-resolver",
                    "\(debugContext) failed to launch osascript: \(error.localizedDescription)"
                )
            }
            return []
        }

        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let errorText = String(data: errorData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if let debugContext {
                WindowListDebugLogger.log(
                    "iterm-resolver",
                    "\(debugContext) osascript failed status=\(process.terminationStatus) error=\(errorText)"
                )
            }
            return []
        }

        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        guard let outputText = String(data: outputData, encoding: .utf8),
              let data = outputText.data(using: .utf8),
              let rawWindows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            if let debugContext {
                WindowListDebugLogger.log(
                    "iterm-resolver",
                    "\(debugContext) failed to decode osascript output"
                )
            }
            return []
        }

        let windows = rawWindows.compactMap { rawWindow -> WindowDescriptor? in
            let id: Int? = {
                if let number = rawWindow["id"] as? NSNumber {
                    return number.intValue
                }
                if let number = rawWindow["id"] as? Int {
                    return number
                }
                return nil
            }()
            let index: Int? = {
                if let number = rawWindow["index"] as? NSNumber {
                    return number.intValue
                }
                if let number = rawWindow["index"] as? Int {
                    return number
                }
                return nil
            }()
            let title = (rawWindow["name"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard let id, let index, index > 0,
                  let bounds = rawWindow["bounds"] as? [String: Any] else {
                return nil
            }
            let x = (bounds["x"] as? NSNumber)?.doubleValue ?? 0
            let y = (bounds["y"] as? NSNumber)?.doubleValue ?? 0
            let width = (bounds["width"] as? NSNumber)?.doubleValue ?? 0
            let height = (bounds["height"] as? NSNumber)?.doubleValue ?? 0
            return WindowDescriptor(
                id: id,
                index: index,
                name: title,
                frame: CGRect(x: x, y: y, width: width, height: height)
            )
        }

        if let debugContext {
            WindowListDebugLogger.log(
                "iterm-resolver",
                "\(debugContext) fetched \(windows.count) iTerm windows"
            )
        }
        return windows
    }

    static func fetchRuntimeInventory(debugContext: String? = nil) -> [RuntimeWindowDescriptor] {
        let pythonURL = pythonURL()
        guard FileManager.default.isExecutableFile(atPath: pythonURL.path) else {
            if let debugContext {
                WindowListDebugLogger.log(
                    "iterm-runtime-resolver",
                    "\(debugContext) missing python runtime at \(pythonURL.path)"
                )
            }
            ensurePythonVenv(debugContext: debugContext)
            return []
        }

        let process = Process()
        process.executableURL = pythonURL
        process.arguments = [
            "-c",
            """
            import json
            import iterm2

            async def _window_title(window):
                for name in (
                    "currentTab.currentSession.terminalWindowName",
                    "currentTab.title",
                    "currentTab.currentSession.autoName",
                ):
                    try:
                        value = await window.async_get_variable(name)
                    except Exception:
                        value = None
                    if isinstance(value, str) and value.strip():
                        return value.strip()
                return ""

            async def main(connection):
                app = await iterm2.async_get_app(connection)
                windows = []
                for window in app.windows:
                    frame = window.frame
                    windows.append({
                        "window_id": window.window_id,
                        "window_number": window.window_number,
                        "title": await _window_title(window),
                        "bounds": {
                            "x": frame.origin.x,
                            "y": frame.origin.y,
                            "width": frame.size.width,
                            "height": frame.size.height,
                        },
                    })
                print(json.dumps(windows))

            iterm2.run_until_complete(main, retry=False)
            """
        ]

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        do {
            try process.run()
        } catch {
            if let debugContext {
                WindowListDebugLogger.log(
                    "iterm-runtime-resolver",
                    "\(debugContext) failed to launch python runtime: \(error.localizedDescription)"
                )
            }
            return []
        }

        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let errorText = String(data: errorData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if let debugContext {
                WindowListDebugLogger.log(
                    "iterm-runtime-resolver",
                    "\(debugContext) python runtime failed status=\(process.terminationStatus) error=\(errorText)"
                )
            }
            return []
        }

        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        guard let outputText = String(data: outputData, encoding: .utf8),
              let data = outputText.data(using: .utf8),
              let rawWindows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            if let debugContext {
                WindowListDebugLogger.log(
                    "iterm-runtime-resolver",
                    "\(debugContext) failed to decode python runtime output"
                )
            }
            return []
        }

        let windows = rawWindows.compactMap { rawWindow -> RuntimeWindowDescriptor? in
            let windowID = (rawWindow["window_id"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let windowNumber: Int? = {
                if let number = rawWindow["window_number"] as? NSNumber {
                    return number.intValue
                }
                if let number = rawWindow["window_number"] as? Int {
                    return number
                }
                return nil
            }()
            let title = (rawWindow["title"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !windowID.isEmpty,
                  let windowNumber, windowNumber >= 0,
                  let bounds = rawWindow["bounds"] as? [String: Any] else {
                return nil
            }
            let x = (bounds["x"] as? NSNumber)?.doubleValue ?? 0
            let y = (bounds["y"] as? NSNumber)?.doubleValue ?? 0
            let width = (bounds["width"] as? NSNumber)?.doubleValue ?? 0
            let height = (bounds["height"] as? NSNumber)?.doubleValue ?? 0
            return RuntimeWindowDescriptor(
                windowID: windowID,
                windowNumber: windowNumber,
                name: title,
                frame: CGRect(x: x, y: y, width: width, height: height)
            )
        }

        if let debugContext {
            WindowListDebugLogger.log(
                "iterm-runtime-resolver",
                "\(debugContext) fetched \(windows.count) runtime iTerm windows"
            )
        }
        return windows
    }

    static func resolveWindowDescriptor(
        from inventory: [WindowDescriptor],
        titleCandidates: [String],
        frame: CGRect?,
        debugContext: String? = nil
    ) -> WindowDescriptor? {
        guard !inventory.isEmpty else {
            if let debugContext {
                WindowListDebugLogger.log("iterm-resolver", "\(debugContext) empty inventory")
            }
            return nil
        }

        let exactRawTitles = Set(
            titleCandidates
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                .filter { !$0.isEmpty }
        )
        let normalizedTitles = Set(
            titleCandidates
                .map(normalizedTitle)
                .filter { !$0.isEmpty }
        )

        let frameMatches: [WindowDescriptor] = {
            guard let frame else {
                return []
            }
            return inventory.filter { framesMatch($0.frame, frame) }
        }()
        if frameMatches.count == 1, let matched = frameMatches.first {
            if let debugContext {
                WindowListDebugLogger.log(
                    "iterm-resolver",
                    "\(debugContext) resolved by frame index=\(matched.index) id=\(matched.id) title=\(matched.name)"
                )
            }
            return matched
        }

        if let resolved = resolveByTitle(
            candidates: frameMatches,
            exactRawTitles: exactRawTitles,
            normalizedTitles: normalizedTitles
        ) {
            if let debugContext {
                WindowListDebugLogger.log(
                    "iterm-resolver",
                    "\(debugContext) resolved by frame+title index=\(resolved.index) id=\(resolved.id) title=\(resolved.name)"
                )
            }
            return resolved
        }

        if let resolved = resolveByTitle(
            candidates: inventory,
            exactRawTitles: exactRawTitles,
            normalizedTitles: normalizedTitles
        ) {
            if let debugContext {
                WindowListDebugLogger.log(
                    "iterm-resolver",
                    "\(debugContext) resolved by title index=\(resolved.index) id=\(resolved.id) title=\(resolved.name)"
                )
            }
            return resolved
        }

        if inventory.count == 1, let resolved = inventory.first {
            if let debugContext {
                WindowListDebugLogger.log(
                    "iterm-resolver",
                    "\(debugContext) resolved by sole inventory window index=\(resolved.index) id=\(resolved.id)"
                )
            }
            return resolved
        }

        if let debugContext {
            let frameDescription: String = {
                guard let frame else {
                    return "nil"
                }
                return NSStringFromRect(NSRectFromCGRect(frame))
            }()
            WindowListDebugLogger.log(
                "iterm-resolver",
                "\(debugContext) failed to resolve index frame=\(frameDescription) titleCandidates=\(titleCandidates)"
            )
        }
        return nil
    }

    static func resolveWindowIndex(
        from inventory: [WindowDescriptor],
        titleCandidates: [String],
        frame: CGRect?,
        debugContext: String? = nil
    ) -> Int? {
        resolveWindowDescriptor(
            from: inventory,
            titleCandidates: titleCandidates,
            frame: frame,
            debugContext: debugContext
        )?.index
    }

    static func resolveRuntimeWindowDescriptor(
        from inventory: [RuntimeWindowDescriptor],
        titleCandidates: [String],
        frame: CGRect?,
        debugContext: String? = nil
    ) -> RuntimeWindowDescriptor? {
        guard !inventory.isEmpty else {
            if let debugContext {
                WindowListDebugLogger.log("iterm-runtime-resolver", "\(debugContext) empty runtime inventory")
            }
            return nil
        }

        let exactRawTitles = Set(
            titleCandidates
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                .filter { !$0.isEmpty }
        )
        let normalizedTitles = Set(
            titleCandidates
                .map(normalizedTitle)
                .filter { !$0.isEmpty }
        )

        let frameMatches: [RuntimeWindowDescriptor] = {
            guard let frame else {
                return []
            }
            return inventory.filter { framesMatch($0.frame, frame) }
        }()
        if frameMatches.count == 1, let matched = frameMatches.first {
            if let debugContext {
                WindowListDebugLogger.log(
                    "iterm-runtime-resolver",
                    "\(debugContext) resolved by frame windowID=\(matched.windowID) windowNumber=\(matched.windowNumber) title=\(matched.name)"
                )
            }
            return matched
        }

        if let resolved = resolveByTitle(
            candidates: frameMatches,
            exactRawTitles: exactRawTitles,
            normalizedTitles: normalizedTitles
        ) {
            if let debugContext {
                WindowListDebugLogger.log(
                    "iterm-runtime-resolver",
                    "\(debugContext) resolved by frame+title windowID=\(resolved.windowID) windowNumber=\(resolved.windowNumber) title=\(resolved.name)"
                )
            }
            return resolved
        }

        if let resolved = resolveByTitle(
            candidates: inventory,
            exactRawTitles: exactRawTitles,
            normalizedTitles: normalizedTitles
        ) {
            if let debugContext {
                WindowListDebugLogger.log(
                    "iterm-runtime-resolver",
                    "\(debugContext) resolved by title windowID=\(resolved.windowID) windowNumber=\(resolved.windowNumber) title=\(resolved.name)"
                )
            }
            return resolved
        }

        if inventory.count == 1, let resolved = inventory.first {
            if let debugContext {
                WindowListDebugLogger.log(
                    "iterm-runtime-resolver",
                    "\(debugContext) resolved by sole runtime inventory windowID=\(resolved.windowID) windowNumber=\(resolved.windowNumber)"
                )
            }
            return resolved
        }

        if let debugContext {
            let frameDescription: String = {
                guard let frame else {
                    return "nil"
                }
                return NSStringFromRect(NSRectFromCGRect(frame))
            }()
            WindowListDebugLogger.log(
                "iterm-runtime-resolver",
                "\(debugContext) failed to resolve runtime window frame=\(frameDescription) titleCandidates=\(titleCandidates)"
            )
        }
        return nil
    }

    static func normalizedTitle(_ value: String) -> String {
        var normalized = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !normalized.isEmpty else {
            return normalized
        }

        for _ in 0..<8 {
            let strippedMarker = normalized.replacingOccurrences(
                of: #"^\[[^\]]{1,32}\]\s*"#,
                with: "",
                options: .regularExpression
            )
            let stripped = strippedMarker.replacingOccurrences(
                of: #"^[\s\-:|•]+"#,
                with: "",
                options: .regularExpression
            )
            if stripped == normalized {
                break
            }
            normalized = stripped.trimmingCharacters(in: .whitespacesAndNewlines)
            if normalized.isEmpty {
                break
            }
        }

        return normalized
    }

    private static func resolveByTitle(
        candidates: [WindowDescriptor],
        exactRawTitles: Set<String>,
        normalizedTitles: Set<String>
    ) -> WindowDescriptor? {
        resolveByTitle(
            candidates: candidates,
            exactRawTitles: exactRawTitles,
            normalizedTitles: normalizedTitles,
            name: { $0.name }
        )
    }

    private static func resolveByTitle(
        candidates: [RuntimeWindowDescriptor],
        exactRawTitles: Set<String>,
        normalizedTitles: Set<String>
    ) -> RuntimeWindowDescriptor? {
        resolveByTitle(
            candidates: candidates,
            exactRawTitles: exactRawTitles,
            normalizedTitles: normalizedTitles,
            name: { $0.name }
        )
    }

    private static func resolveByTitle<T>(
        candidates: [T],
        exactRawTitles: Set<String>,
        normalizedTitles: Set<String>,
        name: (T) -> String
    ) -> T? {
        guard !candidates.isEmpty else {
            return nil
        }

        if !exactRawTitles.isEmpty {
            let exactMatches = candidates.filter {
                exactRawTitles.contains(name($0).trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
            }
            if exactMatches.count == 1 {
                return exactMatches[0]
            }
        }

        if !normalizedTitles.isEmpty {
            let normalizedMatches = candidates.filter {
                normalizedTitles.contains(normalizedTitle(name($0)))
            }
            if normalizedMatches.count == 1 {
                return normalizedMatches[0]
            }

            let fuzzyMatches = candidates.filter { candidate in
                let candidateTitle = normalizedTitle(name(candidate))
                guard !candidateTitle.isEmpty else {
                    return false
                }
                return normalizedTitles.contains {
                    candidateTitle.contains($0) || $0.contains(candidateTitle)
                }
            }
            if fuzzyMatches.count == 1 {
                return fuzzyMatches[0]
            }
        }

        return nil
    }

    /// Apply badge text and optionally badge color to all sessions of a specific iTerm2 window
    /// using the iterm2 Python API. Runs asynchronously in the background.
    static func applyBadge(
        windowID: String,
        badgeText: String,
        badgeColor: String,
        badgeOpacity: Int = 55,
        badgeSize: Int = 55,
        debugContext: String? = nil
    ) {
        let pythonURL = pythonURL()
        guard FileManager.default.isExecutableFile(atPath: pythonURL.path) else {
            if let debugContext {
                WindowListDebugLogger.log(
                    "iterm-badge",
                    "\(debugContext) missing python runtime at \(pythonURL.path)"
                )
            }
            ensurePythonVenv(debugContext: debugContext)
            return
        }

        let escapedBadgeText = badgeText
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let escapedWindowID = windowID
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")

        var colorR: UInt8?
        var colorG: UInt8?
        var colorB: UInt8?
        if !badgeColor.isEmpty, badgeColor.count >= 7, badgeColor.hasPrefix("#") {
            let hex = badgeColor.dropFirst()
            colorR = UInt8(hex.prefix(2), radix: 16)
            colorG = UInt8(hex.dropFirst(2).prefix(2), radix: 16)
            colorB = UInt8(hex.dropFirst(4).prefix(2), radix: 16)
        }
        let applyColor = colorR != nil && colorG != nil && colorB != nil
        let clampedOpacity = max(10, min(100, badgeOpacity))
        let alpha = Int(round(Double(clampedOpacity) * 255.0 / 100.0))
        let clampedSize = max(5, min(95, badgeSize))
        let badgeSizeWidth = clampedSize * 6
        let badgeSizeHeight = clampedSize * 3

        let script = """
        import iterm2
        import sys

        async def main(connection):
            app = await iterm2.async_get_app(connection)
            target_id = "\(escapedWindowID)"
            apply_color = \(applyColor ? "True" : "False")
            color_r = \(colorR.map(String.init) ?? "0")
            color_g = \(colorG.map(String.init) ?? "0")
            color_b = \(colorB.map(String.init) ?? "0")
            color_a = \(alpha)
            badge_width = \(badgeSizeWidth)
            badge_height = \(badgeSizeHeight)
            found = False
            # Try to parse target as int for window_number matching (JXA IDs are integers)
            try:
                target_number = int(target_id)
            except (ValueError, TypeError):
                target_number = None
            for window in app.windows:
                matched = window.window_id == target_id
                if not matched and target_number is not None:
                    try:
                        matched = window.window_number == target_number
                    except Exception:
                        pass
                if matched:
                    found = True
                    for tab in window.tabs:
                        for session in tab.sessions:
                            profile = await session.async_get_profile()
                            await profile.async_set_badge_text("\(escapedBadgeText)")
                            if apply_color:
                                bc = iterm2.Color(color_r, color_g, color_b, color_a)
                                await profile.async_set_badge_color(bc)
                                await profile.async_set_badge_color_light(bc)
                                await profile.async_set_badge_color_dark(bc)
                            await profile.async_set_badge_max_width(badge_width)
                            await profile.async_set_badge_max_height(badge_height)
                    break
            if not found:
                print(f"window {target_id} not found", file=sys.stderr)

        iterm2.run_until_complete(main, retry=False)
        """

        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            process.executableURL = pythonURL
            process.arguments = ["-c", script]
            let errorPipe = Pipe()
            process.standardError = errorPipe
            process.standardOutput = FileHandle.nullDevice

            do {
                try process.run()
            } catch {
                if let debugContext {
                    WindowListDebugLogger.log(
                        "iterm-badge",
                        "\(debugContext) failed to launch python: \(error.localizedDescription)"
                    )
                }
                return
            }

            process.waitUntilExit()
            if process.terminationStatus != 0 {
                let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
                let errorText = String(data: errorData, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if let debugContext {
                    WindowListDebugLogger.log(
                        "iterm-badge",
                        "\(debugContext) python failed status=\(process.terminationStatus) error=\(errorText)"
                    )
                }
            } else if let debugContext {
                WindowListDebugLogger.log(
                    "iterm-badge",
                    "\(debugContext) badge applied windowID=\(windowID) text=\(badgeText) color=\(badgeColor)"
                )
            }
        }
    }

    // MARK: - Python venv management

    private static let venvRelativePath = "Library/Application Support/iTerm2/window-activity-venv"
    private static var venvProvisioningInProgress = false

    static func pythonURL() -> URL {
        ITermWindowActivityDetector.defaultPythonURL()
    }

    /// Ensures the Python venv with the iterm2 package exists.
    /// Safe to call from any thread; runs pip install in the background.
    /// Calls the completion handler on a background queue when done.
    static func ensurePythonVenv(
        debugContext: String? = nil,
        completion: ((Bool) -> Void)? = nil
    ) {
        let python = pythonURL()
        if FileManager.default.isExecutableFile(atPath: python.path) {
            completion?(true)
            return
        }

        // Avoid concurrent provisioning attempts
        guard !venvProvisioningInProgress else {
            if let debugContext {
                WindowListDebugLogger.log("iterm-venv", "\(debugContext) provisioning already in progress")
            }
            completion?(false)
            return
        }
        venvProvisioningInProgress = true

        DispatchQueue.global(qos: .utility).async {
            defer { venvProvisioningInProgress = false }

            let venvDir = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(venvRelativePath)

            // Step 1: create the venv
            let venvProcess = Process()
            venvProcess.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            venvProcess.arguments = ["-m", "venv", venvDir.path]
            venvProcess.standardOutput = FileHandle.nullDevice
            venvProcess.standardError = FileHandle.nullDevice
            do {
                try venvProcess.run()
            } catch {
                NSLog("VibeGrid: failed to create Python venv: %@", error.localizedDescription)
                if let debugContext {
                    WindowListDebugLogger.log("iterm-venv", "\(debugContext) venv creation failed: \(error.localizedDescription)")
                }
                completion?(false)
                return
            }
            venvProcess.waitUntilExit()
            guard venvProcess.terminationStatus == 0 else {
                NSLog("VibeGrid: python3 -m venv exited with status %d", venvProcess.terminationStatus)
                if let debugContext {
                    WindowListDebugLogger.log("iterm-venv", "\(debugContext) venv creation exited status=\(venvProcess.terminationStatus)")
                }
                completion?(false)
                return
            }

            // Step 2: pip install iterm2
            let pipURL = venvDir.appendingPathComponent("bin/pip")
            let pipProcess = Process()
            pipProcess.executableURL = pipURL
            pipProcess.arguments = ["install", "--quiet", "iterm2"]
            pipProcess.standardOutput = FileHandle.nullDevice
            let pipErrorPipe = Pipe()
            pipProcess.standardError = pipErrorPipe
            do {
                try pipProcess.run()
            } catch {
                NSLog("VibeGrid: failed to run pip install iterm2: %@", error.localizedDescription)
                if let debugContext {
                    WindowListDebugLogger.log("iterm-venv", "\(debugContext) pip install failed: \(error.localizedDescription)")
                }
                completion?(false)
                return
            }
            pipProcess.waitUntilExit()
            let pipOK = pipProcess.terminationStatus == 0
            if !pipOK {
                let errData = pipErrorPipe.fileHandleForReading.readDataToEndOfFile()
                let errText = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                NSLog("VibeGrid: pip install iterm2 failed status=%d: %@", pipProcess.terminationStatus, errText)
                if let debugContext {
                    WindowListDebugLogger.log("iterm-venv", "\(debugContext) pip install iterm2 failed status=\(pipProcess.terminationStatus)")
                }
            } else if let debugContext {
                WindowListDebugLogger.log("iterm-venv", "\(debugContext) venv provisioned at \(venvDir.path)")
            }
            completion?(pipOK)
        }
    }


    private static func framesMatch(_ left: CGRect, _ right: CGRect) -> Bool {
        let delta = abs(left.origin.x - right.origin.x) +
            abs(left.origin.y - right.origin.y) +
            abs(left.size.width - right.size.width) +
            abs(left.size.height - right.size.height)
        return delta <= 4
    }
}
