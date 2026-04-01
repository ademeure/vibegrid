import Foundation

final class WindowPositionSaveStore {
    let saveURL: URL
    private let fileManager: FileManager

    init(fileManager: FileManager = .default, saveURL: URL? = nil) {
        self.fileManager = fileManager
        self.saveURL = saveURL ?? Self.defaultSaveURL(fileManager: fileManager)
    }

    func loadLatest() -> MoveEverythingSavedWindowPositionsSnapshot? {
        ensureDirectoryExists()
        guard fileManager.fileExists(atPath: saveURL.path) else {
            return nil
        }

        do {
            let data = try Data(contentsOf: saveURL)
            return try JSONDecoder().decode(MoveEverythingSavedWindowPositionsSnapshot.self, from: data)
        } catch {
            NSLog(
                "VibeGrid: failed to load saved window positions from %@: %@",
                saveURL.path,
                String(describing: error)
            )
            return nil
        }
    }

    @discardableResult
    func saveLatest(_ snapshot: MoveEverythingSavedWindowPositionsSnapshot?) -> Bool {
        ensureDirectoryExists()

        if snapshot == nil {
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
            let data = try JSONEncoder().encode(snapshot)
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
}
