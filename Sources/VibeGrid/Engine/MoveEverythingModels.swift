import Foundation

enum MoveEverythingToggleResult {
    case started
    case stopped
    case failed(String)
}

struct MoveEverythingWindowFrameSnapshot: Codable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double
}

struct MoveEverythingWindowSnapshot: Codable {
    let key: String
    let pid: Int32
    let windowNumber: Int?
    let iTermWindowID: String?
    let frame: MoveEverythingWindowFrameSnapshot?
    let title: String
    let appName: String
    let isControlCenter: Bool
    let iconDataURL: String?
    let isCoreGraphicsFallback: Bool
    let iTermWindowName: String?
    let iTermActivityStatus: String?
    let iTermBadgeText: String?
}

struct MoveEverythingWindowInventory: Codable {
    let visible: [MoveEverythingWindowSnapshot]
    let hidden: [MoveEverythingWindowSnapshot]
    let undoRetileAvailable: Bool
    let savedPositionsPreviousAvailable: Bool
    let savedPositionsNextAvailable: Bool
}

struct MoveEverythingSavedWindowPosition: Codable {
    let pid: Int32
    let appName: String
    let title: String
    let windowNumber: Int?
    let iTermWindowID: String?
    let frame: MoveEverythingWindowFrameSnapshot
    let captureOrder: Int
}

struct MoveEverythingSavedWindowPositionsSnapshot: Codable {
    let createdAt: Date
    let windows: [MoveEverythingSavedWindowPosition]
}
