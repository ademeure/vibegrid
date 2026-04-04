import Foundation
import CoreGraphics

struct AppConfig: Codable {
    var version: Int
    var settings: Settings
    var shortcuts: [ShortcutConfig]

    static var `default`: AppConfig {
        AppConfig(
            version: 1,
            settings: Settings.default,
            shortcuts: [
                ShortcutConfig(
                    id: "cycle-left",
                    name: "Left",
                    hotkey: Hotkey(key: "keypad4", modifiers: ["ctrl"]),
                    placements: [
                        PlacementStep(
                            id: "left-half", title: "", mode: .grid, display: .active,
                            grid: GridPlacement(columns: 6, rows: 6, x: 0, y: 0, width: 3, height: 6), rect: nil
                        ),
                        PlacementStep(
                            id: "left-third", title: "", mode: .grid, display: .active,
                            grid: GridPlacement(columns: 6, rows: 6, x: 0, y: 0, width: 2, height: 6), rect: nil
                        )
                    ]
                ),
                ShortcutConfig(
                    id: "cycle-right",
                    name: "Right",
                    hotkey: Hotkey(key: "keypad6", modifiers: ["ctrl"]),
                    placements: [
                        PlacementStep(
                            id: "right-half", title: "", mode: .grid, display: .active,
                            grid: GridPlacement(columns: 6, rows: 6, x: 3, y: 0, width: 3, height: 6), rect: nil
                        ),
                        PlacementStep(
                            id: "right-third", title: "", mode: .grid, display: .active,
                            grid: GridPlacement(columns: 6, rows: 6, x: 4, y: 0, width: 2, height: 6), rect: nil
                        )
                    ]
                ),
                ShortcutConfig(
                    id: "cycle-center",
                    name: "Center",
                    hotkey: Hotkey(key: "keypad5", modifiers: ["ctrl"]),
                    placements: [
                        PlacementStep(
                            id: "full-screen", title: "", mode: .grid, display: .active,
                            grid: GridPlacement(columns: 6, rows: 6, x: 0, y: 0, width: 6, height: 6), rect: nil
                        ),
                        PlacementStep(
                            id: "center-third", title: "", mode: .grid, display: .active,
                            grid: GridPlacement(columns: 6, rows: 6, x: 2, y: 0, width: 2, height: 6), rect: nil
                        )
                    ]
                ),
                ShortcutConfig(
                    id: "cycle-top",
                    name: "Top",
                    hotkey: Hotkey(key: "keypad8", modifiers: ["ctrl"]),
                    placements: [
                        PlacementStep(
                            id: "top-full", title: "", mode: .grid, display: .active,
                            grid: GridPlacement(columns: 6, rows: 6, x: 0, y: 0, width: 6, height: 3), rect: nil
                        ),
                        PlacementStep(
                            id: "top-center", title: "", mode: .grid, display: .active,
                            grid: GridPlacement(columns: 6, rows: 6, x: 2, y: 0, width: 2, height: 3), rect: nil
                        )
                    ]
                ),
                ShortcutConfig(
                    id: "cycle-bottom",
                    name: "Bottom",
                    hotkey: Hotkey(key: "keypad2", modifiers: ["ctrl"]),
                    placements: [
                        PlacementStep(
                            id: "bottom-full", title: "", mode: .grid, display: .active,
                            grid: GridPlacement(columns: 6, rows: 6, x: 0, y: 3, width: 6, height: 3), rect: nil
                        ),
                        PlacementStep(
                            id: "bottom-center", title: "", mode: .grid, display: .active,
                            grid: GridPlacement(columns: 6, rows: 6, x: 2, y: 3, width: 2, height: 3), rect: nil
                        )
                    ]
                ),
                ShortcutConfig(
                    id: "cycle-top-left",
                    name: "Top Left",
                    hotkey: Hotkey(key: "keypad7", modifiers: ["ctrl"]),
                    placements: [
                        PlacementStep(
                            id: "top-left-half", title: "", mode: .grid, display: .active,
                            grid: GridPlacement(columns: 6, rows: 6, x: 0, y: 0, width: 3, height: 3), rect: nil
                        ),
                        PlacementStep(
                            id: "top-left-third", title: "", mode: .grid, display: .active,
                            grid: GridPlacement(columns: 6, rows: 6, x: 0, y: 0, width: 2, height: 3), rect: nil
                        )
                    ]
                ),
                ShortcutConfig(
                    id: "cycle-top-right",
                    name: "Top Right",
                    hotkey: Hotkey(key: "keypad9", modifiers: ["ctrl"]),
                    placements: [
                        PlacementStep(
                            id: "top-right-half", title: "", mode: .grid, display: .active,
                            grid: GridPlacement(columns: 6, rows: 6, x: 3, y: 0, width: 3, height: 3), rect: nil
                        ),
                        PlacementStep(
                            id: "top-right-third", title: "", mode: .grid, display: .active,
                            grid: GridPlacement(columns: 6, rows: 6, x: 4, y: 0, width: 2, height: 3), rect: nil
                        )
                    ]
                ),
                ShortcutConfig(
                    id: "cycle-bottom-left",
                    name: "Bottom Left",
                    hotkey: Hotkey(key: "keypad1", modifiers: ["ctrl"]),
                    placements: [
                        PlacementStep(
                            id: "bottom-left-half", title: "", mode: .grid, display: .active,
                            grid: GridPlacement(columns: 6, rows: 6, x: 0, y: 3, width: 3, height: 3), rect: nil
                        ),
                        PlacementStep(
                            id: "bottom-left-third", title: "", mode: .grid, display: .active,
                            grid: GridPlacement(columns: 6, rows: 6, x: 0, y: 3, width: 2, height: 3), rect: nil
                        )
                    ]
                ),
                ShortcutConfig(
                    id: "cycle-bottom-right",
                    name: "Bottom Right",
                    hotkey: Hotkey(key: "keypad3", modifiers: ["ctrl"]),
                    placements: [
                        PlacementStep(
                            id: "bottom-right-half", title: "", mode: .grid, display: .active,
                            grid: GridPlacement(columns: 6, rows: 6, x: 3, y: 3, width: 3, height: 3), rect: nil
                        ),
                        PlacementStep(
                            id: "bottom-right-third", title: "", mode: .grid, display: .active,
                            grid: GridPlacement(columns: 6, rows: 6, x: 4, y: 3, width: 2, height: 3), rect: nil
                        )
                    ]
                )
            ]
        )
    }
}

struct Settings: Codable {
    enum ThemeMode: String, Codable {
        case system
        case light
        case dark
    }

    enum MoveEverythingOverlayMode: String, Codable {
        case persistent
        case timed
    }

    enum MoveEverythingMoveOnSelectionMode: String, Codable {
        case never
        case miniControlCenterOnTop
        case firstSelection
        case always

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            let rawValue = (try? container.decode(String.self))?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased() ?? ""

