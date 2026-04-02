import Foundation
import Testing
@testable import ITermActivityKit

@Test func defaultPythonURLPointsAtWindowActivityVenv() {
    let path = ITermWindowActivityDetector.defaultPythonURL().path
    #expect(path.hasSuffix("/Library/Application Support/iTerm2/window-activity-venv/bin/python"))
}

@Test func bundledPythonPackageContainsWorkerModule() {
    let resourceRoot = ITermWindowActivityDetector.pythonModuleRootURL()
    #expect(resourceRoot != nil)
    let workerPath = resourceRoot?.appendingPathComponent("iterm_activity/worker.py").path
    #expect(workerPath != nil)
    #expect(FileManager.default.fileExists(atPath: workerPath ?? ""))
}

@Test func waitForProcessToExitReturnsTrueForCompletedProcess() throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/true")

    try process.run()

    let completedInTime = ITermWindowActivityDetector.waitForProcessToExit(
        process,
        timeout: 0.5
    )

    #expect(completedInTime)
    #expect(!process.isRunning)
}

@Test func waitForProcessToExitTimesOutAndTerminatesHungProcess() throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sleep")
    process.arguments = ["5"]

    try process.run()

    let startedAt = Date()
    let completedInTime = ITermWindowActivityDetector.waitForProcessToExit(
        process,
        timeout: 0.05,
        shutdownGracePeriod: 0.05,
        killGracePeriod: 0.05
    )
    let elapsed = Date().timeIntervalSince(startedAt)

    #expect(!completedInTime)
    #expect(!process.isRunning)
    #expect(elapsed < 1.0)
}
