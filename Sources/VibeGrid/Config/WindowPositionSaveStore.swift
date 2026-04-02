import Foundation

final class WindowPositionSaveStore {
    let saveURL: URL
    private let fileManager: FileManager

    init(fileManager: FileManager = .default, saveURL: URL? = nil) {
        self.fileManager = fileManager
        self.saveURL = saveURL ?? Self.defaultSaveURL(fileManager: fileManager)
    }

    func loadSnapshots() -> [MoveEverythingSavedWindowPositionsSnapshot] {
        ensureDirectoryExists()
        guard fileManager.fileExists(atPath: saveURL.path) else {
            return []
        }

        do {
            let data = try Data(contentsOf: saveURL)
            if let payload = try? JSONDecoder().decode(SavedSnapshotHistory.self, from: data) {
                return payload.snapshots
            }
            if let snapshots = try? JSONDecoder().decode([MoveEverythingSavedWindowPositionsSnapshot].self, from: data) {
                return snapshots
            }
            if let snapshot = try? JSONDecoder().decode(MoveEverythingSavedWindowPositionsSnapshot.self, from: data) {
                return snapshot.windows.isEmpty ? [] : [snapshot]
            }
            NSLog("VibeGrid: failed to decode saved window positions history from %@", saveURL.path)
            return []
        } catch {
            NSLog(
                "VibeGrid: failed to load saved window positions from %@: %@",
                saveURL.path,
                String(describing: error)
            )
            return []
        }
    }

    @discardableResult
    func saveSnapshots(_ snapshots: [MoveEverythingSavedWindowPositionsSnapshot]) -> Bool {
        ensureDirectoryExists()

        if snapshots.isEmpty {
            do {
                if fileManager.fileExists(atPath: saveURL.path) {
                    try fileManager.removeItem(at: saveURL)
                }
                return true
            } catch {
                NSLog(
                    "VibeGrid: failed to clear saved window positions at %@: %@",
                    saveURL.path,
                    String(describing: error)
                )
                return false
            }
        }

        do {
            let data = try JSONEncoder().encode(
                SavedSnapshotHistory(snapshots: snapshots)
            )
            try data.write(to: saveURL, options: .atomic)
            return true
        } catch {
            NSLog(
                "VibeGrid: failed to save window positions to %@: %@",
                saveURL.path,
                String(describing: error)
            )
            return false
        }
    }

    static func defaultSaveURL(fileManager: FileManager = .default) -> URL {
        let appSupportBase = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ??
            fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)

        return appSupportBase
            .appendingPathComponent("VibeGrid", isDirectory: true)
            .appendingPathComponent("window-position-save.json", isDirectory: false)
    }

    private func ensureDirectoryExists() {
        let directory = saveURL.deletingLastPathComponent()
        guard !fileManager.fileExists(atPath: directory.path) else {
            return
        }

        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            NSLog("VibeGrid: failed to create window position save directory: %@", String(describing: error))
        }
    }

    private struct SavedSnapshotHistory: Codable {
        let snapshots: [MoveEverythingSavedWindowPositionsSnapshot]
    }
}