            switch rawValue {
            case "never":
                self = .never
            case "minicontrolcenterontop", "advancedcontrolcenterontop", "controlcenteronce", "controlcenteronly":
                self = .miniControlCenterOnTop
            case "firstselection":
                self = .firstSelection
            case "always":
                self = .always
            default:
                self = .miniControlCenterOnTop
            }
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode(rawValue)
        }
    }

    var defaultGridColumns: Int
    var defaultGridRows: Int
    var gap: Int
    var defaultCycleDisplaysOnWrap: Bool
    var animationDuration: Double
    var controlCenterScale: Double
    var largerFonts: Bool
    var themeMode: ThemeMode
    var moveEverythingMoveOnSelection: MoveEverythingMoveOnSelectionMode
    var moveEverythingCenterWidthPercent: Double
    var moveEverythingCenterHeightPercent: Double
    var moveEverythingOverlayMode: MoveEverythingOverlayMode
    var moveEverythingOverlayDuration: Double
    var moveEverythingStartAlwaysOnTop: Bool
    var moveEverythingStartMoveToBottom: Bool
    var moveEverythingStartDontMoveVibeGrid: Bool
    var moveEverythingAdvancedControlCenterHover: Bool
    var moveEverythingStickyHoverStealFocus: Bool
    var moveEverythingCloseHideHotkeysOutsideMode: Bool
    var moveEverythingExcludeControlCenter: Bool
    var moveEverythingMiniRetileWidthPercent: Double
    var moveEverythingBackgroundRefreshInterval: Double
    var moveEverythingITermRecentActivityTimeout: Double
    var moveEverythingITermRecentActivityBuffer: Double
    var moveEverythingITermRecentActivityActiveText: String
    var moveEverythingITermRecentActivityIdleText: String
    var moveEverythingITermRecentActivityBadgeEnabled: Bool
    var moveEverythingITermRecentActivityColorize: Bool
    var moveEverythingITermRecentActivityColorizeNamedOnly: Bool
    var moveEverythingITermActivityTintIntensity: Double
    var moveEverythingITermActivityHoldSeconds: Double
    var moveEverythingITermActivityOverlayOpacity: Double
    var moveEverythingITermActivityBackgroundTintEnabled: Bool
    var moveEverythingITermActivityTabColorEnabled: Bool
    var moveEverythingActiveWindowHighlightColorize: Bool
    var moveEverythingActiveWindowHighlightColor: String
    var moveEverythingITermRecentActivityActiveColor: String
    var moveEverythingITermRecentActivityIdleColor: String
    var moveEverythingITermRecentActivityActiveColorLight: String
    var moveEverythingITermRecentActivityIdleColorLight: String
    var moveEverythingITermBadgeTopMargin: Int
    var moveEverythingITermBadgeRightMargin: Int
    var moveEverythingITermBadgeMaxWidth: Int
    var moveEverythingITermBadgeMaxHeight: Int
    var moveEverythingITermBadgeFromTitle: Bool
    var moveEverythingITermTitleFromBadge: Bool
    var moveEverythingITermTitleAllCaps: Bool
    var controlCenterFrameX: Double?
    var controlCenterFrameY: Double?
    var controlCenterFrameWidth: Double?
    var controlCenterFrameHeight: Double?
    var moveEverythingCloseWindowHotkey: Hotkey?
    var moveEverythingHideWindowHotkey: Hotkey?
    var moveEverythingNameWindowHotkey: Hotkey?
    var moveEverythingQuickViewHotkey: Hotkey?
    var moveEverythingUndoWindowMovementHotkey: Hotkey?
    var moveEverythingRedoWindowMovementHotkey: Hotkey?

    static var `default`: Settings {
        Settings(
            defaultGridColumns: 12,
            defaultGridRows: 8,
            gap: 2,
            defaultCycleDisplaysOnWrap: false,
            animationDuration: 0.0,
            controlCenterScale: 1.0,
            largerFonts: true,
            themeMode: .system,
            moveEverythingMoveOnSelection: .miniControlCenterOnTop,
            moveEverythingCenterWidthPercent: 33,
            moveEverythingCenterHeightPercent: 70,
            moveEverythingOverlayMode: .persistent,
            moveEverythingOverlayDuration: 2,
            moveEverythingStartAlwaysOnTop: false,
            moveEverythingStartMoveToBottom: false,
            moveEverythingStartDontMoveVibeGrid: false,
            moveEverythingAdvancedControlCenterHover: true,
            moveEverythingStickyHoverStealFocus: false,
            moveEverythingCloseHideHotkeysOutsideMode: false,
            moveEverythingExcludeControlCenter: false,
            moveEverythingMiniRetileWidthPercent: 25,
            moveEverythingBackgroundRefreshInterval: 2,
            moveEverythingITermRecentActivityTimeout: 1,
            moveEverythingITermRecentActivityBuffer: 4,
            moveEverythingITermRecentActivityActiveText: "[ACTIVE]",
            moveEverythingITermRecentActivityIdleText: "",
            moveEverythingITermRecentActivityBadgeEnabled: false,
            moveEverythingITermRecentActivityColorize: true,
            moveEverythingITermRecentActivityColorizeNamedOnly: false,
            moveEverythingITermActivityTintIntensity: 0.25,
            moveEverythingITermActivityHoldSeconds: 7.0,
            moveEverythingITermActivityOverlayOpacity: 0.0,
            moveEverythingITermActivityBackgroundTintEnabled: false,
            moveEverythingITermActivityTabColorEnabled: false,
            moveEverythingActiveWindowHighlightColorize: true,
            moveEverythingActiveWindowHighlightColor: "#4D88D4",
            moveEverythingITermRecentActivityActiveColor: "#2F8F4E",
            moveEverythingITermRecentActivityIdleColor: "#BA4D4D",
            moveEverythingITermRecentActivityActiveColorLight: "#1A7535",
            moveEverythingITermRecentActivityIdleColorLight: "#A03030",
            moveEverythingITermBadgeTopMargin: 6,
            moveEverythingITermBadgeRightMargin: 8,
            moveEverythingITermBadgeMaxWidth: 120,
            moveEverythingITermBadgeMaxHeight: 28,
            moveEverythingITermBadgeFromTitle: true,
            moveEverythingITermTitleFromBadge: true,
            moveEverythingITermTitleAllCaps: false,
            controlCenterFrameX: nil,
            controlCenterFrameY: nil,
            controlCenterFrameWidth: nil,
            controlCenterFrameHeight: nil,
            moveEverythingCloseWindowHotkey: nil,
            moveEverythingHideWindowHotkey: nil,
            moveEverythingNameWindowHotkey: nil,
            moveEverythingQuickViewHotkey: nil,
            moveEverythingUndoWindowMovementHotkey: nil,
            moveEverythingRedoWindowMovementHotkey: nil
        )
    }

    init(
        defaultGridColumns: Int,
        defaultGridRows: Int,
        gap: Int,
        defaultCycleDisplaysOnWrap: Bool,
        animationDuration: Double,
        controlCenterScale: Double = 1.0,
        largerFonts: Bool = true,
        themeMode: ThemeMode = .system,
        moveEverythingMoveOnSelection: MoveEverythingMoveOnSelectionMode = .miniControlCenterOnTop,
        moveEverythingCenterWidthPercent: Double = 33,
        moveEverythingCenterHeightPercent: Double = 70,
        moveEverythingOverlayMode: MoveEverythingOverlayMode = .persistent,
        moveEverythingOverlayDuration: Double = 2,
        moveEverythingStartAlwaysOnTop: Bool = false,
        moveEverythingStartMoveToBottom: Bool = false,
        moveEverythingStartDontMoveVibeGrid: Bool = false,
        moveEverythingAdvancedControlCenterHover: Bool = true,
        moveEverythingStickyHoverStealFocus: Bool = false,
        moveEverythingCloseHideHotkeysOutsideMode: Bool = false,
        moveEverythingExcludeControlCenter: Bool = false,
        moveEverythingMiniRetileWidthPercent: Double = 25,
        moveEverythingBackgroundRefreshInterval: Double = 2,
        moveEverythingITermRecentActivityTimeout: Double = 1,
        moveEverythingITermRecentActivityBuffer: Double = 4,
        moveEverythingITermRecentActivityActiveText: String = "[ACTIVE]",
        moveEverythingITermRecentActivityIdleText: String = "",
        moveEverythingITermRecentActivityBadgeEnabled: Bool = false,
        moveEverythingITermRecentActivityColorize: Bool = true,
        moveEverythingITermRecentActivityColorizeNamedOnly: Bool = false,
        moveEverythingITermActivityTintIntensity: Double = 0.25,
        moveEverythingITermActivityHoldSeconds: Double = 7.0,
        moveEverythingITermActivityOverlayOpacity: Double = 0.14,
        moveEverythingITermActivityBackgroundTintEnabled: Bool = false,
        moveEverythingITermActivityTabColorEnabled: Bool = false,
        moveEverythingActiveWindowHighlightColorize: Bool = true,
        moveEverythingActiveWindowHighlightColor: String = "#4D88D4",
        moveEverythingITermRecentActivityActiveColor: String = "#2F8F4E",
        moveEverythingITermRecentActivityIdleColor: String = "#BA4D4D",
        moveEverythingITermRecentActivityActiveColorLight: String = "#1A7535",
        moveEverythingITermRecentActivityIdleColorLight: String = "#A03030",
        moveEverythingITermBadgeTopMargin: Int = 6,
        moveEverythingITermBadgeRightMargin: Int = 8,
        moveEverythingITermBadgeMaxWidth: Int = 120,
        moveEverythingITermBadgeMaxHeight: Int = 28,
        moveEverythingITermBadgeFromTitle: Bool = false,
        moveEverythingITermTitleFromBadge: Bool = true,
        moveEverythingITermTitleAllCaps: Bool = false,
        controlCenterFrameX: Double? = nil,
        controlCenterFrameY: Double? = nil,
        controlCenterFrameWidth: Double? = nil,
        controlCenterFrameHeight: Double? = nil,
        moveEverythingCloseWindowHotkey: Hotkey? = nil,
        moveEverythingHideWindowHotkey: Hotkey? = nil,
        moveEverythingNameWindowHotkey: Hotkey? = nil,
        moveEverythingQuickViewHotkey: Hotkey? = nil,
        moveEverythingUndoWindowMovementHotkey: Hotkey? = nil,
        moveEverythingRedoWindowMovementHotkey: Hotkey? = nil
    ) {
        self.defaultGridColumns = defaultGridColumns
        self.defaultGridRows = defaultGridRows
        self.gap = gap
        self.defaultCycleDisplaysOnWrap = defaultCycleDisplaysOnWrap
        self.animationDuration = animationDuration
        self.controlCenterScale = controlCenterScale
        self.largerFonts = largerFonts
        self.themeMode = themeMode
        self.moveEverythingMoveOnSelection = moveEverythingMoveOnSelection
        self.moveEverythingCenterWidthPercent = moveEverythingCenterWidthPercent
        self.moveEverythingCenterHeightPercent = moveEverythingCenterHeightPercent
        self.moveEverythingOverlayMode = moveEverythingOverlayMode
        self.moveEverythingOverlayDuration = moveEverythingOverlayDuration
        self.moveEverythingStartAlwaysOnTop = moveEverythingStartAlwaysOnTop
        self.moveEverythingStartMoveToBottom = moveEverythingStartMoveToBottom
        self.moveEverythingStartDontMoveVibeGrid = moveEverythingStartDontMoveVibeGrid
        self.moveEverythingAdvancedControlCenterHover = moveEverythingAdvancedControlCenterHover
        self.moveEverythingStickyHoverStealFocus = moveEverythingStickyHoverStealFocus
        self.moveEverythingCloseHideHotkeysOutsideMode = moveEverythingCloseHideHotkeysOutsideMode
        self.moveEverythingExcludeControlCenter = moveEverythingExcludeControlCenter
        self.moveEverythingMiniRetileWidthPercent = moveEverythingMiniRetileWidthPercent
        self.moveEverythingBackgroundRefreshInterval = moveEverythingBackgroundRefreshInterval
        self.moveEverythingITermRecentActivityTimeout = moveEverythingITermRecentActivityTimeout
        self.moveEverythingITermRecentActivityBuffer = moveEverythingITermRecentActivityBuffer
        self.moveEverythingITermRecentActivityActiveText = moveEverythingITermRecentActivityActiveText
        self.moveEverythingITermRecentActivityIdleText = moveEverythingITermRecentActivityIdleText
        self.moveEverythingITermRecentActivityBadgeEnabled = moveEverythingITermRecentActivityBadgeEnabled
        self.moveEverythingITermRecentActivityColorize = moveEverythingITermRecentActivityColorize
        self.moveEverythingITermRecentActivityColorizeNamedOnly = moveEverythingITermRecentActivityColorizeNamedOnly
        self.moveEverythingITermActivityTintIntensity = moveEverythingITermActivityTintIntensity
        self.moveEverythingITermActivityHoldSeconds = moveEverythingITermActivityHoldSeconds
        self.moveEverythingITermActivityOverlayOpacity = moveEverythingITermActivityOverlayOpacity
        self.moveEverythingITermActivityBackgroundTintEnabled = moveEverythingITermActivityBackgroundTintEnabled
        self.moveEverythingITermActivityTabColorEnabled = moveEverythingITermActivityTabColorEnabled
        self.moveEverythingActiveWindowHighlightColorize = moveEverythingActiveWindowHighlightColorize
        self.moveEverythingActiveWindowHighlightColor = moveEverythingActiveWindowHighlightColor
        self.moveEverythingITermRecentActivityActiveColor = moveEverythingITermRecentActivityActiveColor
        self.moveEverythingITermRecentActivityIdleColor = moveEverythingITermRecentActivityIdleColor
        self.moveEverythingITermRecentActivityActiveColorLight = moveEverythingITermRecentActivityActiveColorLight
        self.moveEverythingITermRecentActivityIdleColorLight = moveEverythingITermRecentActivityIdleColorLight
        self.moveEverythingITermBadgeTopMargin = moveEverythingITermBadgeTopMargin
        self.moveEverythingITermBadgeRightMargin = moveEverythingITermBadgeRightMargin
        self.moveEverythingITermBadgeMaxWidth = moveEverythingITermBadgeMaxWidth
        self.moveEverythingITermBadgeMaxHeight = moveEverythingITermBadgeMaxHeight
        self.moveEverythingITermBadgeFromTitle = moveEverythingITermBadgeFromTitle
        self.moveEverythingITermTitleFromBadge = moveEverythingITermTitleFromBadge
        self.moveEverythingITermTitleAllCaps = moveEverythingITermTitleAllCaps
        self.controlCenterFrameX = controlCenterFrameX
        self.controlCenterFrameY = controlCenterFrameY
        self.controlCenterFrameWidth = controlCenterFrameWidth
        self.controlCenterFrameHeight = controlCenterFrameHeight
        self.moveEverythingCloseWindowHotkey = moveEverythingCloseWindowHotkey
        self.moveEverythingHideWindowHotkey = moveEverythingHideWindowHotkey
        self.moveEverythingNameWindowHotkey = moveEverythingNameWindowHotkey
        self.moveEverythingQuickViewHotkey = moveEverythingQuickViewHotkey
        self.moveEverythingUndoWindowMovementHotkey = moveEverythingUndoWindowMovementHotkey
        self.moveEverythingRedoWindowMovementHotkey = moveEverythingRedoWindowMovementHotkey
    }

    enum CodingKeys: String, CodingKey {
        case defaultGridColumns
        case defaultGridRows
        case gap
        case defaultCycleDisplaysOnWrap
        case animationDuration
        case controlCenterScale
        case largerFonts
        case themeMode
        case darkMode
        case moveEverythingMoveOnSelection
        case moveEverythingCenterWidthPercent
        case moveEverythingCenterHeightPercent
        case moveEverythingOverlayMode
        case moveEverythingOverlayDuration
        case moveEverythingStartAlwaysOnTop
        case moveEverythingStartMoveToBottom
        case moveEverythingStartDontMoveVibeGrid
        case moveEverythingAdvancedControlCenterHover
        case moveEverythingStickyHoverStealFocus
        case moveEverythingCloseHideHotkeysOutsideMode
        case moveEverythingExcludeControlCenter
        case moveEverythingMiniRetileWidthPercent
        case moveEverythingBackgroundRefreshInterval
        case moveEverythingITermRecentActivityTimeout
        case moveEverythingITermRecentActivityBuffer
        case moveEverythingITermRecentActivityActiveText
        case moveEverythingITermRecentActivityIdleText
        case moveEverythingITermRecentActivityBadgeEnabled
        case moveEverythingITermRecentActivityColorize
        case moveEverythingITermRecentActivityColorizeNamedOnly
        case moveEverythingITermActivityTintIntensity
        case moveEverythingITermActivityHoldSeconds
        case moveEverythingITermActivityOverlayOpacity
        case moveEverythingITermActivityBackgroundTintEnabled
        case moveEverythingITermActivityTabColorEnabled
        case moveEverythingActiveWindowHighlightColorize
        case moveEverythingActiveWindowHighlightColor
        case moveEverythingITermRecentActivityActiveColor
        case moveEverythingITermRecentActivityIdleColor
        case moveEverythingITermRecentActivityActiveColorLight
        case moveEverythingITermRecentActivityIdleColorLight
        case moveEverythingITermBadgeTopMargin
        case moveEverythingITermBadgeRightMargin
        case moveEverythingITermBadgeMaxWidth
        case moveEverythingITermBadgeMaxHeight
        case moveEverythingITermBadgeFromTitle
        case moveEverythingITermTitleFromBadge
        case moveEverythingITermTitleAllCaps
        case controlCenterFrameX
        case controlCenterFrameY
        case controlCenterFrameWidth
        case controlCenterFrameHeight
        case moveEverythingCloseWindowHotkey
        case moveEverythingHideWindowHotkey
        case moveEverythingNameWindowHotkey
        case moveEverythingQuickViewHotkey
        case moveEverythingUndoWindowMovementHotkey
        case moveEverythingRedoWindowMovementHotkey
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        defaultGridColumns = try container.decodeIfPresent(Int.self, forKey: .defaultGridColumns) ?? 12
        defaultGridRows = try container.decodeIfPresent(Int.self, forKey: .defaultGridRows) ?? 8
        gap = try container.decodeIfPresent(Int.self, forKey: .gap) ?? 2
        defaultCycleDisplaysOnWrap = try container.decodeIfPresent(Bool.self, forKey: .defaultCycleDisplaysOnWrap) ?? false
        animationDuration = try container.decodeIfPresent(Double.self, forKey: .animationDuration) ?? 0
        controlCenterScale = try container.decodeIfPresent(Double.self, forKey: .controlCenterScale) ?? 1.0
        largerFonts = try container.decodeIfPresent(Bool.self, forKey: .largerFonts) ?? true
        moveEverythingMoveOnSelection = try container.decodeIfPresent(
            MoveEverythingMoveOnSelectionMode.self,
            forKey: .moveEverythingMoveOnSelection
        ) ?? .miniControlCenterOnTop
        moveEverythingCenterWidthPercent = try container.decodeIfPresent(Double.self, forKey: .moveEverythingCenterWidthPercent) ?? 33
        moveEverythingCenterHeightPercent = try container.decodeIfPresent(Double.self, forKey: .moveEverythingCenterHeightPercent) ?? 70
        moveEverythingOverlayMode = try container.decodeIfPresent(MoveEverythingOverlayMode.self, forKey: .moveEverythingOverlayMode) ?? .persistent
        moveEverythingOverlayDuration = try container.decodeIfPresent(Double.self, forKey: .moveEverythingOverlayDuration) ?? 2
        moveEverythingStartAlwaysOnTop = try container.decodeIfPresent(Bool.self, forKey: .moveEverythingStartAlwaysOnTop) ?? false
        moveEverythingStartMoveToBottom = try container.decodeIfPresent(Bool.self, forKey: .moveEverythingStartMoveToBottom) ?? false
        moveEverythingStartDontMoveVibeGrid = try container.decodeIfPresent(Bool.self, forKey: .moveEverythingStartDontMoveVibeGrid) ?? false
        moveEverythingAdvancedControlCenterHover = try container.decodeIfPresent(Bool.self, forKey: .moveEverythingAdvancedControlCenterHover) ?? true
        moveEverythingStickyHoverStealFocus = try container.decodeIfPresent(Bool.self, forKey: .moveEverythingStickyHoverStealFocus) ?? false
        moveEverythingCloseHideHotkeysOutsideMode = try container.decodeIfPresent(
            Bool.self,
            forKey: .moveEverythingCloseHideHotkeysOutsideMode
        ) ?? false
        moveEverythingExcludeControlCenter = try container.decodeIfPresent(Bool.self, forKey: .moveEverythingExcludeControlCenter) ?? false
        moveEverythingMiniRetileWidthPercent = try container.decodeIfPresent(Double.self, forKey: .moveEverythingMiniRetileWidthPercent) ?? 25
        moveEverythingBackgroundRefreshInterval = try container.decodeIfPresent(Double.self, forKey: .moveEverythingBackgroundRefreshInterval) ?? 2
        moveEverythingITermRecentActivityTimeout = try container.decodeIfPresent(
            Double.self,
            forKey: .moveEverythingITermRecentActivityTimeout
        ) ?? 1
        moveEverythingITermRecentActivityBuffer = try container.decodeIfPresent(
            Double.self,
            forKey: .moveEverythingITermRecentActivityBuffer
        ) ?? 4
        moveEverythingITermRecentActivityActiveText = try container.decodeIfPresent(
            String.self,
            forKey: .moveEverythingITermRecentActivityActiveText
        ) ?? "[ACTIVE]"
        moveEverythingITermRecentActivityIdleText = try container.decodeIfPresent(
            String.self,
            forKey: .moveEverythingITermRecentActivityIdleText
        ) ?? ""
        moveEverythingITermRecentActivityBadgeEnabled = try container.decodeIfPresent(
            Bool.self,
            forKey: .moveEverythingITermRecentActivityBadgeEnabled
        ) ?? false
        moveEverythingITermRecentActivityColorize = try container.decodeIfPresent(
            Bool.self,
            forKey: .moveEverythingITermRecentActivityColorize
        ) ?? true
        moveEverythingITermRecentActivityColorizeNamedOnly = try container.decodeIfPresent(
            Bool.self,
            forKey: .moveEverythingITermRecentActivityColorizeNamedOnly
        ) ?? false
        moveEverythingITermActivityTintIntensity = try container.decodeIfPresent(
            Double.self,
            forKey: .moveEverythingITermActivityTintIntensity
        ) ?? 0.25
        moveEverythingITermActivityHoldSeconds = try container.decodeIfPresent(
            Double.self,
            forKey: .moveEverythingITermActivityHoldSeconds
        ) ?? 7.0
        moveEverythingITermActivityOverlayOpacity = try container.decodeIfPresent(
            Double.self,
            forKey: .moveEverythingITermActivityOverlayOpacity
        ) ?? 0.14
        moveEverythingITermActivityBackgroundTintEnabled = try container.decodeIfPresent(
            Bool.self,
            forKey: .moveEverythingITermActivityBackgroundTintEnabled
        ) ?? false
        moveEverythingITermActivityTabColorEnabled = try container.decodeIfPresent(
            Bool.self,
            forKey: .moveEverythingITermActivityTabColorEnabled
        ) ?? false
        moveEverythingActiveWindowHighlightColorize = try container.decodeIfPresent(
            Bool.self,
            forKey: .moveEverythingActiveWindowHighlightColorize
        ) ?? true
        moveEverythingActiveWindowHighlightColor = try container.decodeIfPresent(
            String.self,
            forKey: .moveEverythingActiveWindowHighlightColor
        ) ?? "#4D88D4"
        moveEverythingITermRecentActivityActiveColor = try container.decodeIfPresent(
            String.self,
            forKey: .moveEverythingITermRecentActivityActiveColor
        ) ?? "#2F8F4E"
        moveEverythingITermRecentActivityIdleColor = try container.decodeIfPresent(
            String.self,
            forKey: .moveEverythingITermRecentActivityIdleColor
        ) ?? "#BA4D4D"
        moveEverythingITermRecentActivityActiveColorLight = try container.decodeIfPresent(
            String.self,
            forKey: .moveEverythingITermRecentActivityActiveColorLight
        ) ?? "#1A7535"
        moveEverythingITermRecentActivityIdleColorLight = try container.decodeIfPresent(
            String.self,
            forKey: .moveEverythingITermRecentActivityIdleColorLight
        ) ?? "#A03030"
        moveEverythingITermBadgeTopMargin = try container.decodeIfPresent(
            Int.self,
            forKey: .moveEverythingITermBadgeTopMargin
        ) ?? 6
        moveEverythingITermBadgeRightMargin = try container.decodeIfPresent(
            Int.self,
            forKey: .moveEverythingITermBadgeRightMargin
        ) ?? 8
        moveEverythingITermBadgeMaxWidth = try container.decodeIfPresent(
            Int.self,
            forKey: .moveEverythingITermBadgeMaxWidth
        ) ?? 120
        moveEverythingITermBadgeMaxHeight = try container.decodeIfPresent(
            Int.self,
            forKey: .moveEverythingITermBadgeMaxHeight
        ) ?? 28
        moveEverythingITermBadgeFromTitle = try container.decodeIfPresent(
            Bool.self,
            forKey: .moveEverythingITermBadgeFromTitle
        ) ?? false
        moveEverythingITermTitleFromBadge = try container.decodeIfPresent(
            Bool.self,
            forKey: .moveEverythingITermTitleFromBadge
        ) ?? true
        moveEverythingITermTitleAllCaps = try container.decodeIfPresent(
            Bool.self,
            forKey: .moveEverythingITermTitleAllCaps
        ) ?? false
        controlCenterFrameX = try container.decodeIfPresent(Double.self, forKey: .controlCenterFrameX)
        controlCenterFrameY = try container.decodeIfPresent(Double.self, forKey: .controlCenterFrameY)
        controlCenterFrameWidth = try container.decodeIfPresent(Double.self, forKey: .controlCenterFrameWidth)
        controlCenterFrameHeight = try container.decodeIfPresent(Double.self, forKey: .controlCenterFrameHeight)
        moveEverythingCloseWindowHotkey = try container.decodeIfPresent(Hotkey.self, forKey: .moveEverythingCloseWindowHotkey)
        moveEverythingHideWindowHotkey = try container.decodeIfPresent(Hotkey.self, forKey: .moveEverythingHideWindowHotkey)
        moveEverythingNameWindowHotkey = try container.decodeIfPresent(Hotkey.self, forKey: .moveEverythingNameWindowHotkey)
        moveEverythingQuickViewHotkey = try container.decodeIfPresent(Hotkey.self, forKey: .moveEverythingQuickViewHotkey)
        moveEverythingUndoWindowMovementHotkey = try container.decodeIfPresent(
            Hotkey.self,
            forKey: .moveEverythingUndoWindowMovementHotkey
        )
        moveEverythingRedoWindowMovementHotkey = try container.decodeIfPresent(
            Hotkey.self,
            forKey: .moveEverythingRedoWindowMovementHotkey
        )
        if let decodedThemeMode = try container.decodeIfPresent(ThemeMode.self, forKey: .themeMode) {
            themeMode = decodedThemeMode
        } else {
            let legacyDarkMode = try container.decodeIfPresent(Bool.self, forKey: .darkMode) ?? false
            themeMode = legacyDarkMode ? .dark : .system
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(defaultGridColumns, forKey: .defaultGridColumns)
        try container.encode(defaultGridRows, forKey: .defaultGridRows)
        try container.encode(gap, forKey: .gap)
        try container.encode(defaultCycleDisplaysOnWrap, forKey: .defaultCycleDisplaysOnWrap)
        try container.encode(animationDuration, forKey: .animationDuration)
        try container.encode(controlCenterScale, forKey: .controlCenterScale)
        try container.encode(largerFonts, forKey: .largerFonts)
        try container.encode(themeMode, forKey: .themeMode)
        try container.encode(moveEverythingMoveOnSelection, forKey: .moveEverythingMoveOnSelection)
        try container.encode(moveEverythingCenterWidthPercent, forKey: .moveEverythingCenterWidthPercent)
        try container.encode(moveEverythingCenterHeightPercent, forKey: .moveEverythingCenterHeightPercent)
        try container.encode(moveEverythingOverlayMode, forKey: .moveEverythingOverlayMode)
        try container.encode(moveEverythingOverlayDuration, forKey: .moveEverythingOverlayDuration)
        try container.encode(moveEverythingStartAlwaysOnTop, forKey: .moveEverythingStartAlwaysOnTop)
        try container.encode(moveEverythingStartMoveToBottom, forKey: .moveEverythingStartMoveToBottom)
        try container.encode(moveEverythingStartDontMoveVibeGrid, forKey: .moveEverythingStartDontMoveVibeGrid)
        try container.encode(moveEverythingAdvancedControlCenterHover, forKey: .moveEverythingAdvancedControlCenterHover)
        try container.encode(moveEverythingStickyHoverStealFocus, forKey: .moveEverythingStickyHoverStealFocus)
        try container.encode(
            moveEverythingCloseHideHotkeysOutsideMode,
            forKey: .moveEverythingCloseHideHotkeysOutsideMode
        )
        try container.encode(moveEverythingExcludeControlCenter, forKey: .moveEverythingExcludeControlCenter)
        try container.encode(moveEverythingMiniRetileWidthPercent, forKey: .moveEverythingMiniRetileWidthPercent)
        try container.encode(moveEverythingBackgroundRefreshInterval, forKey: .moveEverythingBackgroundRefreshInterval)
        try container.encode(moveEverythingITermRecentActivityTimeout, forKey: .moveEverythingITermRecentActivityTimeout)
        try container.encode(moveEverythingITermRecentActivityBuffer, forKey: .moveEverythingITermRecentActivityBuffer)
        try container.encode(moveEverythingITermRecentActivityActiveText, forKey: .moveEverythingITermRecentActivityActiveText)
        try container.encode(moveEverythingITermRecentActivityIdleText, forKey: .moveEverythingITermRecentActivityIdleText)
        try container.encode(
            moveEverythingITermRecentActivityBadgeEnabled,
            forKey: .moveEverythingITermRecentActivityBadgeEnabled
        )
        try container.encode(moveEverythingITermRecentActivityColorize, forKey: .moveEverythingITermRecentActivityColorize)
        try container.encode(moveEverythingITermRecentActivityColorizeNamedOnly, forKey: .moveEverythingITermRecentActivityColorizeNamedOnly)
        try container.encode(moveEverythingITermActivityTintIntensity, forKey: .moveEverythingITermActivityTintIntensity)
        try container.encode(moveEverythingITermActivityHoldSeconds, forKey: .moveEverythingITermActivityHoldSeconds)
        try container.encode(moveEverythingITermActivityOverlayOpacity, forKey: .moveEverythingITermActivityOverlayOpacity)
        try container.encode(moveEverythingITermActivityBackgroundTintEnabled, forKey: .moveEverythingITermActivityBackgroundTintEnabled)
        try container.encode(moveEverythingITermActivityTabColorEnabled, forKey: .moveEverythingITermActivityTabColorEnabled)
        try container.encode(
            moveEverythingActiveWindowHighlightColorize,
            forKey: .moveEverythingActiveWindowHighlightColorize
        )
        try container.encode(moveEverythingActiveWindowHighlightColor, forKey: .moveEverythingActiveWindowHighlightColor)
        try container.encode(moveEverythingITermRecentActivityActiveColor, forKey: .moveEverythingITermRecentActivityActiveColor)
        try container.encode(moveEverythingITermRecentActivityIdleColor, forKey: .moveEverythingITermRecentActivityIdleColor)
        try container.encode(moveEverythingITermRecentActivityActiveColorLight, forKey: .moveEverythingITermRecentActivityActiveColorLight)
        try container.encode(moveEverythingITermRecentActivityIdleColorLight, forKey: .moveEverythingITermRecentActivityIdleColorLight)
        try container.encode(moveEverythingITermBadgeTopMargin, forKey: .moveEverythingITermBadgeTopMargin)
        try container.encode(moveEverythingITermBadgeRightMargin, forKey: .moveEverythingITermBadgeRightMargin)
        try container.encode(moveEverythingITermBadgeMaxWidth, forKey: .moveEverythingITermBadgeMaxWidth)
        try container.encode(moveEverythingITermBadgeMaxHeight, forKey: .moveEverythingITermBadgeMaxHeight)
        try container.encode(moveEverythingITermBadgeFromTitle, forKey: .moveEverythingITermBadgeFromTitle)
        try container.encode(moveEverythingITermTitleFromBadge, forKey: .moveEverythingITermTitleFromBadge)
        try container.encode(moveEverythingITermTitleAllCaps, forKey: .moveEverythingITermTitleAllCaps)
        try container.encodeIfPresent(controlCenterFrameX, forKey: .controlCenterFrameX)
        try container.encodeIfPresent(controlCenterFrameY, forKey: .controlCenterFrameY)
        try container.encodeIfPresent(controlCenterFrameWidth, forKey: .controlCenterFrameWidth)
        try container.encodeIfPresent(controlCenterFrameHeight, forKey: .controlCenterFrameHeight)
        try container.encodeIfPresent(moveEverythingCloseWindowHotkey, forKey: .moveEverythingCloseWindowHotkey)
        try container.encodeIfPresent(moveEverythingHideWindowHotkey, forKey: .moveEverythingHideWindowHotkey)
        try container.encodeIfPresent(moveEverythingNameWindowHotkey, forKey: .moveEverythingNameWindowHotkey)
        try container.encodeIfPresent(moveEverythingQuickViewHotkey, forKey: .moveEverythingQuickViewHotkey)
        try container.encodeIfPresent(
            moveEverythingUndoWindowMovementHotkey,
            forKey: .moveEverythingUndoWindowMovementHotkey
        )
        try container.encodeIfPresent(
            moveEverythingRedoWindowMovementHotkey,
            forKey: .moveEverythingRedoWindowMovementHotkey
        )
    }
}

