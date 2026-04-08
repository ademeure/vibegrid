import Foundation
#if os(macOS)
import Darwin
#endif

public final class ITermActivityWorkerClient {
    private let stateQueue = DispatchQueue(label: "ITermActivityWorkerClient.state")

    private var process: Process?
    private var stdinHandle: FileHandle?
    private var stdoutHandle: FileHandle?
    private var stdoutBuffer = Data()
    private var stderrBuffer = Data()
    private var nextRequestID: Int = 1

    public init() {}

    deinit {
        invalidate()
    }

    public func poll(
        pythonURL: URL,
        timeout: Double,
        maxPolledNonEmptyLines: Int,
        commands: [[String: Any]] = [],
        activeHoldOverride: Double? = nil
    ) -> ITermWindowActivityDetector.PollResult {
        stateQueue.sync {
            pollLocked(
                pythonURL: pythonURL,
                timeout: timeout,
                maxPolledNonEmptyLines: maxPolledNonEmptyLines,
                commands: commands,
                activeHoldOverride: activeHoldOverride
            )
        }
    }

    public func setWindowName(
        pythonURL: URL,
        windowID: String,
        name: String,
        timeout: Double = 2.0
    ) -> Bool {
        stateQueue.sync {
            setWindowNameLocked(
                pythonURL: pythonURL,
                windowID: windowID,
                name: name,
                timeout: timeout
            )
        }
    }


    public func invalidate() {
        stateQueue.sync {
            invalidateLocked(sendShutdown: true)
        }
    }

