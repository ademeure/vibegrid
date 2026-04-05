import Foundation

struct PinnedWindowDescriptor: Codable, Equatable {
    var bundleIdentifier: String?
    var appName: String
    var title: String?
    var iTermWindowName: String?

    func matches(_ other: PinnedWindowDescriptor) -> Bool {
        if let bid = bundleIdentifier, let otherBid = other.bundleIdentifier, !bid.isEmpty, !otherBid.isEmpty {
            guard bid == otherBid else { return false }
        } else {
            guard appName == other.appName else { return false }
        }
        guard title == other.title else { return false }
        if iTermWindowName != nil || other.iTermWindowName != nil {
            guard iTermWindowName == other.iTermWindowName else { return false }
        }
        return true
    }
}

struct PinnedWindowStore {
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func load() -> [PinnedWindowDescriptor] {
        let url = Self.fileURL(fileManager: fileManager)
        guard let data = try? Data(contentsOf: url),
              let descriptors = try? JSONDecoder().decode([PinnedWindowDescriptor].self, from: data) else {
            return []
        }
        return descriptors
    }

    func save(_ descriptors: [PinnedWindowDescriptor]) {
        let url = Self.fileURL(fileManager: fileManager)
        let directoryURL = url.deletingLastPathComponent()
        do {
            try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(descriptors)
            try data.write(to: url, options: .atomic)
        } catch {
            NSLog("VibeGrid: failed to save pinned windows: %@", error.localizedDescription)
        }
    }

    static func fileURL(fileManager: FileManager = .default) -> URL {
        let appSupportBase = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ??
            fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)

        return appSupportBase
            .appendingPathComponent("VibeGrid", isDirectory: true)
            .appendingPathComponent("pinned-windows.json", isDirectory: false)
    }
}
