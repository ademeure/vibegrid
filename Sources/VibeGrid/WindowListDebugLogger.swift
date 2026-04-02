import Foundation

final class WindowListDebugLogger {
    static let shared = WindowListDebugLogger()

    private let queue = DispatchQueue(label: "vibegrid.windowListDebugLogger")
    private let fileManager = FileManager.default
    private lazy var fileURL: URL = {
        let appSupportBase = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ??
            fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        return appSupportBase
            .appendingPathComponent("VibeGrid", isDirectory: true)
            .appendingPathComponent("logs", isDirectory: true)
            .appendingPathComponent("window-list-debug.log", isDirectory: false)
    }()

    static func log(_ component: String, _ message: String) {
        shared.append(component: component, message: message)
    }

    static func logPath() -> String {
        shared.fileURL.path
    }

    private static let dateFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        return f
    }()

    private func append(component: String, message: String) {
        let sanitizedMessage = message.replacingOccurrences(of: "\n", with: "\\n")
        NSLog("VibeGrid %@: %@", component, sanitizedMessage)
        let timestamp = Self.dateFormatter.string(from: Date())
        let line = "\(timestamp) [\(component)] \(sanitizedMessage)\n"

        queue.async { [fileManager, fileURL] in
            do {
                try fileManager.createDirectory(
                    at: fileURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )

                let data = Data(line.utf8)
                if fileManager.fileExists(atPath: fileURL.path) {
                    let handle = try FileHandle(forWritingTo: fileURL)
                    defer {
                        try? handle.close()
                    }
                    try handle.seekToEnd()
                    try handle.write(contentsOf: data)
                } else {
                    try data.write(to: fileURL, options: .atomic)
                }
            } catch {
                NSLog(
                    "VibeGrid window-list-debug logger failed for %@: %@",
                    component,
                    String(describing: error)
                )
            }
        }
    }
}
