import Foundation
import ITermActivityKit

private struct Options {
    var count = 1
    var interval = 1.0
    var timeout = 2.0
    var maxLines = 60
    var pythonURL = ITermWindowActivityDetector.defaultPythonURL()
    var filter = ""
    var showBody = false
}

private func parseOptions() -> Options {
    var options = Options()
    var arguments = Array(CommandLine.arguments.dropFirst())

    while !arguments.isEmpty {
        let argument = arguments.removeFirst()
        switch argument {
        case "--count":
            if let value = arguments.first, let parsed = Int(value) {
                options.count = parsed
                arguments.removeFirst()
            }
        case "--interval":
            if let value = arguments.first, let parsed = Double(value) {
                options.interval = parsed
                arguments.removeFirst()
            }
        case "--timeout":
            if let value = arguments.first, let parsed = Double(value) {
                options.timeout = parsed
                arguments.removeFirst()
            }
        case "--max-lines":
            if let value = arguments.first, let parsed = Int(value) {
                options.maxLines = parsed
                arguments.removeFirst()
            }
        case "--python":
            if let value = arguments.first {
                options.pythonURL = URL(fileURLWithPath: value)
                arguments.removeFirst()
            }
        case "--filter":
            if let value = arguments.first {
                options.filter = value
                arguments.removeFirst()
            }
        case "--show-body":
            options.showBody = true
        default:
            break
        }
    }

    return options
}

private func summarize(_ value: String, limit: Int = 120) -> String {
    let compact = value.replacingOccurrences(of: "\n", with: " ")
    if compact.count <= limit {
        return compact
    }
    return String(compact.prefix(limit - 3)) + "..."
}

@main
private enum ITermActivityDebugMain {
    static func main() {
        let options = parseOptions()
        let workerClient = ITermActivityWorkerClient()
        defer {
            workerClient.invalidate()
        }

        let iterations = max(options.count, 1)
        for iteration in 0..<iterations {
            let pollResult = workerClient.poll(
                pythonURL: options.pythonURL,
                timeout: options.timeout,
                maxPolledNonEmptyLines: options.maxLines
            )

            let timestamp = ISO8601DateFormatter().string(from: Date())
            print("poll \(iteration + 1)/\(iterations) \(timestamp)")

            if pollResult.entries.isEmpty {
                print(
                    "  no entries status=\(pollResult.terminationStatus) " +
                        "parse=\(pollResult.parseSucceeded) stderr=\(summarize(pollResult.stderrText))"
                )
            } else {
                for entry in pollResult.entries.sorted(by: { $0.windowID < $1.windowID }) {
                    let activity = pollResult.activitiesByWindowID[entry.windowID]
                    let semanticLines = activity?.semanticLines ?? []
                    let sessionName = activity?.sessionName ?? entry.sessionName
                    if !options.filter.isEmpty &&
                        !entry.windowID.localizedCaseInsensitiveContains(options.filter) &&
                        !sessionName.localizedCaseInsensitiveContains(options.filter) {
                        continue
                    }
                    let lastLine = summarize(activity?.lastLine ?? entry.lastLine, limit: 90)
                    print(
                        "  window=\(entry.windowID) " +
                            "status=\(activity?.status.rawValue ?? "idle") " +
                            "profile=\(activity?.profileID ?? "default") " +
                            "reason=\(activity?.reason ?? "unknown") " +
                            "semanticLines=\(semanticLines.count) " +
                            "session=\(sessionName) " +
                            "last=\(lastLine)"
                    )
                    if options.showBody {
                        for (index, line) in semanticLines.enumerated() {
                            print("    [\(index)] \(summarize(line, limit: 180))")
                        }
                    }
                }
            }

            if iteration + 1 < iterations {
                Thread.sleep(forTimeInterval: options.interval)
            }
        }
    }
}
