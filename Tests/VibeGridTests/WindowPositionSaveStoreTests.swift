import Foundation
import Testing
@testable import VibeGrid

private func makeSnapshot(createdAt: Date, windowNumber: Int) -> MoveEverythingSavedWindowPositionsSnapshot {
    MoveEverythingSavedWindowPositionsSnapshot(
        createdAt: createdAt,
        windows: [
            MoveEverythingSavedWindowPosition(
                pid: 123,
                appName: "Test App",
                title: "Window \(windowNumber)",
                windowNumber: windowNumber,
                iTermWindowID: nil,
                frame: MoveEverythingWindowFrameSnapshot(
                    x: 10,
                    y: 20,
                    width: 300,
                    height: 200
                ),
                captureOrder: 0
            )
        ]
    )
}

private func withTemporarySaveStore(
    _ body: (WindowPositionSaveStore, URL) throws -> Void
) throws {
    let tempDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("VibeGridTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    let saveURL = tempDirectory.appendingPathComponent("window-position-save.json", isDirectory: false)
    let store = WindowPositionSaveStore(saveURL: saveURL)
    defer {
        try? FileManager.default.removeItem(at: tempDirectory)
    }
    try body(store, saveURL)
}

@Test func windowPositionSaveStoreLoadsLegacySingleSnapshot() throws {
    try withTemporarySaveStore { store, saveURL in
        let snapshot = makeSnapshot(
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            windowNumber: 7
        )
        let data = try JSONEncoder().encode(snapshot)
        try data.write(to: saveURL, options: .atomic)

        let loaded = store.loadSnapshots()

        #expect(loaded.count == 1)
        #expect(loaded.first?.windows.first?.windowNumber == 7)
    }
}

@Test func windowPositionSaveStoreRoundTripsSnapshotHistory() throws {
    try withTemporarySaveStore { store, _ in
        let snapshots = [
            makeSnapshot(
                createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                windowNumber: 1
            ),
            makeSnapshot(
                createdAt: Date(timeIntervalSince1970: 1_700_000_100),
                windowNumber: 2
            ),
        ]

        #expect(store.saveSnapshots(snapshots))

        let loaded = store.loadSnapshots()

        #expect(loaded.count == 2)
        #expect(loaded.map { $0.windows.first?.windowNumber } == [1, 2])
    }
}
