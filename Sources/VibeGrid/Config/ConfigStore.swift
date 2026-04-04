import Foundation

final class ConfigStore {
    let configURL: URL
    let legacyConfigURL: URL?
    private let fileManager: FileManager
    /// Set when config parsing fails and defaults are restored. Cleared on successful load.
    private(set) var lastParseError: String?

    init(fileManager: FileManager = .default, configURL: URL? = nil, legacyConfigURL: URL? = nil) {
        self.fileManager = fileManager
        self.configURL = configURL ?? Self.defaultConfigURL(fileManager: fileManager)
        self.legacyConfigURL = legacyConfigURL ?? Self.defaultLegacyConfigURL(fileManager: fileManager)
    }

    func loadOrCreate() -> AppConfig {
        ensureDirectoryExists()
        migrateLegacyConfigIfNeeded()

        guard fileManager.fileExists(atPath: configURL.path) else {
            return saveDefaultConfig()
        }

        do {
            let raw = try String(contentsOf: configURL, encoding: .utf8)
            return decodeOrRestore(rawYAML: raw)
        } catch {
            NSLog("VibeGrid: failed to read config, restoring defaults. Error: %@", String(describing: error))
            return saveDefaultConfig()
        }
    }

    @discardableResult
    func save(_ config: AppConfig) -> Bool {
        ensureDirectoryExists()
        let text = YAMLConfigCodec.encode(config.normalized())
        do {
            try text.write(to: configURL, atomically: true, encoding: .utf8)
            return true
        } catch {
            NSLog("VibeGrid: failed to save config: %@", String(describing: error))
            return false
        }
    }

    func loadRawText() -> String {
        do {
            return try String(contentsOf: configURL, encoding: .utf8)
        } catch {
            return ""
        }
    }

    static func defaultConfigURL(fileManager: FileManager = .default) -> URL {
        if let configuredPath = ProcessInfo.processInfo.environment["VIBEGRID_CONFIG_PATH"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !configuredPath.isEmpty {
            let expandedPath = (configuredPath as NSString).expandingTildeInPath
            return URL(fileURLWithPath: expandedPath, isDirectory: false)
        }

        let appSupportBase = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ??
            fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)

        return appSupportBase
            .appendingPathComponent("VibeGrid", isDirectory: true)
            .appendingPathComponent("config.yaml", isDirectory: false)
    }

    static func defaultLegacyConfigURL(fileManager: FileManager = .default) -> URL {
        fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(".vibegrid", isDirectory: true)
            .appendingPathComponent("config.yaml", isDirectory: false)
    }

    private func ensureDirectoryExists() {
        let directory = configURL.deletingLastPathComponent()
        if !fileManager.fileExists(atPath: directory.path) {
            do {
                try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            } catch {
                NSLog("VibeGrid: failed to create config directory: %@", String(describing: error))
            }
        }
    }

    private func decodeOrRestore(rawYAML: String) -> AppConfig {
        do {
            let config = try YAMLConfigCodec.decode(rawYAML)
            lastParseError = nil
            return config
        } catch {
            let backupURL = backupInvalidConfig(rawYAML: rawYAML)
            let errorMessage = String(describing: error)
            lastParseError = "Config parse failed: \(errorMessage)"
            if let backupURL {
                lastParseError! += " — backed up to \(backupURL.lastPathComponent)"
                NSLog(
                    "VibeGrid: failed to parse config, restored defaults and backed up invalid file to %@. Error: %@",
                    backupURL.path,
                    errorMessage
                )
            } else {
                NSLog("VibeGrid: failed to parse config, restored defaults. Error: %@", errorMessage)
            }
            return saveDefaultConfig()
        }
    }

    private func saveDefaultConfig() -> AppConfig {
        let fallback = AppConfig.default.normalized()
        save(fallback)
        return fallback
    }

    private func backupInvalidConfig(rawYAML: String) -> URL? {
        guard !rawYAML.isEmpty else {
            return nil
        }

        let timestamp = Self.backupTimestampFormatter.string(from: Date())
        var candidate = configURL
            .deletingLastPathComponent()
            .appendingPathComponent("config.invalid-\(timestamp).yaml", isDirectory: false)
        var suffix = 1

        while fileManager.fileExists(atPath: candidate.path) {
            suffix += 1
            candidate = configURL
                .deletingLastPathComponent()
                .appendingPathComponent("config.invalid-\(timestamp)-\(suffix).yaml", isDirectory: false)
        }

        do {
            try rawYAML.write(to: candidate, atomically: true, encoding: .utf8)
            return candidate
        } catch {
            NSLog("VibeGrid: failed to back up invalid config: %@", String(describing: error))
            return nil
        }
    }

    private func migrateLegacyConfigIfNeeded() {
        guard let legacyConfigURL,
              legacyConfigURL.standardizedFileURL != configURL.standardizedFileURL else {
            return
        }

        guard !fileManager.fileExists(atPath: configURL.path),
              fileManager.fileExists(atPath: legacyConfigURL.path) else {
            return
        }

        do {
            try fileManager.copyItem(at: legacyConfigURL, to: configURL)
            NSLog(
                "VibeGrid: migrated config from legacy path %@ to %@",
                legacyConfigURL.path,
                configURL.path
            )
        } catch {
            NSLog(
                "VibeGrid: failed to migrate legacy config from %@ to %@: %@",
                legacyConfigURL.path,
                configURL.path,
                String(describing: error)
            )
        }
    }

    private static let backupTimestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }()
}
