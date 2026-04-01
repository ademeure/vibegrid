import Foundation
import CoreGraphics

protocol WindowManagerEngineProtocol: AnyObject {
    var isMoveEverythingAlwaysOnTopEnabledProvider: (() -> Bool)? { get set }
    var onMoveEverythingModeChanged: ((Bool) -> Void)? { get set }
    var onMoveEverythingInventoryRefreshed: (() -> Void)? { get set }
    var onMoveEverythingNameWindowRequested: ((String) -> Void)? { get set }
    var onMoveEverythingQuickViewRequested: (() -> Void)? { get set }
    var onMoveEverythingLatestSavedWindowPositionsChanged: ((MoveEverythingSavedWindowPositionsSnapshot?) -> Void)? { get set }
    var isMoveEverythingActive: Bool { get }
    var moveEverythingHoveredWindowKey: String? { get }

    func applyConfig(_ config: AppConfig)
    func requestAccessibility(prompt: Bool) -> Bool
    func setHotkeysSuspended(_ suspended: Bool)
    func previewRect(for placement: PlacementStep) -> CGRect?
    func registrationIssues() -> [HotKeyRegistrationIssue]
    func moveEverythingControlCenterFocused() -> Bool
    func moveEverythingFocusedWindowKeySnapshot() -> String?
    func moveEverythingWindowInventory() -> MoveEverythingWindowInventory
    func toggleMoveEverythingMode() -> MoveEverythingToggleResult
    func closeMoveEverythingWindow(withKey key: String) -> Bool
    func hideMoveEverythingWindow(withKey key: String) -> Bool
    func showHiddenMoveEverythingWindow(withKey key: String) -> Bool
    func showAllHiddenMoveEverythingWindows() -> Bool
    func saveCurrentMoveEverythingWindowPositions() -> MoveEverythingSavedWindowPositionsSnapshot?
    func restorePreviousMoveEverythingSavedWindowPositions() -> Bool
    func restoreNextMoveEverythingSavedWindowPositions() -> Bool
    func seedMoveEverythingSavedWindowPositions(_ snapshot: MoveEverythingSavedWindowPositionsSnapshot?)
    func moveEverythingSavedPositionsPreviousAvailable() -> Bool
    func moveEverythingSavedPositionsNextAvailable() -> Bool
    func focusMoveEverythingWindow(withKey key: String, movePointerToTopMiddle: Bool) -> Bool
    func centerMoveEverythingWindow(withKey key: String) -> Bool
    func maximizeMoveEverythingWindow(withKey key: String) -> Bool
    func retileVisibleMoveEverythingWindows() -> Bool
    func miniRetileVisibleMoveEverythingWindows() -> Bool
    func undoLastMoveEverythingRetile() -> Bool
    func moveEverythingUndoRetileAvailable() -> Bool
    func moveEverythingLastDirectActionError() -> String?
    func setMoveEverythingShowOverlays(_ enabled: Bool)
    func setMoveEverythingMoveToBottom(_ enabled: Bool)
    func setMoveEverythingDontMoveVibeGrid(_ enabled: Bool)
    func setMoveEverythingNarrowMode(_ enabled: Bool)
    func setMoveEverythingHoveredWindow(withKey key: String?) -> Bool
}