enum MoveEverythingHotkeyAction: String, CaseIterable {
    case closeWindow
    case hideWindow
    case nameWindow
    case quickView
    case undoWindowMovement
    case redoWindowMovement

    var displayName: String {
        switch self {
        case .closeWindow:
            return "Close Window"
        case .hideWindow:
            return "Hide Window"
        case .nameWindow:
            return "Name Window"
        case .quickView:
            return "Quick View"
        case .undoWindowMovement:
            return "Undo Window Movement"
        case .redoWindowMovement:
            return "Redo Window Movement"
        }
    }
}

extension Settings {
    func moveEverythingHotkey(for action: MoveEverythingHotkeyAction) -> Hotkey? {
        switch action {
        case .closeWindow:
            return moveEverythingCloseWindowHotkey
        case .hideWindow:
            return moveEverythingHideWindowHotkey
        case .nameWindow:
            return moveEverythingNameWindowHotkey
        case .quickView:
            return moveEverythingQuickViewHotkey
        case .undoWindowMovement:
            return moveEverythingUndoWindowMovementHotkey
        case .redoWindowMovement:
            return moveEverythingRedoWindowMovementHotkey
        }
    }
}

struct ShortcutConfig: Codable, Identifiable {
    var id: String
    var name: String
    var enabled: Bool
    var hotkey: Hotkey
    var cycleDisplaysOnWrap: Bool
    var controlCenterOnly: Bool
    var placements: [PlacementStep]

