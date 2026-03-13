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
    let windowNumber: Int?
    let iTermWindowID: String?
    let frame: MoveEverythingWindowFrameSnapshot?
    let title: String
    let appName: String
    let isControlCenter: Bool
    let iconDataURL: String?
    let isCoreGraphicsFallback: Bool
}

struct MoveEverythingWindowInventory: Codable {
    let visible: [MoveEverythingWindowSnapshot]
    let hidden: [MoveEverythingWindowSnapshot]
}
