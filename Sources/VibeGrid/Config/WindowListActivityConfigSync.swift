import Foundation

struct WindowListActivityConfigSync {
    struct ITermWindowOverride: Codable {
        let title: String
        let badgeText: String
        let badgeColor: String
        let badgeOpacity: Int
        let badgeSize: Int
    }

    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func sync(
        settings: Settings,
        iTermWindowOverridesByID: [String: ITermWindowOverride] = [:],
        iTermWindowOverridesByNumber: [Int: ITermWindowOverride] = [:]
    ) {
        let targetURL = Self.configURL(fileManager: fileManager)
        let directoryURL = targetURL.deletingLastPathComponent()
        let payload: Data
        do {
            payload = try JSONEncoder().encode(
                Payload(
                    settings: settings,
                    iTermWindowOverridesByID: iTermWindowOverridesByID,
                    iTermWindowOverridesByNumber: iTermWindowOverridesByNumber
                )
            )
        } catch {
            NSLog("VibeGrid: failed to encode Window List activity config: %@", String(describing: error))
            return
        }
        // File I/O dispatched to background to avoid stalling the main thread
        DispatchQueue.global(qos: .utility).async {
            do {
                try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
                try payload.write(to: targetURL, options: .atomic)
                WindowListDebugLogger.log(
                    "activity-sync",
                    "wrote activity config path=\(targetURL.path) overrideIDs=\(iTermWindowOverridesByID.keys.sorted()) " +
                        "overrideNumbers=\(iTermWindowOverridesByNumber.keys.sorted())"
                )
            } catch {
                NSLog(
                    "VibeGrid: failed to sync Window List activity config to %@: %@",
                    targetURL.path,
                    String(describing: error)
                )
                WindowListDebugLogger.log(
                    "activity-sync",
                    "failed to write activity config path=\(targetURL.path) error=\(String(describing: error))"
                )
            }
        }
    }

    static func configURL(fileManager: FileManager = .default) -> URL {
        let appSupportBase = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ??
            fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)

        return appSupportBase
            .appendingPathComponent("VibeGrid", isDirectory: true)
            .appendingPathComponent("window-list-activity.json", isDirectory: false)
    }

    private struct Payload: Codable {
        let moveEverythingITermRecentActivityTimeout: Double
        let moveEverythingITermRecentActivityActiveText: String
        let moveEverythingITermRecentActivityIdleText: String
        let moveEverythingITermRecentActivityBadgeEnabled: Bool
        let moveEverythingITermBadgeTopMargin: Int
        let moveEverythingITermBadgeRightMargin: Int
        let moveEverythingITermBadgeMaxWidth: Int
        let moveEverythingITermBadgeMaxHeight: Int
        let moveEverythingITermBadgeFromTitle: Bool
        let windowOverridesByID: [String: ITermWindowOverride]
        let windowOverridesByNumber: [String: ITermWindowOverride]

        init(
            settings: Settings,
            iTermWindowOverridesByID: [String: ITermWindowOverride],
            iTermWindowOverridesByNumber: [Int: ITermWindowOverride]
        ) {
            moveEverythingITermRecentActivityTimeout = settings.moveEverythingITermRecentActivityTimeout
            moveEverythingITermRecentActivityActiveText = settings.moveEverythingITermRecentActivityActiveText
            moveEverythingITermRecentActivityIdleText = settings.moveEverythingITermRecentActivityIdleText
            moveEverythingITermRecentActivityBadgeEnabled = settings.moveEverythingITermRecentActivityBadgeEnabled
            moveEverythingITermBadgeTopMargin = settings.moveEverythingITermBadgeTopMargin
            moveEverythingITermBadgeRightMargin = settings.moveEverythingITermBadgeRightMargin
            moveEverythingITermBadgeMaxWidth = settings.moveEverythingITermBadgeMaxWidth
            moveEverythingITermBadgeMaxHeight = settings.moveEverythingITermBadgeMaxHeight
            moveEverythingITermBadgeFromTitle = settings.moveEverythingITermBadgeFromTitle
            var encodedIDOverrides: [String: ITermWindowOverride] = [:]
            for key in iTermWindowOverridesByID.keys.sorted() {
                guard let override = iTermWindowOverridesByID[key] else {
                    continue
                }
                encodedIDOverrides[key] = override
            }
            var encodedOverrides: [String: ITermWindowOverride] = [:]
            for key in iTermWindowOverridesByNumber.keys.sorted() {
                guard let override = iTermWindowOverridesByNumber[key] else {
                    continue
                }
                encodedOverrides[String(key)] = override
            }
            windowOverridesByID = encodedIDOverrides
            windowOverridesByNumber = encodedOverrides
        }
    }
}