    private func pollLocked(
        pythonURL: URL,
        timeout: Double,
        maxPolledNonEmptyLines: Int,
        commands: [[String: Any]] = [],
        activeHoldOverride: Double? = nil
    ) -> ITermWindowActivityDetector.PollResult {
        do {
            try ensureWorkerRunningLocked(pythonURL: pythonURL)
        } catch {
            invalidateLocked(sendShutdown: false)
            return ITermWindowActivityDetector.PollResult(
                entries: [],
                activitiesByWindowID: [:],
                rawOutput: "",
                stderrText: error.localizedDescription,
                terminationStatus: -1,
                parseSucceeded: false
            )
        }

        let requestID = nextRequestID
        nextRequestID += 1

        var request: [String: Any] = [
            "id": requestID,
            "op": "poll",
            "max_polled_non_empty_lines": maxPolledNonEmptyLines,
        ]
        if !commands.isEmpty {
            request["commands"] = commands
        }
        if let activeHoldOverride {
            request["active_hold_override"] = activeHoldOverride
        }

        do {
            try writeJSONLineLocked(request)
        } catch {
            let stderrText = currentStderrTextLocked(fallback: error.localizedDescription)
            invalidateLocked(sendShutdown: false)
            return ITermWindowActivityDetector.PollResult(
                entries: [],
                activitiesByWindowID: [:],
                rawOutput: "",
                stderrText: stderrText,
                terminationStatus: safeTerminationStatusLocked(),
                parseSucceeded: false
            )
        }

        guard let responseLine = readLineLocked(timeout: timeout) else {
            let stderrText = currentStderrTextLocked(fallback: "timed out")
            let terminationStatus = safeTerminationStatusLocked()
            invalidateLocked(sendShutdown: false)
            return ITermWindowActivityDetector.PollResult(
                entries: [],
                activitiesByWindowID: [:],
                rawOutput: "",
                stderrText: stderrText,
                terminationStatus: terminationStatus,
                parseSucceeded: false,
                timedOut: true
            )
        }

        let responseText = String(data: responseLine, encoding: .utf8) ?? ""
        guard let responseObject = try? JSONSerialization.jsonObject(with: responseLine) as? [String: Any] else {
            let stderrText = currentStderrTextLocked(fallback: "invalid worker response")
            invalidateLocked(sendShutdown: false)
            return ITermWindowActivityDetector.PollResult(
                entries: [],
                activitiesByWindowID: [:],
                rawOutput: responseText,
                stderrText: stderrText,
                terminationStatus: safeTerminationStatusLocked(),
                parseSucceeded: false
            )
        }

        let responseID = (responseObject["id"] as? NSNumber)?.intValue
        guard responseID == requestID else {
            let stderrText = currentStderrTextLocked(fallback: "worker response id mismatch")
            invalidateLocked(sendShutdown: false)
            return ITermWindowActivityDetector.PollResult(
                entries: [],
                activitiesByWindowID: [:],
                rawOutput: responseText,
                stderrText: stderrText,
                terminationStatus: safeTerminationStatusLocked(),
                parseSucceeded: false
            )
        }

        let ok = responseObject["ok"] as? Bool ?? false
        guard ok else {
            let errorText = (responseObject["error"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return ITermWindowActivityDetector.PollResult(
                entries: [],
                activitiesByWindowID: [:],
                rawOutput: responseText,
                stderrText: currentStderrTextLocked(fallback: errorText ?? "worker error"),
                terminationStatus: safeTerminationStatusLocked(fallback: 0),
                parseSucceeded: false
            )
        }

        let entries = ((responseObject["entries"] as? [[String: Any]]) ?? []).compactMap(parseEntry)
        let activities = parseActivities(responseObject["activities"] as? [String: Any] ?? [:])
        return ITermWindowActivityDetector.PollResult(
            entries: entries,
            activitiesByWindowID: activities,
            rawOutput: responseText,
            stderrText: currentStderrTextLocked(fallback: ""),
            terminationStatus: safeTerminationStatusLocked(fallback: 0),
            parseSucceeded: true
        )
    }

    private func setWindowNameLocked(
        pythonURL: URL,
        windowID: String,
        name: String,
        timeout: Double
    ) -> Bool {
        do {
            try ensureWorkerRunningLocked(pythonURL: pythonURL)
        } catch {
            return false
        }

        let requestID = nextRequestID
        nextRequestID += 1
        let request: [String: Any] = [
            "id": requestID,
            "op": "set_name",
            "window_id": windowID,
            "name": name,
        ]

        do {
            try writeJSONLineLocked(request)
        } catch {
            return false
        }

        guard let responseLine = readLineLocked(timeout: timeout),
              let responseObject = try? JSONSerialization.jsonObject(with: responseLine) as? [String: Any] else {
            return false
        }
        return responseObject["ok"] as? Bool ?? false
    }

    private func ensureWorkerRunningLocked(pythonURL: URL) throws {
        if let process, process.isRunning {
            return
        }

        invalidateLocked(sendShutdown: false)

        guard let pythonModuleRootURL = ITermWindowActivityDetector.pythonModuleRootURL() else {
            throw NSError(
                domain: "ITermActivityWorkerClient",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Missing bundled Python resources"]
            )
        }

        let process = Process()
        process.executableURL = pythonURL
        process.arguments = ["-m", "iterm_activity.worker"]

        var environment = ProcessInfo.processInfo.environment
        let existingPythonPath = environment["PYTHONPATH"] ?? ""
        environment["PYTHONUNBUFFERED"] = "1"
        environment["PYTHONPATH"] = existingPythonPath.isEmpty
            ? pythonModuleRootURL.path
            : "\(pythonModuleRootURL.path):\(existingPythonPath)"
        process.environment = environment

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()

        self.process = process
        self.stdinHandle = stdinPipe.fileHandleForWriting
        self.stdoutHandle = stdoutPipe.fileHandleForReading
        self.stdoutBuffer = Data()
        self.stderrBuffer = Data()

        let stderrHandle = stderrPipe.fileHandleForReading
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let data = stderrHandle.readDataToEndOfFile()
            guard let self else { return }
            self.stateQueue.async {
                self.appendStderrLocked(data)
            }
        }
    }

    private func invalidateLocked(sendShutdown: Bool) {
        let currentProcess = process

        if sendShutdown,
           let currentProcess,
           currentProcess.isRunning {
            let request: [String: Any] = [
                "id": 0,
                "op": "shutdown",
            ]
            _ = try? writeJSONLineLocked(request)
            _ = ITermWindowActivityDetector.waitForProcessToExit(currentProcess, timeout: 0.5)
        }

        if let currentProcess, currentProcess.isRunning {
            currentProcess.terminate()
            _ = ITermWindowActivityDetector.waitForProcessToExit(currentProcess, timeout: 0.5)
        }

        stdinHandle?.closeFile()
        stdoutHandle?.closeFile()

        stdinHandle = nil
        stdoutHandle = nil
        process = nil
        stdoutBuffer = Data()
    }

    private func writeJSONLineLocked(_ object: [String: Any]) throws {
        guard let stdinHandle else {
            throw NSError(
                domain: "ITermActivityWorkerClient",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Worker stdin is unavailable"]
            )
        }
        let data = try JSONSerialization.data(withJSONObject: object)
        var line = data
        line.append(0x0A)
        try stdinHandle.write(contentsOf: line)
    }

    private func readLineLocked(timeout: Double) -> Data? {
        guard let stdoutHandle else {
            return nil
        }

        let fd = stdoutHandle.fileDescriptor
        let deadline = Date().addingTimeInterval(timeout)

        while true {
            if let newlineIndex = stdoutBuffer.firstIndex(of: 0x0A) {
                let line = stdoutBuffer.prefix(upTo: newlineIndex)
                stdoutBuffer.removeSubrange(...newlineIndex)
                return Data(line)
            }

            let remaining = deadline.timeIntervalSinceNow
            if remaining <= 0 {
                return nil
            }

            var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let pollResult = Darwin.poll(
                &descriptor,
                1,
                Int32(max(1, Int(remaining * 1_000)))
            )
            if pollResult == 0 {
                continue
            }
            if pollResult < 0 {
                if errno == EINTR {
                    continue
                }
                return nil
            }

            var buffer = [UInt8](repeating: 0, count: 4_096)
            let bytesRead = Darwin.read(fd, &buffer, buffer.count)
            if bytesRead > 0 {
                stdoutBuffer.append(buffer, count: bytesRead)
                continue
            }
            if bytesRead == 0 {
                if stdoutBuffer.isEmpty {
                    return nil
                }
                let line = stdoutBuffer
                stdoutBuffer = Data()
                return line
            }
            if errno == EINTR {
                continue
            }
            return nil
        }
    }

    private func parseEntry(_ value: [String: Any]) -> ITermWindowActivityDetector.PollEntry? {
        let windowID = (value["window_id"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !windowID.isEmpty else {
            return nil
        }

        return ITermWindowActivityDetector.PollEntry(
            windowID: windowID,
            ttyActive: value["tty_active"] as? Bool ?? false,
            x: (value["x"] as? NSNumber)?.doubleValue ?? 0,
            y: (value["y"] as? NSNumber)?.doubleValue ?? 0,
            width: (value["width"] as? NSNumber)?.doubleValue ?? 0,
            height: (value["height"] as? NSNumber)?.doubleValue ?? 0,
            badgeText: (value["badge_text"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
            sessionName: (value["session_name"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
            presentationName: (value["presentation_name"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
            commandLine: (value["command_line"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
            lastLine: (value["last_line"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
            nonEmptyLinesFromBottom: (value["non_empty_lines_from_bottom"] as? [String] ?? [])
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty },
            backgroundColorR: (value["background_color_r"] as? NSNumber)?.intValue ?? 0,
            backgroundColorG: (value["background_color_g"] as? NSNumber)?.intValue ?? 0,
            backgroundColorB: (value["background_color_b"] as? NSNumber)?.intValue ?? 0,
            backgroundColorLightR: (value["background_color_light_r"] as? NSNumber)?.intValue ?? 0,
            backgroundColorLightG: (value["background_color_light_g"] as? NSNumber)?.intValue ?? 0,
            backgroundColorLightB: (value["background_color_light_b"] as? NSNumber)?.intValue ?? 0,
            useSeparateColors: value["use_separate_colors"] as? Bool ?? false
        )
    }

    private func parseActivities(_ value: [String: Any]) -> [String: ITermWindowActivityDetector.ResolvedActivity] {
        var activities: [String: ITermWindowActivityDetector.ResolvedActivity] = [:]

        for (windowID, rawActivity) in value {
            guard let dict = rawActivity as? [String: Any],
                  let statusRaw = (dict["status"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                  let status = ITermWindowActivityDetector.Status(rawValue: statusRaw) else {
                continue
            }

            activities[windowID] = ITermWindowActivityDetector.ResolvedActivity(
                status: status,
                badgeText: (dict["badge_text"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
                sessionName: (dict["session_name"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
                lastLine: (dict["last_line"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
                profileID: (dict["profile_id"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? "default",
                reason: (dict["reason"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? "unknown",
                semanticLines: (dict["semantic_lines"] as? [String] ?? [])
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty },
                detail: (dict["detail"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
                tmuxPaneCommand: (dict["tmux_pane_command"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
                tmuxPanePath: (dict["tmux_pane_path"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
                tmuxPaneTitle: (dict["tmux_pane_title"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            )
        }

        return activities
    }

    private func appendStderrLocked(_ data: Data) {
        guard !data.isEmpty else {
            return
        }
        stderrBuffer.append(data)
        let maxBytes = 32_768
        if stderrBuffer.count > maxBytes {
            stderrBuffer.removeFirst(stderrBuffer.count - maxBytes)
        }
    }

    private func safeTerminationStatusLocked(fallback: Int32 = -1) -> Int32 {
        guard let process, !process.isRunning else {
            return fallback
        }
        return process.terminationStatus
    }

    private func currentStderrTextLocked(fallback: String) -> String {
        let stderrText = String(data: stderrBuffer, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return stderrText.isEmpty ? fallback : stderrText
    }
}
