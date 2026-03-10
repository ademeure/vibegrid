import Foundation
import Testing
@testable import VibeGrid

@Test func configStoreMigratesLegacyConfigWhenTargetIsMissing() throws {
    try withTemporaryDirectory { tempDirectory in
        let fileManager = FileManager.default
        let targetURL = tempDirectory
            .appendingPathComponent("Library/Application Support/VibeGrid", isDirectory: true)
            .appendingPathComponent("config.yaml", isDirectory: false)
        let legacyURL = tempDirectory
            .appendingPathComponent(".vibegrid", isDirectory: true)
            .appendingPathComponent("config.yaml", isDirectory: false)

        try fileManager.createDirectory(at: legacyURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let legacyConfig = AppConfig.default
        try YAMLConfigCodec.encode(legacyConfig).write(to: legacyURL, atomically: true, encoding: .utf8)

        let store = ConfigStore(fileManager: fileManager, configURL: targetURL, legacyConfigURL: legacyURL)
        let loaded = store.loadOrCreate()

        #expect(fileManager.fileExists(atPath: targetURL.path))
        #expect(loaded.shortcuts.count == legacyConfig.shortcuts.count)
        #expect(loaded.settings.defaultGridColumns == legacyConfig.settings.defaultGridColumns)
    }
}

@Test func configStoreKeepsExistingTargetConfigWhenLegacyFileExists() throws {
    try withTemporaryDirectory { tempDirectory in
        let fileManager = FileManager.default
        let targetURL = tempDirectory
            .appendingPathComponent("Library/Application Support/VibeGrid", isDirectory: true)
            .appendingPathComponent("config.yaml", isDirectory: false)
        let legacyURL = tempDirectory
            .appendingPathComponent(".vibegrid", isDirectory: true)
            .appendingPathComponent("config.yaml", isDirectory: false)

        try fileManager.createDirectory(at: targetURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fileManager.createDirectory(at: legacyURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        var targetConfig = AppConfig.default
        targetConfig.version = 7
        try YAMLConfigCodec.encode(targetConfig).write(to: targetURL, atomically: true, encoding: .utf8)

        var legacyConfig = AppConfig.default
        legacyConfig.version = 2
        try YAMLConfigCodec.encode(legacyConfig).write(to: legacyURL, atomically: true, encoding: .utf8)

        let store = ConfigStore(fileManager: fileManager, configURL: targetURL, legacyConfigURL: legacyURL)
        let loaded = store.loadOrCreate()

        #expect(loaded.version == 7)
    }
}

private func withTemporaryDirectory(_ body: (URL) throws -> Void) throws {
    let fileManager = FileManager.default
    let temporaryDirectory = fileManager.temporaryDirectory
        .appendingPathComponent("VibeGridTests-\(UUID().uuidString)", isDirectory: true)
    try fileManager.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    defer {
        try? fileManager.removeItem(at: temporaryDirectory)
    }
    try body(temporaryDirectory)
}