    init(
        id: String,
        name: String,
        enabled: Bool = true,
        hotkey: Hotkey,
        cycleDisplaysOnWrap: Bool = false,
        controlCenterOnly: Bool = false,
        placements: [PlacementStep]
    ) {
        self.id = id
        self.name = name
        self.enabled = enabled
        self.hotkey = hotkey
        self.cycleDisplaysOnWrap = cycleDisplaysOnWrap
        self.controlCenterOnly = controlCenterOnly
        self.placements = placements
    }

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case enabled
        case hotkey
        case cycleDisplaysOnWrap
        case controlCenterOnly
        case placements
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        hotkey = try container.decode(Hotkey.self, forKey: .hotkey)
        cycleDisplaysOnWrap = try container.decodeIfPresent(Bool.self, forKey: .cycleDisplaysOnWrap) ?? false
        controlCenterOnly = try container.decodeIfPresent(Bool.self, forKey: .controlCenterOnly) ?? false
        placements = try container.decode([PlacementStep].self, forKey: .placements)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(enabled, forKey: .enabled)
        try container.encode(hotkey, forKey: .hotkey)
        try container.encode(cycleDisplaysOnWrap, forKey: .cycleDisplaysOnWrap)
        try container.encode(controlCenterOnly, forKey: .controlCenterOnly)
        try container.encode(placements, forKey: .placements)
    }
}

