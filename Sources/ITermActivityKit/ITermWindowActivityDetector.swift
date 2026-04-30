import Foundation
#if os(macOS)
import Darwin
#endif

public enum ITermWindowActivityDetector {
    public enum Status: String, Sendable {
        case active
        case idle
    }

    public struct PollEntry: Sendable {
        public let windowID: String
        public let ttyActive: Bool
        public let x: Double
        public let y: Double
        public let width: Double
        public let height: Double
        public let badgeText: String
        public let sessionName: String
        public let presentationName: String
        public let commandLine: String
        public let lastLine: String
        public let nonEmptyLinesFromBottom: [String]
        public let backgroundColorR: Int
        public let backgroundColorG: Int
        public let backgroundColorB: Int
        public let backgroundColorLightR: Int
        public let backgroundColorLightG: Int
        public let backgroundColorLightB: Int
        public let useSeparateColors: Bool

        public init(
            windowID: String,
            ttyActive: Bool,
            x: Double,
            y: Double,
            width: Double,
            height: Double,
            badgeText: String,
            sessionName: String,
            presentationName: String,
            commandLine: String,
            lastLine: String,
            nonEmptyLinesFromBottom: [String],
            backgroundColorR: Int = 0,
            backgroundColorG: Int = 0,
            backgroundColorB: Int = 0,
            backgroundColorLightR: Int = 0,
            backgroundColorLightG: Int = 0,
            backgroundColorLightB: Int = 0,
            useSeparateColors: Bool = false
        ) {
            self.windowID = windowID
            self.ttyActive = ttyActive
            self.x = x
            self.y = y
            self.width = width
            self.height = height
            self.badgeText = badgeText
            self.sessionName = sessionName
            self.presentationName = presentationName
            self.commandLine = commandLine
            self.lastLine = lastLine
            self.nonEmptyLinesFromBottom = nonEmptyLinesFromBottom
            self.backgroundColorR = backgroundColorR
            self.backgroundColorG = backgroundColorG
            self.backgroundColorB = backgroundColorB
            self.backgroundColorLightR = backgroundColorLightR
            self.backgroundColorLightG = backgroundColorLightG
            self.backgroundColorLightB = backgroundColorLightB
            self.useSeparateColors = useSeparateColors
        }
    }

    public struct ResolvedActivity: Sendable {
        public let status: Status
        public let badgeText: String
        public let sessionName: String
        public let lastLine: String
        public let profileID: String
        public let reason: String
        public let semanticLines: [String]
        public let detail: String
        public let tmuxPaneCommand: String
        public let tmuxPanePath: String
        public let tmuxPaneTitle: String

        public var semanticLineCount: Int {
            semanticLines.count
        }

        public init(
            status: Status,
            badgeText: String,
            sessionName: String,
            lastLine: String,
            profileID: String,
            reason: String,
            semanticLines: [String],
            detail: String = "",
            tmuxPaneCommand: String = "",
            tmuxPanePath: String = "",
            tmuxPaneTitle: String = ""
        ) {
            self.status = status
            self.badgeText = badgeText
            self.sessionName = sessionName
            self.lastLine = lastLine
            self.profileID = profileID
            self.reason = reason
            self.semanticLines = semanticLines
            self.detail = detail
            self.tmuxPaneCommand = tmuxPaneCommand
            self.tmuxPanePath = tmuxPanePath
            self.tmuxPaneTitle = tmuxPaneTitle
        }
    }

    public struct CommandResult: Sendable {
        public let op: String
        public let ok: Bool
        public let error: String

        public init(op: String, ok: Bool, error: String = "") {
            self.op = op
            self.ok = ok
            self.error = error
        }
    }

    public struct PollResult: Sendable {
        public let entries: [PollEntry]
        public let activitiesByWindowID: [String: ResolvedActivity]
        public let commandResults: [CommandResult]
        public let rawOutput: String
        public let stderrText: String
        public let terminationStatus: Int32
        public let parseSucceeded: Bool
        public let timedOut: Bool

        public init(
            entries: [PollEntry],
            activitiesByWindowID: [String: ResolvedActivity],
            commandResults: [CommandResult] = [],
            rawOutput: String,
            stderrText: String,
            terminationStatus: Int32,
            parseSucceeded: Bool,
            timedOut: Bool = false
        ) {
            self.entries = entries
            self.activitiesByWindowID = activitiesByWindowID
            self.commandResults = commandResults
            self.rawOutput = rawOutput
            self.stderrText = stderrText
            self.terminationStatus = terminationStatus
            self.parseSucceeded = parseSucceeded
            self.timedOut = timedOut
        }
    }

    public static func defaultPythonURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/iTerm2/window-activity-venv")
            .appendingPathComponent("bin/python")
    }

    static func pythonModuleRootURL() -> URL? {
        Bundle.module.resourceURL?.appendingPathComponent("python")
    }

    static func waitForProcessToExit(
        _ process: Process,
        timeout: Double,
        shutdownGracePeriod: Double = 0.2,
        killGracePeriod: Double = 0.2
    ) -> Bool {
        if !process.isRunning {
            return true
        }

        if timeout <= 0 {
            process.waitUntilExit()
            return true
        }

        let sleepInterval = 0.01

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: sleepInterval)
        }
        if !process.isRunning {
            return true
        }

        if process.isRunning {
            process.interrupt()
        }
        let interruptDeadline = Date().addingTimeInterval(shutdownGracePeriod)
        while process.isRunning && Date() < interruptDeadline {
            Thread.sleep(forTimeInterval: sleepInterval)
        }
        if !process.isRunning {
            return false
        }

        if process.isRunning {
            process.terminate()
        }
        let terminateDeadline = Date().addingTimeInterval(killGracePeriod)
        while process.isRunning && Date() < terminateDeadline {
            Thread.sleep(forTimeInterval: sleepInterval)
        }
        if !process.isRunning {
            return false
        }

        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
        }
        let killDeadline = Date().addingTimeInterval(killGracePeriod)
        while process.isRunning && Date() < killDeadline {
            Thread.sleep(forTimeInterval: sleepInterval)
        }
        return false
    }
}
