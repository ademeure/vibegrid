import Foundation

enum MoveEverythingToggleResult {
    case started
    case stopped
    case failed(String)
}

struct MoveEverythingWindowSnapshot: Codable {
    let key: String
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