struct Hotkey: Codable {
    var key: String
    var modifiers: [String]
}

struct PlacementStep: Codable, Identifiable {
    var id: String
    var title: String
    var mode: PlacementMode
    var display: DisplayTarget
    var grid: GridPlacement?
    var rect: FreeformRect?
}

enum PlacementMode: String, Codable {
    case grid
    case freeform
}

enum DisplayTarget: Codable, Equatable {
    case active
    case main
    case index(Int)

    private static let indexPrefix = "index-"

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        guard let parsed = Self.parse(rawValue) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported display target: \(rawValue)")
        }
        self = parsed
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    var rawValue: String {
        switch self {
        case .active:
            return "active"
        case .main:
            return "main"
        case .index(let index):
            return "\(Self.indexPrefix)\(index)"
        }
    }

    static func parse(_ rawValue: String) -> DisplayTarget? {
        switch rawValue {
        case "active":
            return .active
        case "main":
            return .main
        default:
            guard rawValue.hasPrefix(indexPrefix) else {
                return nil
            }
            let suffix = String(rawValue.dropFirst(indexPrefix.count))
            guard let parsed = Int(suffix), parsed >= 0 else {
                return nil
            }
            return .index(parsed)
        }
    }
}

struct GridPlacement: Codable {
    var columns: Int
    var rows: Int
    var x: Int
    var y: Int
    var width: Int
    var height: Int
}

struct FreeformRect: Codable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double
}

extension PlacementStep {
    func normalizedRect(defaultColumns: Int, defaultRows: Int) -> CGRect? {
        switch mode {
        case .grid:
            let config = grid ?? GridPlacement(columns: defaultColumns, rows: defaultRows, x: 0, y: 0, width: defaultColumns, height: defaultRows)
            guard config.columns > 0, config.rows > 0 else { return nil }
            return CGRect(
                x: Double(config.x) / Double(config.columns),
                y: Double(config.y) / Double(config.rows),
                width: Double(config.width) / Double(config.columns),
                height: Double(config.height) / Double(config.rows)
            )
        case .freeform:
            guard let rect else { return nil }
            return CGRect(x: rect.x, y: rect.y, width: rect.width, height: rect.height)
        }
    }
}

extension AppConfig {
    func normalized() -> AppConfig {
        var copy = self
        if copy.version <= 0 {
            copy.version = 1
        }
        if copy.settings.defaultGridColumns <= 0 {
            copy.settings.defaultGridColumns = 12
        }
        if copy.settings.defaultGridRows <= 0 {
            copy.settings.defaultGridRows = 8
        }
        if copy.settings.gap < 0 {
            copy.settings.gap = 0
        }
        if copy.settings.animationDuration < 0 {
            copy.settings.animationDuration = 0
        }
        if !copy.settings.controlCenterScale.isFinite {
            copy.settings.controlCenterScale = 1
        }
        copy.settings.controlCenterScale = min(max(copy.settings.controlCenterScale, 0.5), 2.0)
        if !copy.settings.moveEverythingCenterWidthPercent.isFinite {
            copy.settings.moveEverythingCenterWidthPercent = 33
        }
        copy.settings.moveEverythingCenterWidthPercent = min(max(copy.settings.moveEverythingCenterWidthPercent, 10), 100)
        if !copy.settings.moveEverythingCenterHeightPercent.isFinite {
            copy.settings.moveEverythingCenterHeightPercent = 70
        }
        copy.settings.moveEverythingCenterHeightPercent = min(max(copy.settings.moveEverythingCenterHeightPercent, 10), 100)
        if !copy.settings.moveEverythingOverlayDuration.isFinite {
            copy.settings.moveEverythingOverlayDuration = 2
        }
        copy.settings.moveEverythingOverlayDuration = min(max(copy.settings.moveEverythingOverlayDuration, 0.2), 8)
        if !copy.settings.moveEverythingBackgroundRefreshInterval.isFinite {
            copy.settings.moveEverythingBackgroundRefreshInterval = 2
        }
        copy.settings.moveEverythingBackgroundRefreshInterval = min(
            max(copy.settings.moveEverythingBackgroundRefreshInterval, 0.5),
            30
        )
        if !copy.settings.moveEverythingITermRecentActivityTimeout.isFinite {
            copy.settings.moveEverythingITermRecentActivityTimeout = 1
        }
        copy.settings.moveEverythingITermRecentActivityTimeout = min(
            max(copy.settings.moveEverythingITermRecentActivityTimeout, 0),
            300
        )
        if !copy.settings.moveEverythingITermRecentActivityBuffer.isFinite {
            copy.settings.moveEverythingITermRecentActivityBuffer = 4
        }
        copy.settings.moveEverythingITermRecentActivityBuffer = min(
            max(copy.settings.moveEverythingITermRecentActivityBuffer, 0),
            300
        )
        if !copy.settings.moveEverythingITermActivityOverlayOpacity.isFinite {
            copy.settings.moveEverythingITermActivityOverlayOpacity = 0.14
        }
        copy.settings.moveEverythingITermActivityOverlayOpacity = min(
            max(copy.settings.moveEverythingITermActivityOverlayOpacity, 0),
            1
        )
        copy.settings.moveEverythingITermRecentActivityActiveText = copy.settings.moveEverythingITermRecentActivityActiveText
            .trimmingCharacters(in: .whitespacesAndNewlines)
        copy.settings.moveEverythingITermRecentActivityIdleText = copy.settings.moveEverythingITermRecentActivityIdleText
            .trimmingCharacters(in: .whitespacesAndNewlines)
        copy.settings.moveEverythingActiveWindowHighlightColor = normalizeHexColor(
            copy.settings.moveEverythingActiveWindowHighlightColor,
            fallback: "#4D88D4"
        )
        copy.settings.moveEverythingITermRecentActivityActiveColor = normalizeHexColor(
            copy.settings.moveEverythingITermRecentActivityActiveColor,
            fallback: "#2F8F4E"
        )
        copy.settings.moveEverythingITermRecentActivityIdleColor = normalizeHexColor(
            copy.settings.moveEverythingITermRecentActivityIdleColor,
            fallback: "#BA4D4D"
        )
        copy.settings.moveEverythingITermBadgeTopMargin = min(
            max(copy.settings.moveEverythingITermBadgeTopMargin, 0),
            200
        )
        copy.settings.moveEverythingITermBadgeRightMargin = min(
            max(copy.settings.moveEverythingITermBadgeRightMargin, 0),
            200
        )
        copy.settings.moveEverythingITermBadgeMaxWidth = min(
            max(copy.settings.moveEverythingITermBadgeMaxWidth, 32),
            600
        )
        copy.settings.moveEverythingITermBadgeMaxHeight = min(
            max(copy.settings.moveEverythingITermBadgeMaxHeight, 10),
            200
        )
        copy.settings.moveEverythingCloseWindowHotkey = normalizeHotkey(copy.settings.moveEverythingCloseWindowHotkey)
        copy.settings.moveEverythingHideWindowHotkey = normalizeHotkey(copy.settings.moveEverythingHideWindowHotkey)
        copy.settings.moveEverythingNameWindowHotkey = normalizeHotkey(copy.settings.moveEverythingNameWindowHotkey)
        copy.settings.moveEverythingQuickViewHotkey = normalizeHotkey(copy.settings.moveEverythingQuickViewHotkey)
        copy.settings.moveEverythingUndoWindowMovementHotkey = normalizeHotkey(
            copy.settings.moveEverythingUndoWindowMovementHotkey
        )
        copy.settings.moveEverythingRedoWindowMovementHotkey = normalizeHotkey(
            copy.settings.moveEverythingRedoWindowMovementHotkey
        )

        var seenShortcutIDs: Set<String> = []
        copy.shortcuts = copy.shortcuts.map { shortcut in
            var normalizedShortcut = shortcut
            normalizedShortcut.id = nextUniqueID(from: shortcut.id, seen: &seenShortcutIDs)
            normalizedShortcut.name = shortcut.name.trimmingCharacters(in: .whitespacesAndNewlines)
            if normalizedShortcut.name.isEmpty {
                normalizedShortcut.name = normalizedShortcut.id
            }
            normalizedShortcut.hotkey.key = shortcut.hotkey.key.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            normalizedShortcut.hotkey.modifiers = Array(Set(shortcut.hotkey.modifiers.map { $0.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) })).sorted()
            var seenPlacementIDs: Set<String> = []
            normalizedShortcut.placements = shortcut.placements.compactMap { placement in
                var normalizedPlacement = placement
                normalizedPlacement.id = nextUniqueID(from: placement.id, seen: &seenPlacementIDs)
                normalizedPlacement.title = placement.title.trimmingCharacters(in: .whitespacesAndNewlines)
                switch normalizedPlacement.mode {
                case .grid:
                    guard var grid = normalizedPlacement.grid else { return nil }
                    grid.columns = max(grid.columns, 1)
                    grid.rows = max(grid.rows, 1)
                    grid.x = max(grid.x, 0)
                    grid.y = max(grid.y, 0)
                    grid.width = max(grid.width, 1)
                    grid.height = max(grid.height, 1)
                    if grid.x + grid.width > grid.columns {
                        grid.width = max(1, grid.columns - grid.x)
                    }
                    if grid.y + grid.height > grid.rows {
                        grid.height = max(1, grid.rows - grid.y)
                    }
                    normalizedPlacement.grid = grid
                    normalizedPlacement.rect = nil
                case .freeform:
                    guard var rect = normalizedPlacement.rect else { return nil }
                    rect.x = min(max(rect.x, 0), 1)
                    rect.y = min(max(rect.y, 0), 1)
                    rect.width = min(max(rect.width, 0.05), 1)
                    rect.height = min(max(rect.height, 0.05), 1)
                    if rect.x + rect.width > 1 {
                        rect.x = max(0, 1 - rect.width)
                    }
                    if rect.y + rect.height > 1 {
                        rect.y = max(0, 1 - rect.height)
                    }
                    normalizedPlacement.rect = rect
                    normalizedPlacement.grid = nil
                }
                return normalizedPlacement
            }
            return normalizedShortcut
        }
        return copy
    }
}

private func nextUniqueID(from rawID: String, seen: inout Set<String>) -> String {
    let base = rawID
        .trimmingCharacters(in: .whitespacesAndNewlines)
    let seeded = base.isEmpty ? UUID().uuidString.lowercased() : base

    if !seen.contains(seeded) {
        seen.insert(seeded)
        return seeded
    }

    var suffix = 2
    var candidate = "\(seeded)-\(suffix)"
    while seen.contains(candidate) {
        suffix += 1
        candidate = "\(seeded)-\(suffix)"
    }
    seen.insert(candidate)
    return candidate
}

private func normalizeHotkey(_ hotkey: Hotkey?) -> Hotkey? {
    guard var hotkey else {
        return nil
    }

    hotkey.key = hotkey.key
        .lowercased()
        .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !hotkey.key.isEmpty else {
        return nil
    }

    hotkey.modifiers = Array(
        Set(
            hotkey.modifiers.map {
                $0.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            }
        )
    ).sorted()
    return hotkey
}

private func normalizeHexColor(_ value: String, fallback: String) -> String {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.hasPrefix("#") else {
        return fallback
    }
    let raw = String(trimmed.dropFirst())
    let hexSet = CharacterSet(charactersIn: "0123456789ABCDEFabcdef")
    guard !raw.isEmpty,
          raw.unicodeScalars.allSatisfy({ hexSet.contains($0) }) else {
        return fallback
    }
    if raw.count == 6 {
        return "#\(raw.uppercased())"
    }
    if raw.count == 3 {
        let characters = Array(raw.uppercased())
        return "#\(characters[0])\(characters[0])\(characters[1])\(characters[1])\(characters[2])\(characters[2])"
    }
    return fallback
}
