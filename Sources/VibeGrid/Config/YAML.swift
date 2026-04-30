import Foundation

enum ConfigParseError: Error, CustomStringConvertible {
    case invalidLine(Int, String)
    case invalidValue(Int, String)

    var description: String {
        switch self {
        case .invalidLine(let line, let message):
            return "Line \(line): \(message)"
        case .invalidValue(let line, let message):
            return "Line \(line): \(message)"
        }
    }
}

struct YAMLConfigCodec {
    private struct ParsedLine {
        let number: Int
        let indent: Int
        let content: String
    }

    private static let ignoredLegacySettingsKeys: Set<String> = [
        "moveEverythingStartStopHotkey",
        "moveEverythingNextWindowHotkey",
        "moveEverythingPreviousWindowHotkey",
        "moveEverythingCycleNextWindowHotkey",
        "moveEverythingToggleOriginalPositionHotkey",
        "moveEverythingSplitITermTabHotkey",
    ]

    static func decode(_ yaml: String) throws -> AppConfig {
        let lines = preprocess(yaml)

        var config = AppConfig.default
        config.shortcuts = []
        var didSetMoveEverythingStartMoveToBottom = false

        // Build an indent-depth stack to convert absolute indent (in spaces)
        // to a logical depth (0, 1, 2, ...) regardless of indent unit.
        var indentStack: [Int] = [0]  // stack of raw indent values; depth = stack index

        func depth(for line: ParsedLine) -> Int {
            let raw = line.indent
            if raw == 0 {
                indentStack = [0]
                return 0
            }
            // indentStack is never empty (initialized to [0], reset to [0] when raw==0)
            let top = indentStack[indentStack.count - 1]
            if raw > top {
                // Deeper nesting
                indentStack.append(raw)
                return indentStack.count - 1
            }
            if raw < top {
                // Dedent: pop until we find matching or lesser indent
                while indentStack.count > 1 && indentStack[indentStack.count - 1] > raw {
                    indentStack.removeLast()
                }
            }
            // raw == indentStack.last (same level) or we popped to it
            return indentStack.count - 1
        }

        // State tracking using context path instead of hardcoded indent levels
        var topLevelSection: String?
        var shortcutSubsection: String?
        var hotkeyListContext: String?
        var placementSubsection: String?

        var currentShortcut: ShortcutConfig?
        var currentPlacement: PlacementStep?

        func finishPlacement() {
            guard var shortcut = currentShortcut, let placement = currentPlacement else { return }
            shortcut.placements.append(placement)
            currentShortcut = shortcut
            currentPlacement = nil
            placementSubsection = nil
        }

        func finishShortcut() {
            finishPlacement()
            guard let shortcut = currentShortcut else { return }
            config.shortcuts.append(shortcut)
            currentShortcut = nil
            shortcutSubsection = nil
            hotkeyListContext = nil
        }

        for line in lines {
            let d = depth(for: line)

            switch d {
            case 0:
                // Top-level keys: version, settings, shortcuts
                finishShortcut()
                let (key, value) = try parseKeyValue(line)
                topLevelSection = key
                shortcutSubsection = nil
                hotkeyListContext = nil
                placementSubsection = nil

                switch key {
                case "version":
                    guard let value, let parsed = Int(parseScalar(value)) else {
                        throw ConfigParseError.invalidValue(line.number, "version must be an integer")
                    }
                    config.version = parsed
                    topLevelSection = nil
                case "settings", "shortcuts":
                    break
                default:
                    throw ConfigParseError.invalidLine(line.number, "Unknown top-level key: \(key)")
                }

            case 1:
                // Depth 1: settings key-values, or shortcut list items ("- ...")
                guard let topLevelSection else {
                    throw ConfigParseError.invalidLine(line.number, "Unexpected indented line")
                }

                if topLevelSection == "settings" {
                    let (key, value) = try parseKeyValue(line)
                    let effectiveValue = value ?? ""
                    guard value != nil || key.hasSuffix("Hotkey") else {
                        throw ConfigParseError.invalidLine(line.number, "settings.\(key) requires a value")
                    }
                    switch key {
                    case "defaultGridColumns":
                        config.settings.defaultGridColumns = try parseInt(effectiveValue, lineNumber: line.number, field: "defaultGridColumns")
                    case "defaultGridRows":
                        config.settings.defaultGridRows = try parseInt(effectiveValue, lineNumber: line.number, field: "defaultGridRows")
                    case "gap":
                        config.settings.gap = try parseInt(effectiveValue, lineNumber: line.number, field: "gap")
                    case "defaultCycleDisplaysOnWrap":
                        config.settings.defaultCycleDisplaysOnWrap = try parseBoolean(
                            effectiveValue,
                            lineNumber: line.number,
                            field: "defaultCycleDisplaysOnWrap"
                        )
                    case "animationDuration":
                        config.settings.animationDuration = try parseDouble(effectiveValue, lineNumber: line.number, field: "animationDuration")
                    case "controlCenterScale":
                        config.settings.controlCenterScale = try parseDouble(effectiveValue, lineNumber: line.number, field: "controlCenterScale")
                    case "largerFonts":
                        config.settings.largerFonts = try parseBoolean(
                            effectiveValue, lineNumber: line.number, field: "largerFonts"
                        )
                    case "fontSizeAdjustPt":
                        let raw = try parseInt(effectiveValue, lineNumber: line.number, field: "fontSizeAdjustPt")
                        config.settings.fontSizeAdjustPt = max(-4, min(8, raw))
                    case "themeMode":
                        let rawThemeMode = parseScalar(effectiveValue).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                        guard let themeMode = Settings.ThemeMode(rawValue: rawThemeMode) else {
                            throw ConfigParseError.invalidValue(
                                line.number,
                                "themeMode must be one of: system, light, dark"
                            )
                        }
                        config.settings.themeMode = themeMode
                    case "darkMode":
                        let darkMode = try parseBoolean(
                            effectiveValue,
                            lineNumber: line.number,
                            field: "darkMode"
                        )
                        config.settings.themeMode = darkMode ? .dark : .system
                    case "moveEverythingMoveOnSelection":
                        let rawMoveOnSelection = parseScalar(effectiveValue)
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                            .lowercased()
                        let moveOnSelection: Settings.MoveEverythingMoveOnSelectionMode
                        switch rawMoveOnSelection {
                        case "never":
                            moveOnSelection = .never
                        case "minicontrolcenterontop", "advancedcontrolcenterontop", "controlcenteronly", "controlcenteronce":
                            moveOnSelection = .miniControlCenterOnTop
                        case "firstselection":
                            moveOnSelection = .firstSelection
                        case "always":
                            moveOnSelection = .always
                        default:
                            throw ConfigParseError.invalidValue(
                                line.number,
                                "moveEverythingMoveOnSelection must be one of: never, advancedControlCenterOnTop, firstSelection, always"
                            )
                        }
                        config.settings.moveEverythingMoveOnSelection = moveOnSelection
                    case "moveEverythingCenterWidthPercent":
                        config.settings.moveEverythingCenterWidthPercent = try parseDouble(
                            effectiveValue,
                            lineNumber: line.number,
                            field: "moveEverythingCenterWidthPercent"
                        )
                    case "moveEverythingCenterHeightPercent":
                        config.settings.moveEverythingCenterHeightPercent = try parseDouble(
                            effectiveValue,
                            lineNumber: line.number,
                            field: "moveEverythingCenterHeightPercent"
                        )
                    case "moveEverythingOverlayMode":
                        let rawOverlayMode = parseScalar(effectiveValue)
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                            .lowercased()
                        guard let overlayMode = Settings.MoveEverythingOverlayMode(rawValue: rawOverlayMode) else {
                            throw ConfigParseError.invalidValue(
                                line.number,
                                "moveEverythingOverlayMode must be one of: persistent, timed"
                            )
                        }
                        config.settings.moveEverythingOverlayMode = overlayMode
                    case "moveEverythingOverlayDuration":
                        config.settings.moveEverythingOverlayDuration = try parseDouble(
                            effectiveValue,
                            lineNumber: line.number,
                            field: "moveEverythingOverlayDuration"
                        )
                    case "moveEverythingStartAlwaysOnTop":
                        config.settings.moveEverythingStartAlwaysOnTop = try parseBoolean(
                            effectiveValue,
                            lineNumber: line.number,
                            field: "moveEverythingStartAlwaysOnTop"
                        )
                    case "moveEverythingStartMoveToBottom":
                        config.settings.moveEverythingStartMoveToBottom = try parseBoolean(
                            effectiveValue,
                            lineNumber: line.number,
                            field: "moveEverythingStartMoveToBottom"
                        )
                        didSetMoveEverythingStartMoveToBottom = true
                    case "moveEverythingStartMoveToCenter":
                        config.settings.moveEverythingStartMoveToCenter = try parseBoolean(
                            effectiveValue,
                            lineNumber: line.number,
                            field: "moveEverythingStartMoveToCenter"
                        )
                    case "moveEverythingStartDontMoveVibeGrid":
                        config.settings.moveEverythingStartDontMoveVibeGrid = try parseBoolean(
                            effectiveValue,
                            lineNumber: line.number,
                            field: "moveEverythingStartDontMoveVibeGrid"
                        )
                    case "controlCenterSticky":
                        config.settings.controlCenterSticky = try parseBoolean(
                            effectiveValue,
                            lineNumber: line.number,
                            field: "controlCenterSticky"
                        )
                    case "controlCenterFrameX":
                        config.settings.controlCenterFrameX = Double(effectiveValue)
                    case "controlCenterFrameY":
                        config.settings.controlCenterFrameY = Double(effectiveValue)
                    case "controlCenterFrameWidth":
                        config.settings.controlCenterFrameWidth = Double(effectiveValue)
                    case "controlCenterFrameHeight":
                        config.settings.controlCenterFrameHeight = Double(effectiveValue)
                    case "moveEverythingAdvancedControlCenterHover":
                        config.settings.moveEverythingAdvancedControlCenterHover = try parseBoolean(
                            effectiveValue,
                            lineNumber: line.number,
                            field: "moveEverythingAdvancedControlCenterHover"
                        )
                    case "moveEverythingStickyHoverStealFocus":
                        config.settings.moveEverythingStickyHoverStealFocus = try parseBoolean(
                            effectiveValue,
                            lineNumber: line.number,
                            field: "moveEverythingStickyHoverStealFocus"
                        )
                    case "moveEverythingCloseHideHotkeysOutsideMode":
                        config.settings.moveEverythingCloseHideHotkeysOutsideMode = try parseBoolean(
                            effectiveValue,
                            lineNumber: line.number,
                            field: "moveEverythingCloseHideHotkeysOutsideMode"
                        )
                    case "moveEverythingCloseMuxKill":
                        config.settings.moveEverythingCloseMuxKill = try parseBoolean(
                            effectiveValue,
                            lineNumber: line.number,
                            field: "moveEverythingCloseMuxKill"
                        )
                    case "moveEverythingCloseSmart":
                        config.settings.moveEverythingCloseSmart = try parseBoolean(
                            effectiveValue,
                            lineNumber: line.number,
                            field: "moveEverythingCloseSmart"
                        )
                    case "moveEverythingCloseSmartDelaySeconds":
                        config.settings.moveEverythingCloseSmartDelaySeconds = try parseDouble(
                            effectiveValue,
                            lineNumber: line.number,
                            field: "moveEverythingCloseSmartDelaySeconds"
                        )
                    case "moveEverythingExcludePinnedWindows", "moveEverythingExcludeControlCenter":
                        config.settings.moveEverythingExcludePinnedWindows = try parseBoolean(
                            effectiveValue,
                            lineNumber: line.number,
                            field: "moveEverythingExcludePinnedWindows"
                        )
                    case "moveEverythingMiniRetileWidthPercent":
                        config.settings.moveEverythingMiniRetileWidthPercent = try parseDouble(
                            effectiveValue,
                            lineNumber: line.number,
                            field: "moveEverythingMiniRetileWidthPercent"
                        )
                    case "moveEverythingRetileSide":
                        let raw = effectiveValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                        switch raw {
                        case "left":
                            config.settings.moveEverythingRetileSide = .left
                        case "right":
                            config.settings.moveEverythingRetileSide = .right
                        default:
                            config.settings.moveEverythingRetileSide = .auto
                        }
                    case "moveEverythingRetileOrder":
                        let raw = effectiveValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                        if raw == "innermostfirst" {
                            config.settings.moveEverythingRetileOrder = .innermostFirst
                        } else {
                            config.settings.moveEverythingRetileOrder = .leftToRight
                        }
                    case "moveEverythingITermGroupByRepository":
                        config.settings.moveEverythingITermGroupByRepository = try parseBoolean(
                            effectiveValue,
                            lineNumber: line.number,
                            field: "moveEverythingITermGroupByRepository"
                        )
                    case "moveEverythingBackgroundRefreshInterval":
                        config.settings.moveEverythingBackgroundRefreshInterval = try parseDouble(
                            effectiveValue,
                            lineNumber: line.number,
                            field: "moveEverythingBackgroundRefreshInterval"
                        )
                    case "moveEverythingITermRecentActivityTimeout":
                        config.settings.moveEverythingITermRecentActivityTimeout = try parseDouble(
                            effectiveValue,
                            lineNumber: line.number,
                            field: "moveEverythingITermRecentActivityTimeout"
                        )
                    case "moveEverythingITermRecentActivityBuffer":
                        config.settings.moveEverythingITermRecentActivityBuffer = try parseDouble(
                            effectiveValue,
                            lineNumber: line.number,
                            field: "moveEverythingITermRecentActivityBuffer"
                        )
                    case "moveEverythingITermRecentActivityActiveText":
                        config.settings.moveEverythingITermRecentActivityActiveText = parseScalar(effectiveValue)
                    case "moveEverythingITermRecentActivityIdleText":
                        config.settings.moveEverythingITermRecentActivityIdleText = parseScalar(effectiveValue)
                    case "moveEverythingITermRecentActivityBadgeEnabled":
                        config.settings.moveEverythingITermRecentActivityBadgeEnabled = try parseBoolean(
                            effectiveValue,
                            lineNumber: line.number,
                            field: "moveEverythingITermRecentActivityBadgeEnabled"
                        )
                    case "moveEverythingITermRecentActivityColorize":
                        config.settings.moveEverythingITermRecentActivityColorize = try parseBoolean(
                            effectiveValue,
                            lineNumber: line.number,
                            field: "moveEverythingITermRecentActivityColorize"
                        )
                    case "moveEverythingITermRecentActivityColorizeNamedOnly":
                        config.settings.moveEverythingITermRecentActivityColorizeNamedOnly = try parseBoolean(
                            effectiveValue,
                            lineNumber: line.number,
                            field: "moveEverythingITermRecentActivityColorizeNamedOnly"
                        )
                    case "moveEverythingITermActivityTintIntensity":
                        config.settings.moveEverythingITermActivityTintIntensity = try parseDouble(
                            effectiveValue,
                            lineNumber: line.number,
                            field: "moveEverythingITermActivityTintIntensity"
                        )
                    case "moveEverythingITermActivityHoldSeconds":
                        config.settings.moveEverythingITermActivityHoldSeconds = try parseDouble(
                            effectiveValue,
                            lineNumber: line.number,
                            field: "moveEverythingITermActivityHoldSeconds"
                        )
                    case "moveEverythingITermActivityOverlayOpacity":
                        config.settings.moveEverythingITermActivityOverlayOpacity = try parseDouble(
                            effectiveValue,
                            lineNumber: line.number,
                            field: "moveEverythingITermActivityOverlayOpacity"
                        )
                    case "moveEverythingHoverOverlayOpacity":
                        config.settings.moveEverythingHoverOverlayOpacity = try parseDouble(
                            effectiveValue,
                            lineNumber: line.number,
                            field: "moveEverythingHoverOverlayOpacity"
                        )
                    case "moveEverythingITermActivityBackgroundTintEnabled":
                        config.settings.moveEverythingITermActivityBackgroundTintEnabled = try parseBoolean(
                            effectiveValue,
                            lineNumber: line.number,
                            field: "moveEverythingITermActivityBackgroundTintEnabled"
                        )
                    case "moveEverythingITermActivityBackgroundTintPersistent":
                        config.settings.moveEverythingITermActivityBackgroundTintPersistent = try parseBoolean(
                            effectiveValue,
                            lineNumber: line.number,
                            field: "moveEverythingITermActivityBackgroundTintPersistent"
                        )
                    case "moveEverythingITermActivityTabColorEnabled":
                        config.settings.moveEverythingITermActivityTabColorEnabled = try parseBoolean(
                            effectiveValue,
                            lineNumber: line.number,
                            field: "moveEverythingITermActivityTabColorEnabled"
                        )
                    case "moveEverythingActiveWindowHighlightColorize":
                        config.settings.moveEverythingActiveWindowHighlightColorize = try parseBoolean(
                            effectiveValue,
                            lineNumber: line.number,
                            field: "moveEverythingActiveWindowHighlightColorize"
                        )
                    case "moveEverythingActiveWindowHighlightColor":
                        config.settings.moveEverythingActiveWindowHighlightColor = parseScalar(effectiveValue)
                    case "moveEverythingITermRecentActivityActiveColor":
                        config.settings.moveEverythingITermRecentActivityActiveColor = parseScalar(effectiveValue)
                    case "moveEverythingITermRecentActivityIdleColor":
                        config.settings.moveEverythingITermRecentActivityIdleColor = parseScalar(effectiveValue)
                    case "moveEverythingITermRecentActivityActiveColorLight":
                        config.settings.moveEverythingITermRecentActivityActiveColorLight = parseScalar(effectiveValue)
                    case "moveEverythingITermRecentActivityIdleColorLight":
                        config.settings.moveEverythingITermRecentActivityIdleColorLight = parseScalar(effectiveValue)
                    case "moveEverythingWindowListActiveColor":
                        config.settings.moveEverythingWindowListActiveColor = parseScalar(effectiveValue)
                    case "moveEverythingWindowListIdleColor":
                        config.settings.moveEverythingWindowListIdleColor = parseScalar(effectiveValue)
                    case "moveEverythingWindowListActiveColorLight":
                        config.settings.moveEverythingWindowListActiveColorLight = parseScalar(effectiveValue)
                    case "moveEverythingWindowListIdleColorLight":
                        config.settings.moveEverythingWindowListIdleColorLight = parseScalar(effectiveValue)
                    case "moveEverythingITermBadgeTopMargin":
                        config.settings.moveEverythingITermBadgeTopMargin = try parseInt(
                            effectiveValue,
                            lineNumber: line.number,
                            field: "moveEverythingITermBadgeTopMargin"
                        )
                    case "moveEverythingITermBadgeRightMargin":
                        config.settings.moveEverythingITermBadgeRightMargin = try parseInt(
                            effectiveValue,
                            lineNumber: line.number,
                            field: "moveEverythingITermBadgeRightMargin"
                        )
                    case "moveEverythingITermBadgeMaxWidth":
                        config.settings.moveEverythingITermBadgeMaxWidth = try parseInt(
                            effectiveValue,
                            lineNumber: line.number,
                            field: "moveEverythingITermBadgeMaxWidth"
                        )
                    case "moveEverythingITermBadgeMaxHeight":
                        config.settings.moveEverythingITermBadgeMaxHeight = try parseInt(
                            effectiveValue,
                            lineNumber: line.number,
                            field: "moveEverythingITermBadgeMaxHeight"
                        )
                    case "moveEverythingITermBadgeFromTitle":
                        config.settings.moveEverythingITermBadgeFromTitle = try parseBoolean(
                            effectiveValue,
                            lineNumber: line.number,
                            field: "moveEverythingITermBadgeFromTitle"
                        )
                    case "moveEverythingITermTitleAllCaps":
                        config.settings.moveEverythingITermTitleAllCaps = try parseBoolean(
                            effectiveValue,
                            lineNumber: line.number,
                            field: "moveEverythingITermTitleAllCaps"
                        )
                    case "moveEverythingITermTitleFromBadge":
                        config.settings.moveEverythingITermTitleFromBadge = try parseBoolean(
                            effectiveValue,
                            lineNumber: line.number,
                            field: "moveEverythingITermTitleFromBadge"
                        )
                    case "moveEverythingClaudeCodeRepoPrefix":
                        config.settings.moveEverythingClaudeCodeRepoPrefix = try parseBoolean(
                            effectiveValue,
                            lineNumber: line.number,
                            field: "moveEverythingClaudeCodeRepoPrefix"
                        )
                    case "moveEverythingClaudeCodeRepoPrefixColor":
                        config.settings.moveEverythingClaudeCodeRepoPrefixColor = parseScalar(effectiveValue)
                    case "moveEverythingClaudeCodeRepoPrefixColorLight":
                        config.settings.moveEverythingClaudeCodeRepoPrefixColorLight = parseScalar(effectiveValue)
                    case "moveEverythingActivityEnabled":
                        config.settings.moveEverythingActivityEnabled = try parseBoolean(
                            effectiveValue,
                            lineNumber: line.number,
                            field: "moveEverythingActivityEnabled"
                        )
                    case "moveEverythingVibedActivityEnabled":
                        config.settings.moveEverythingVibedActivityEnabled = try parseBoolean(
                            effectiveValue,
                            lineNumber: line.number,
                            field: "moveEverythingVibedActivityEnabled"
                        )
                    case "moveEverythingCloseWindowHotkey":
                        config.settings.moveEverythingCloseWindowHotkey = try parseHotkey(
                            effectiveValue,
                            lineNumber: line.number,
                            field: "moveEverythingCloseWindowHotkey"
                        )
                    case "moveEverythingHideWindowHotkey":
                        config.settings.moveEverythingHideWindowHotkey = try parseHotkey(
                            effectiveValue,
                            lineNumber: line.number,
                            field: "moveEverythingHideWindowHotkey"
                        )
                    case "moveEverythingNameWindowHotkey":
                        config.settings.moveEverythingNameWindowHotkey = try parseHotkey(
                            effectiveValue,
                            lineNumber: line.number,
                            field: "moveEverythingNameWindowHotkey"
                        )
                    case "moveEverythingQuickViewHotkey":
                        config.settings.moveEverythingQuickViewHotkey = try parseHotkey(
                            effectiveValue,
                            lineNumber: line.number,
                            field: "moveEverythingQuickViewHotkey"
                        )
                    case "moveEverythingQuickViewVerticalMode":
                        let rawMode = parseScalar(effectiveValue)
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                            .lowercased()
                        let mode: Settings.MoveEverythingQuickViewVerticalMode
                        switch rawMode {
                        case "fullheight":
                            mode = .fullHeight
                        case "fromcursor":
                            mode = .fromCursor
                        case "padded":
                            mode = .padded
                        default:
                            throw ConfigParseError.invalidValue(
                                line.number,
                                "moveEverythingQuickViewVerticalMode must be one of: fullHeight, fromCursor, padded"
                            )
                        }
                        config.settings.moveEverythingQuickViewVerticalMode = mode
                    case "moveEverythingUndoWindowMovementHotkey":
                        config.settings.moveEverythingUndoWindowMovementHotkey = try parseHotkey(
                            effectiveValue,
                            lineNumber: line.number,
                            field: "moveEverythingUndoWindowMovementHotkey"
                        )
                    case "moveEverythingRedoWindowMovementHotkey":
                        config.settings.moveEverythingRedoWindowMovementHotkey = try parseHotkey(
                            effectiveValue,
                            lineNumber: line.number,
                            field: "moveEverythingRedoWindowMovementHotkey"
                        )
                    case "moveEverythingUndoWindowMovementForFocusedWindowHotkey":
                        config.settings.moveEverythingUndoWindowMovementForFocusedWindowHotkey = try parseHotkey(
                            effectiveValue,
                            lineNumber: line.number,
                            field: "moveEverythingUndoWindowMovementForFocusedWindowHotkey"
                        )
                    case "moveEverythingRedoWindowMovementForFocusedWindowHotkey":
                        config.settings.moveEverythingRedoWindowMovementForFocusedWindowHotkey = try parseHotkey(
                            effectiveValue,
                            lineNumber: line.number,
                            field: "moveEverythingRedoWindowMovementForFocusedWindowHotkey"
                        )
                    case "moveEverythingShowAllHiddenWindowsHotkey":
                        config.settings.moveEverythingShowAllHiddenWindowsHotkey = try parseHotkey(
                            effectiveValue,
                            lineNumber: line.number,
                            field: "moveEverythingShowAllHiddenWindowsHotkey"
                        )
                    case "moveEverythingRetile1Hotkey":
                        config.settings.moveEverythingRetile1Hotkey = try parseHotkey(
                            effectiveValue,
                            lineNumber: line.number,
                            field: "moveEverythingRetile1Hotkey"
                        )
                    case "moveEverythingRetile1Mode":
                        config.settings.moveEverythingRetile1Mode = try parseRetileMode(
                            effectiveValue,
                            lineNumber: line.number,
                            field: "moveEverythingRetile1Mode"
                        )
                    case "moveEverythingRetile2Hotkey":
                        config.settings.moveEverythingRetile2Hotkey = try parseHotkey(
                            effectiveValue,
                            lineNumber: line.number,
                            field: "moveEverythingRetile2Hotkey"
                        )
                    case "moveEverythingRetile2Mode":
                        config.settings.moveEverythingRetile2Mode = try parseRetileMode(
                            effectiveValue,
                            lineNumber: line.number,
                            field: "moveEverythingRetile2Mode"
                        )
                    case "moveEverythingRetile3Hotkey":
                        config.settings.moveEverythingRetile3Hotkey = try parseHotkey(
                            effectiveValue,
                            lineNumber: line.number,
                            field: "moveEverythingRetile3Hotkey"
                        )
                    case "moveEverythingRetile3Mode":
                        config.settings.moveEverythingRetile3Mode = try parseRetileMode(
                            effectiveValue,
                            lineNumber: line.number,
                            field: "moveEverythingRetile3Mode"
                        )
                    default:
                        // Silently ignore unknown settings keys for forward compatibility
                        break
                    }
                } else if topLevelSection == "shortcuts" {
                    guard line.content.hasPrefix("- ") else {
                        throw ConfigParseError.invalidLine(line.number, "Expected a shortcut list item")
                    }

                    finishShortcut()
                    currentShortcut = ShortcutConfig(
                        id: UUID().uuidString.lowercased(),
                        name: "",
                        enabled: true,
                        hotkey: Hotkey(key: "", modifiers: []),
                        cycleDisplaysOnWrap: config.settings.defaultCycleDisplaysOnWrap,
                        canMoveControlCenter: false,
                        ignoreExcludePinnedWindows: false,
                        placements: []
                    )
                    shortcutSubsection = nil
                    hotkeyListContext = nil
                    placementSubsection = nil

                    let inline = String(line.content.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                    if !inline.isEmpty {
                        let (key, value) = try parseInlineKeyValue(inline, lineNumber: line.number)
                        try applyShortcutKeyValue(key: key, value: value, to: &currentShortcut, lineNumber: line.number)
                    }
                } else {
                    throw ConfigParseError.invalidLine(line.number, "Unknown section at depth 1")
                }

            case 2:
                // Depth 2: shortcut properties (name, enabled, hotkey:, placements:, ...)
                guard topLevelSection == "shortcuts", currentShortcut != nil else {
                    throw ConfigParseError.invalidLine(line.number, "Unexpected line at depth 2")
                }

                hotkeyListContext = nil
                placementSubsection = nil

                let (key, value) = try parseKeyValue(line)
                switch key {
                case "hotkey", "placements":
                    shortcutSubsection = key
                    if key == "placements" {
                        finishPlacement()
                    }
                default:
                    shortcutSubsection = nil
                    try applyShortcutKeyValue(key: key, value: value, to: &currentShortcut, lineNumber: line.number)
                }

            case 3:
                // Depth 3: hotkey properties (key, modifiers) or placement list items
                guard topLevelSection == "shortcuts", currentShortcut != nil else {
                    throw ConfigParseError.invalidLine(line.number, "Unexpected line at depth 3")
                }

                if shortcutSubsection == "hotkey" {
                    if line.content.hasPrefix("- ") {
                        throw ConfigParseError.invalidLine(line.number, "modifiers list must be inside hotkey.modifiers")
                    }
                    let (key, value) = try parseKeyValue(line)
                    guard var shortcut = currentShortcut else { break }
                    switch key {
                    case "key":
                        guard let value else {
                            throw ConfigParseError.invalidValue(line.number, "hotkey.key requires a value")
                        }
                        shortcut.hotkey.key = parseScalar(value)
                        currentShortcut = shortcut
                        hotkeyListContext = nil
                    case "modifiers":
                        hotkeyListContext = "modifiers"
                    default:
                        throw ConfigParseError.invalidLine(line.number, "Unknown hotkey key: \(key)")
                    }
                } else if shortcutSubsection == "placements" {
                    guard line.content.hasPrefix("- ") else {
                        throw ConfigParseError.invalidLine(line.number, "Expected placement list item")
                    }
                    finishPlacement()
                    currentPlacement = PlacementStep(
                        id: UUID().uuidString.lowercased(),
                        title: "",
                        mode: .grid,
                        display: .active,
                        grid: GridPlacement(
                            columns: config.settings.defaultGridColumns,
                            rows: config.settings.defaultGridRows,
                            x: 0,
                            y: 0,
                            width: config.settings.defaultGridColumns,
                            height: config.settings.defaultGridRows
                        ),
                        rect: nil
                    )
                    placementSubsection = nil

                    let inline = String(line.content.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                    if !inline.isEmpty {
                        let (key, value) = try parseInlineKeyValue(inline, lineNumber: line.number)
                        try applyPlacementKeyValue(key: key, value: value, to: &currentPlacement, lineNumber: line.number)
                    }
                } else {
                    throw ConfigParseError.invalidLine(line.number, "Unexpected subsection at depth 3")
                }

            case 4:
                // Depth 4: modifier list items, or placement properties (title, mode, grid:, rect:)
                guard topLevelSection == "shortcuts", let subsection = shortcutSubsection else {
                    throw ConfigParseError.invalidLine(line.number, "Unexpected line at depth 4")
                }

                if subsection == "hotkey" {
                    guard hotkeyListContext == "modifiers", line.content.hasPrefix("- ") else {
                        throw ConfigParseError.invalidLine(line.number, "Expected a modifier list item")
                    }
                    guard var shortcut = currentShortcut else { break }
                    let item = String(line.content.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                    shortcut.hotkey.modifiers.append(parseScalar(item).lowercased())
                    currentShortcut = shortcut
                } else if subsection == "placements" {
                    guard currentPlacement != nil else {
                        throw ConfigParseError.invalidLine(line.number, "Placement details without a placement item")
                    }
                    if line.content.hasPrefix("- ") {
                        throw ConfigParseError.invalidLine(line.number, "Nested list is not supported here")
                    }
                    let (key, value) = try parseKeyValue(line)
                    switch key {
                    case "grid", "rect":
                        placementSubsection = key
                    default:
                        placementSubsection = nil
                        try applyPlacementKeyValue(key: key, value: value, to: &currentPlacement, lineNumber: line.number)
                    }
                } else {
                    throw ConfigParseError.invalidLine(line.number, "Unexpected subsection at depth 4")
                }

            case 5:
                // Depth 5: grid/rect properties (columns, rows, x, y, width, height)
                guard topLevelSection == "shortcuts", shortcutSubsection == "placements", currentPlacement != nil, let placementSubsection else {
                    throw ConfigParseError.invalidLine(line.number, "Unexpected line at depth 5")
                }
                let (key, value) = try parseKeyValue(line)
                guard let value else {
                    throw ConfigParseError.invalidValue(line.number, "\(placementSubsection).\(key) requires a value")
                }
                try applyPlacementShapeKeyValue(
                    parentKey: placementSubsection,
                    key: key,
                    value: value,
                    to: &currentPlacement,
                    lineNumber: line.number,
                    settings: config.settings
                )

            default:
                throw ConfigParseError.invalidLine(line.number, "Unsupported nesting depth: \(d)")
            }
        }

        finishShortcut()

        if !didSetMoveEverythingStartMoveToBottom {
            config.settings.moveEverythingStartMoveToBottom = false
        }

        return config.normalized()
    }

    static func encode(_ config: AppConfig) -> String {
        let normalized = config.normalized()
        var lines: [String] = []

        lines.append("version: \(normalized.version)")
        lines.append("")
        lines.append("# ── Appearance ──────────────────────────────────────────────────")
        lines.append("settings:")
        lines.append("  defaultGridColumns: \(normalized.settings.defaultGridColumns)  # grid columns for new shortcuts (1-24)")
        lines.append("  defaultGridRows: \(normalized.settings.defaultGridRows)  # grid rows for new shortcuts (1-20)")
        lines.append("  gap: \(normalized.settings.gap)  # gap between placements in pixels (0-80)")
        lines.append("  defaultCycleDisplaysOnWrap: \(normalized.settings.defaultCycleDisplaysOnWrap ? "true" : "false")  # cycle to next display when wrapping")
        lines.append("  animationDuration: \(formatDouble(normalized.settings.animationDuration))  # window move animation in seconds (0=instant)")
        lines.append("  controlCenterScale: \(formatDouble(normalized.settings.controlCenterScale))  # UI scale for control center (0.5-2.0)")
        lines.append("  largerFonts: \(normalized.settings.largerFonts ? "true" : "false")  # use larger fonts (+2pt) [deprecated: use fontSizeAdjustPt]")
        lines.append("  fontSizeAdjustPt: \(normalized.settings.fontSizeAdjustPt)  # font size adjustment in points (-4..+8)")
        lines.append("  themeMode: \(normalized.settings.themeMode.rawValue)  # system | light | dark")
        lines.append("")
        lines.append("  # ── Window List ────────────────────────────────────────────────")
        lines.append("  moveEverythingMoveOnSelection: \(normalized.settings.moveEverythingMoveOnSelection.rawValue)  # what happens on window click")
        lines.append("  moveEverythingCenterWidthPercent: \(formatDouble(normalized.settings.moveEverythingCenterWidthPercent))  # center placement width %")
        lines.append("  moveEverythingCenterHeightPercent: \(formatDouble(normalized.settings.moveEverythingCenterHeightPercent))  # center placement height %")
        lines.append("  moveEverythingOverlayMode: \(normalized.settings.moveEverythingOverlayMode.rawValue)  # persistent | timed | off")
        lines.append("  moveEverythingOverlayDuration: \(formatDouble(normalized.settings.moveEverythingOverlayDuration))  # overlay display duration (sec)")
        lines.append("  moveEverythingStartAlwaysOnTop: \(normalized.settings.moveEverythingStartAlwaysOnTop ? "true" : "false")  # start with always-on-top")
        lines.append("  moveEverythingStartMoveToBottom: \(normalized.settings.moveEverythingStartMoveToBottom ? "true" : "false")")
        lines.append("  moveEverythingStartMoveToCenter: \(normalized.settings.moveEverythingStartMoveToCenter ? "true" : "false")")
        lines.append("  moveEverythingStartDontMoveVibeGrid: \(normalized.settings.moveEverythingStartDontMoveVibeGrid ? "true" : "false")  # Pin CC toggle (persists across sessions)")
        lines.append("  controlCenterSticky: \(normalized.settings.controlCenterSticky ? "true" : "false")  # true = placement shortcuts don't move the control center when it's focused (unless shortcut has canMoveControlCenter: true)")
        if let x = normalized.settings.controlCenterFrameX,
           let y = normalized.settings.controlCenterFrameY,
           let w = normalized.settings.controlCenterFrameWidth,
           let h = normalized.settings.controlCenterFrameHeight {
            lines.append("  controlCenterFrameX: \(formatDouble(x))")
            lines.append("  controlCenterFrameY: \(formatDouble(y))")
            lines.append("  controlCenterFrameWidth: \(formatDouble(w))")
            lines.append("  controlCenterFrameHeight: \(formatDouble(h))")
        }
        lines.append("  moveEverythingAdvancedControlCenterHover: \(normalized.settings.moveEverythingAdvancedControlCenterHover ? "true" : "false")")
        lines.append("  moveEverythingStickyHoverStealFocus: \(normalized.settings.moveEverythingStickyHoverStealFocus ? "true" : "false")")
        lines.append(
            "  moveEverythingCloseHideHotkeysOutsideMode: \(normalized.settings.moveEverythingCloseHideHotkeysOutsideMode ? "true" : "false")  # close/hide hotkeys work outside Window List mode"
        )
        lines.append("  moveEverythingCloseMuxKill: \(normalized.settings.moveEverythingCloseMuxKill ? "true" : "false")  # kill mux session when closing iTerm windows")
        lines.append("  moveEverythingCloseSmart: \(normalized.settings.moveEverythingCloseSmart ? "true" : "false")  # close hotkey hides first, then kills if still hidden")
        lines.append("  moveEverythingCloseSmartDelaySeconds: \(formatDouble(normalized.settings.moveEverythingCloseSmartDelaySeconds))  # smart close kill delay (sec)")
        lines.append("  moveEverythingExcludePinnedWindows: \(normalized.settings.moveEverythingExcludePinnedWindows ? "true" : "false")")
        lines.append("  moveEverythingMiniRetileWidthPercent: \(formatDouble(normalized.settings.moveEverythingMiniRetileWidthPercent))  # width % for mini retile")
        lines.append("  moveEverythingRetileSide: \(normalized.settings.moveEverythingRetileSide.rawValue)  # auto | left | right — force retile side, auto follows control center")
        lines.append("  moveEverythingRetileOrder: \(normalized.settings.moveEverythingRetileOrder.rawValue)  # leftToRight | innermostFirst")
        lines.append("  moveEverythingBackgroundRefreshInterval: \(formatDouble(normalized.settings.moveEverythingBackgroundRefreshInterval))  # window list refresh interval (sec)")
        lines.append("")
        lines.append("  # ── iTerm2 Activity Detection ──────────────────────────────────")
        lines.append("  moveEverythingITermGroupByRepository: \(normalized.settings.moveEverythingITermGroupByRepository ? "true" : "false")  # group iTerm windows by repository")
        lines.append("  moveEverythingITermRecentActivityTimeout: \(formatDouble(normalized.settings.moveEverythingITermRecentActivityTimeout))  # detection poll timeout (sec)")
        lines.append("  moveEverythingITermRecentActivityBuffer: \(formatDouble(normalized.settings.moveEverythingITermRecentActivityBuffer))  # buffer before activity detection starts (sec)")
        lines.append("  moveEverythingITermRecentActivityActiveText: \(encodeScalar(normalized.settings.moveEverythingITermRecentActivityActiveText))  # text shown for active windows")
        lines.append("  moveEverythingITermRecentActivityIdleText: \(encodeScalar(normalized.settings.moveEverythingITermRecentActivityIdleText))  # text shown for idle windows (empty=hidden)")
        lines.append("  moveEverythingITermRecentActivityBadgeEnabled: \(normalized.settings.moveEverythingITermRecentActivityBadgeEnabled ? "true" : "false")  # show activity badge in iTerm")
        lines.append("")
        lines.append("  # ── Activity Indicator Colors ──────────────────────────────────")
        lines.append("  # Three indicator modes (can be combined):")
        lines.append("  #   backgroundTint — shifts iTerm background color (green=active, red=idle)")
        lines.append("  #   tabColor — colors the iTerm tab bar per-window")
        lines.append("  #   overlay — legacy transparent border overlay (0=off)")
        lines.append("  moveEverythingITermActivityBackgroundTintEnabled: \(normalized.settings.moveEverythingITermActivityBackgroundTintEnabled ? "true" : "false")")
        lines.append("  moveEverythingITermActivityBackgroundTintPersistent: \(normalized.settings.moveEverythingITermActivityBackgroundTintPersistent ? "true" : "false")  # keep tint active during user interaction")
        lines.append("  moveEverythingITermActivityTabColorEnabled: \(normalized.settings.moveEverythingITermActivityTabColorEnabled ? "true" : "false")")
        lines.append("  moveEverythingITermActivityOverlayOpacity: \(formatDouble(normalized.settings.moveEverythingITermActivityOverlayOpacity))  # legacy overlay opacity (0=off, 0-1)")
        lines.append("  moveEverythingHoverOverlayOpacity: \(formatDouble(normalized.settings.moveEverythingHoverOverlayOpacity))  # hover overlay opacity multiplier (0=off, 1=default, 2=2x)")
        lines.append("  moveEverythingITermActivityTintIntensity: \(formatDouble(normalized.settings.moveEverythingITermActivityTintIntensity))  # background tint strength (0.05-1.0)")
        lines.append("  moveEverythingITermActivityHoldSeconds: \(formatDouble(normalized.settings.moveEverythingITermActivityHoldSeconds))  # how long active status persists after last change (sec)")
        lines.append("  moveEverythingITermRecentActivityColorize: \(normalized.settings.moveEverythingITermRecentActivityColorize ? "true" : "false")  # color-code window list by activity")
        lines.append("  moveEverythingITermRecentActivityColorizeNamedOnly: \(normalized.settings.moveEverythingITermRecentActivityColorizeNamedOnly ? "true" : "false")  # only color-code windows with custom names")
        lines.append("  moveEverythingActiveWindowHighlightColorize: \(normalized.settings.moveEverythingActiveWindowHighlightColorize ? "true" : "false")  # highlight OS-focused window in list")
        lines.append("")
        lines.append("  # Dark mode colors (hex #RRGGBB)")
        lines.append("  moveEverythingITermRecentActivityActiveColor: \(encodeScalar(normalized.settings.moveEverythingITermRecentActivityActiveColor))  # active tint color (dark mode)")
        lines.append("  moveEverythingITermRecentActivityIdleColor: \(encodeScalar(normalized.settings.moveEverythingITermRecentActivityIdleColor))  # idle tint color (dark mode)")
        lines.append("  moveEverythingActiveWindowHighlightColor: \(encodeScalar(normalized.settings.moveEverythingActiveWindowHighlightColor))  # focused window highlight color")
        lines.append("")
        lines.append("  # Light mode colors (hex #RRGGBB)")
        lines.append("  moveEverythingITermRecentActivityActiveColorLight: \(encodeScalar(normalized.settings.moveEverythingITermRecentActivityActiveColorLight))  # active tint color (light mode)")
        lines.append("  moveEverythingITermRecentActivityIdleColorLight: \(encodeScalar(normalized.settings.moveEverythingITermRecentActivityIdleColorLight))  # idle tint color (light mode)")
        lines.append("")
        lines.append("  # Window list row colors (hex #RRGGBB)")
        lines.append("  moveEverythingWindowListActiveColor: \(encodeScalar(normalized.settings.moveEverythingWindowListActiveColor))  # window list active color (dark mode)")
        lines.append("  moveEverythingWindowListIdleColor: \(encodeScalar(normalized.settings.moveEverythingWindowListIdleColor))  # window list idle color (dark mode)")
        lines.append("  moveEverythingWindowListActiveColorLight: \(encodeScalar(normalized.settings.moveEverythingWindowListActiveColorLight))  # window list active color (light mode)")
        lines.append("  moveEverythingWindowListIdleColorLight: \(encodeScalar(normalized.settings.moveEverythingWindowListIdleColorLight))  # window list idle color (light mode)")
        lines.append("")
        lines.append("  # ── iTerm2 Badges & Titles ─────────────────────────────────────")
        lines.append("  moveEverythingITermBadgeTopMargin: \(normalized.settings.moveEverythingITermBadgeTopMargin)  # badge top margin in points")
        lines.append("  moveEverythingITermBadgeRightMargin: \(normalized.settings.moveEverythingITermBadgeRightMargin)  # badge right margin in points")
        lines.append("  moveEverythingITermBadgeMaxWidth: \(normalized.settings.moveEverythingITermBadgeMaxWidth)")
        lines.append("  moveEverythingITermBadgeMaxHeight: \(normalized.settings.moveEverythingITermBadgeMaxHeight)")
        lines.append("  moveEverythingITermBadgeFromTitle: \(normalized.settings.moveEverythingITermBadgeFromTitle)  # auto-create badge from window title")
        lines.append("  moveEverythingITermTitleFromBadge: \(normalized.settings.moveEverythingITermTitleFromBadge)  # use badge text as window title")
        lines.append("  moveEverythingITermTitleAllCaps: \(normalized.settings.moveEverythingITermTitleAllCaps ? "true" : "false")  # ALL CAPS iTerm window titles")
        lines.append("  moveEverythingClaudeCodeRepoPrefix: \(normalized.settings.moveEverythingClaudeCodeRepoPrefix ? "true" : "false")  # show repo: title format for Claude Code windows")
        lines.append("  moveEverythingClaudeCodeRepoPrefixColor: \(encodeScalar(normalized.settings.moveEverythingClaudeCodeRepoPrefixColor))  # repo prefix color (dark mode)")
        lines.append("  moveEverythingClaudeCodeRepoPrefixColorLight: \(encodeScalar(normalized.settings.moveEverythingClaudeCodeRepoPrefixColorLight))  # repo prefix color (light mode)")
        lines.append("  moveEverythingActivityEnabled: \(normalized.settings.moveEverythingActivityEnabled ? "true" : "false")  # enable iTerm activity detection (screen polling + vibed)")
        lines.append("  moveEverythingVibedActivityEnabled: \(normalized.settings.moveEverythingVibedActivityEnabled ? "true" : "false")  # use vibed daemon (localhost:7483) for activity detection")
        lines.append("")
        lines.append("  # ── Window List Hotkeys ────────────────────────────────────────")
        lines.append("  # Format: {key: \"x\", modifiers: [\"ctrl\",\"shift\"]} or none")
        lines.append("  moveEverythingCloseWindowHotkey: \(encodeHotkey(normalized.settings.moveEverythingCloseWindowHotkey))")
        lines.append("  moveEverythingHideWindowHotkey: \(encodeHotkey(normalized.settings.moveEverythingHideWindowHotkey))")
        lines.append("  moveEverythingNameWindowHotkey: \(encodeHotkey(normalized.settings.moveEverythingNameWindowHotkey))")
        lines.append("  moveEverythingQuickViewHotkey: \(encodeHotkey(normalized.settings.moveEverythingQuickViewHotkey))")
        lines.append("  moveEverythingUndoWindowMovementHotkey: \(encodeHotkey(normalized.settings.moveEverythingUndoWindowMovementHotkey))")
        lines.append("  moveEverythingRedoWindowMovementHotkey: \(encodeHotkey(normalized.settings.moveEverythingRedoWindowMovementHotkey))")
        lines.append("  moveEverythingUndoWindowMovementForFocusedWindowHotkey: \(encodeHotkey(normalized.settings.moveEverythingUndoWindowMovementForFocusedWindowHotkey))")
        lines.append("  moveEverythingRedoWindowMovementForFocusedWindowHotkey: \(encodeHotkey(normalized.settings.moveEverythingRedoWindowMovementForFocusedWindowHotkey))")
        lines.append("  moveEverythingShowAllHiddenWindowsHotkey: \(encodeHotkey(normalized.settings.moveEverythingShowAllHiddenWindowsHotkey))")
        lines.append("  # Configurable retile shortcuts — mode: full | mini | iterm | nonITerm | hybrid")
        lines.append("  moveEverythingRetile1Hotkey: \(encodeHotkey(normalized.settings.moveEverythingRetile1Hotkey))")
        lines.append("  moveEverythingRetile1Mode: \(normalized.settings.moveEverythingRetile1Mode.rawValue)")
        lines.append("  moveEverythingRetile2Hotkey: \(encodeHotkey(normalized.settings.moveEverythingRetile2Hotkey))")
        lines.append("  moveEverythingRetile2Mode: \(normalized.settings.moveEverythingRetile2Mode.rawValue)")
        lines.append("  moveEverythingRetile3Hotkey: \(encodeHotkey(normalized.settings.moveEverythingRetile3Hotkey))")
        lines.append("  moveEverythingRetile3Mode: \(normalized.settings.moveEverythingRetile3Mode.rawValue)")
        lines.append("  moveEverythingQuickViewVerticalMode: \(normalized.settings.moveEverythingQuickViewVerticalMode.rawValue)  # fullHeight | fromCursor | padded")
        lines.append("")
        lines.append("# ── Shortcuts ───────────────────────────────────────────────────")
        lines.append("# Each shortcut has a hotkey and one or more placement steps.")
        lines.append("# Pressing the hotkey cycles through the steps in order.")
        lines.append("#")
        lines.append("# Shortcut fields:")
        lines.append("#   id: unique identifier (UUID)")
        lines.append("#   name: display name shown in the control center")
        lines.append("#   enabled: true/false — disabled shortcuts are ignored")
        lines.append("#   cycleDisplaysOnWrap: true = move to next display on wrap from last step")
        lines.append("#   canMoveControlCenter: true = this shortcut is allowed to move the control center when it's the focused window (overrides controlCenterSticky)")
        lines.append("#   hotkey: {key: \"x\", modifiers: [\"ctrl\",\"shift\",\"alt\",\"cmd\"]}")
        lines.append("#")
        lines.append("# Placement step fields:")
        lines.append("#   mode: grid | freeform")
        lines.append("#   display: active (focused display) | main | index-0, index-1, ...")
        lines.append("#")
        lines.append("# Grid mode — divides the display into a columns x rows grid:")
        lines.append("#   grid: {columns: 12, rows: 8, x: 0, y: 0, width: 6, height: 8}")
        lines.append("#   x,y = top-left cell (0-indexed), width,height = span in cells")
        lines.append("#   Example: left half  = {columns:2, rows:1, x:0, y:0, width:1, height:1}")
        lines.append("#   Example: right half = {columns:2, rows:1, x:1, y:0, width:1, height:1}")
        lines.append("#   Example: top-left quarter on a 12x8 grid = {columns:12, rows:8, x:0, y:0, width:6, height:4}")
        lines.append("#")
        lines.append("# Freeform mode — position as fraction of display (0.0 to 1.0):")
        lines.append("#   rect: {x: 0.0, y: 0.0, width: 0.5, height: 1.0}  # left half")
        lines.append("#")
        lines.append("shortcuts:")

        for shortcut in normalized.shortcuts {
            lines.append("  - id: \(encodeScalar(shortcut.id))")
            lines.append("    name: \(encodeScalar(shortcut.name))")
            lines.append("    enabled: \(shortcut.enabled ? "true" : "false")")
            lines.append("    cycleDisplaysOnWrap: \(shortcut.cycleDisplaysOnWrap ? "true" : "false")")
            lines.append("    canMoveControlCenter: \(shortcut.canMoveControlCenter ? "true" : "false")")
            lines.append("    ignoreExcludePinnedWindows: \(shortcut.ignoreExcludePinnedWindows ? "true" : "false")")
            lines.append("    resetBeforeFirstStep: \(shortcut.resetBeforeFirstStep ? "true" : "false")")
            lines.append("    resetBeforeFirstStepMoveCursor: \(shortcut.resetBeforeFirstStepMoveCursor ? "true" : "false")")
            if shortcut.useForRetiling != "no" {
                lines.append("    useForRetiling: \(encodeScalar(shortcut.useForRetiling))")
            }
            lines.append("    hotkey:")
            lines.append("      key: \(encodeScalar(shortcut.hotkey.key.lowercased()))")
            lines.append("      modifiers:")
            for modifier in shortcut.hotkey.modifiers {
                lines.append("        - \(encodeScalar(modifier.lowercased()))")
            }
            lines.append("    placements:")
            for placement in shortcut.placements {
                lines.append("      - id: \(encodeScalar(placement.id))")
                lines.append("        title: \(encodeScalar(placement.title))")
                lines.append("        mode: \(placement.mode.rawValue)")
                lines.append("        display: \(placement.display.rawValue)")
                switch placement.mode {
                case .grid:
                    let grid = placement.grid ?? GridPlacement(columns: normalized.settings.defaultGridColumns, rows: normalized.settings.defaultGridRows, x: 0, y: 0, width: normalized.settings.defaultGridColumns, height: normalized.settings.defaultGridRows)
                    lines.append("        grid:")
                    lines.append("          columns: \(grid.columns)")
                    lines.append("          rows: \(grid.rows)")
                    lines.append("          x: \(grid.x)")
                    lines.append("          y: \(grid.y)")
                    lines.append("          width: \(grid.width)")
                    lines.append("          height: \(grid.height)")
                case .freeform:
                    let rect = placement.rect ?? FreeformRect(x: 0, y: 0, width: 1, height: 1)
                    lines.append("        rect:")
                    lines.append("          x: \(formatDouble(rect.x))")
                    lines.append("          y: \(formatDouble(rect.y))")
                    lines.append("          width: \(formatDouble(rect.width))")
                    lines.append("          height: \(formatDouble(rect.height))")
                }
            }
        }

        return lines.joined(separator: "\n") + "\n"
    }

    private static func preprocess(_ yaml: String) -> [ParsedLine] {
        return yaml
            .split(separator: "\n", omittingEmptySubsequences: false)
            .enumerated()
            .compactMap { index, rawLine -> ParsedLine? in
                let lineNumber = index + 1
                let stripped = stripComment(String(rawLine)).trimmingCharacters(in: .newlines)
                if stripped.trimmingCharacters(in: .whitespaces).isEmpty {
                    return nil
                }

                let spaces = stripped.prefix { $0 == " " }.count
                let content = String(stripped.dropFirst(spaces))
                return ParsedLine(number: lineNumber, indent: spaces, content: content)
            }
    }

    private static func stripComment(_ line: String) -> String {
        var inSingle = false
        var inDouble = false
        var result = ""

        for character in line {
            if character == "'" && !inDouble {
                inSingle.toggle()
            } else if character == "\"" && !inSingle {
                inDouble.toggle()
            }

            if character == "#" && !inSingle && !inDouble {
                break
            }
            result.append(character)
        }

        return result
    }

    private static func parseKeyValue(_ line: ParsedLine) throws -> (String, String?) {
        guard let separator = line.content.firstIndex(of: ":") else {
            throw ConfigParseError.invalidLine(line.number, "Expected key/value")
        }

        let key = line.content[..<separator].trimmingCharacters(in: .whitespaces)
        let rawValue = line.content[line.content.index(after: separator)...].trimmingCharacters(in: .whitespaces)

        if key.isEmpty {
            throw ConfigParseError.invalidLine(line.number, "Missing key")
        }

        return (key, rawValue.isEmpty ? nil : rawValue)
    }

    private static func parseInlineKeyValue(_ inline: String, lineNumber: Int) throws -> (String, String?) {
        guard let separator = inline.firstIndex(of: ":") else {
            throw ConfigParseError.invalidLine(lineNumber, "Expected inline key/value")
        }

        let key = inline[..<separator].trimmingCharacters(in: .whitespaces)
        let value = inline[inline.index(after: separator)...].trimmingCharacters(in: .whitespaces)

        if key.isEmpty {
            throw ConfigParseError.invalidLine(lineNumber, "Missing key in inline item")
        }

        return (key, value.isEmpty ? nil : value)
    }

    private static func parseScalar(_ raw: String) -> String {
        let value = raw.trimmingCharacters(in: .whitespaces)
        guard value.count >= 2 else {
            return value
        }

        if value.hasPrefix("\""), value.hasSuffix("\"") {
            let inner = String(value.dropFirst().dropLast())
            return decodeDoubleQuotedEscapes(inner)
        }

        if value.hasPrefix("'"), value.hasSuffix("'") {
            let inner = String(value.dropFirst().dropLast())
            return inner.replacingOccurrences(of: "''", with: "'")
        }

        return value
    }

    private static func encodeScalar(_ value: String) -> String {
        if value.isEmpty {
            return "\"\""
        }

        let reserved = CharacterSet(charactersIn: ":#[]{}!,&*?|<>=%@`\"")
        if value.rangeOfCharacter(from: .whitespacesAndNewlines) != nil || value.rangeOfCharacter(from: reserved) != nil {
            let escaped = value
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
                .replacingOccurrences(of: "\n", with: "\\n")
                .replacingOccurrences(of: "\r", with: "\\r")
                .replacingOccurrences(of: "\t", with: "\\t")
            return "\"\(escaped)\""
        }

        return value
    }

    private static func decodeDoubleQuotedEscapes(_ value: String) -> String {
        var decoded = ""
        var iterator = value.makeIterator()

        while let character = iterator.next() {
            guard character == "\\" else {
                decoded.append(character)
                continue
            }

            guard let escaped = iterator.next() else {
                decoded.append("\\")
                break
            }

            switch escaped {
            case "\\":
                decoded.append("\\")
            case "\"":
                decoded.append("\"")
            case "n":
                decoded.append("\n")
            case "r":
                decoded.append("\r")
            case "t":
                decoded.append("\t")
            default:
                decoded.append("\\")
                decoded.append(escaped)
            }
        }

        return decoded
    }

    private static func applyShortcutKeyValue(
        key: String,
        value: String?,
        to storage: inout ShortcutConfig?,
        lineNumber: Int
    ) throws {
        guard var shortcut = storage else {
            throw ConfigParseError.invalidLine(lineNumber, "Shortcut context is missing")
        }

        switch key {
        case "id":
            shortcut.id = parseScalar(try requiredValue(value, lineNumber: lineNumber, field: "shortcut.id"))
        case "name":
            shortcut.name = parseScalar(try requiredValue(value, lineNumber: lineNumber, field: "shortcut.name"))
        case "enabled":
            shortcut.enabled = try parseRequiredBoolean(value, lineNumber: lineNumber, field: "shortcut.enabled")
        case "cycleDisplaysOnWrap":
            shortcut.cycleDisplaysOnWrap = try parseRequiredBoolean(value, lineNumber: lineNumber, field: "shortcut.cycleDisplaysOnWrap")
        case "canMoveControlCenter", "controlCenterOnly":
            // `controlCenterOnly` is the legacy key; treat it as an alias when reading.
            shortcut.canMoveControlCenter = try parseRequiredBoolean(value, lineNumber: lineNumber, field: "shortcut.canMoveControlCenter")
        case "ignoreExcludePinnedWindows", "ignoreExcludeControlCenter":
            shortcut.ignoreExcludePinnedWindows = try parseRequiredBoolean(value, lineNumber: lineNumber, field: "shortcut.ignoreExcludePinnedWindows")
        case "resetBeforeFirstStep":
            shortcut.resetBeforeFirstStep = try parseRequiredBoolean(value, lineNumber: lineNumber, field: "shortcut.resetBeforeFirstStep")
        case "resetBeforeFirstStepMoveCursor":
            shortcut.resetBeforeFirstStepMoveCursor = try parseRequiredBoolean(value, lineNumber: lineNumber, field: "shortcut.resetBeforeFirstStepMoveCursor")
        case "useForRetiling":
            shortcut.useForRetiling = parseScalar(try requiredValue(value, lineNumber: lineNumber, field: "shortcut.useForRetiling"))
        default:
            break
        }
        storage = shortcut
    }

    private static func applyPlacementKeyValue(
        key: String,
        value: String?,
        to storage: inout PlacementStep?,
        lineNumber: Int
    ) throws {
        guard var placement = storage else {
            throw ConfigParseError.invalidLine(lineNumber, "Placement context is missing")
        }

        switch key {
        case "id":
            placement.id = parseScalar(try requiredValue(value, lineNumber: lineNumber, field: "placement.id"))
        case "title":
            placement.title = value.map(parseScalar) ?? ""
        case "mode":
            let parsed = parseScalar(try requiredValue(value, lineNumber: lineNumber, field: "placement.mode")).lowercased()
            guard let mode = PlacementMode(rawValue: parsed) else {
                throw ConfigParseError.invalidValue(lineNumber, "Unsupported placement mode: \(parsed)")
            }
            placement.mode = mode
        case "display":
            let parsed = parseScalar(try requiredValue(value, lineNumber: lineNumber, field: "placement.display")).lowercased()
            guard let display = DisplayTarget.parse(parsed) else {
                throw ConfigParseError.invalidValue(lineNumber, "Unsupported display target: \(parsed)")
            }
            placement.display = display
        default:
            throw ConfigParseError.invalidLine(lineNumber, "Unknown placement key: \(key)")
        }
        storage = placement
    }

    private static func applyPlacementShapeKeyValue(
        parentKey: String,
        key: String,
        value: String,
        to storage: inout PlacementStep?,
        lineNumber: Int,
        settings: Settings
    ) throws {
        guard var placement = storage else {
            throw ConfigParseError.invalidLine(lineNumber, "Placement context is missing")
        }

        switch parentKey {
        case "grid":
            var grid = placement.grid ?? GridPlacement(
                columns: settings.defaultGridColumns,
                rows: settings.defaultGridRows,
                x: 0,
                y: 0,
                width: settings.defaultGridColumns,
                height: settings.defaultGridRows
            )
            let parsed = try parseInt(value, lineNumber: lineNumber, field: "grid.\(key)")
            switch key {
            case "columns": grid.columns = parsed
            case "rows": grid.rows = parsed
            case "x": grid.x = parsed
            case "y": grid.y = parsed
            case "width": grid.width = parsed
            case "height": grid.height = parsed
            default:
                throw ConfigParseError.invalidLine(lineNumber, "Unknown grid key: \(key)")
            }
            placement.grid = grid
            placement.rect = nil
        case "rect":
            var rect = placement.rect ?? FreeformRect(x: 0, y: 0, width: 1, height: 1)
            let parsed = try parseDouble(value, lineNumber: lineNumber, field: "rect.\(key)")
            switch key {
            case "x": rect.x = parsed
            case "y": rect.y = parsed
            case "width": rect.width = parsed
            case "height": rect.height = parsed
            default:
                throw ConfigParseError.invalidLine(lineNumber, "Unknown rect key: \(key)")
            }
            placement.rect = rect
            placement.grid = nil
        default:
            throw ConfigParseError.invalidLine(lineNumber, "Unknown placement object: \(parentKey)")
        }
        storage = placement
    }

    private static func formatDouble(_ value: Double) -> String {
        if value == floor(value) {
            return String(Int(value))
        }
        return String(format: "%.4f", value)
            .replacingOccurrences(of: "0+$", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\\.$", with: "", options: .regularExpression)
    }

    private static func parseBoolean(_ raw: String, lineNumber: Int, field: String) throws -> Bool {
        switch parseScalar(raw).lowercased() {
        case "true", "yes", "on", "1":
            return true
        case "false", "no", "off", "0":
            return false
        default:
            throw ConfigParseError.invalidValue(lineNumber, "\(field) must be true or false")
        }
    }

    private static func parseRequiredBoolean(_ value: String?, lineNumber: Int, field: String) throws -> Bool {
        try parseBoolean(
            try requiredValue(value, lineNumber: lineNumber, field: field),
            lineNumber: lineNumber,
            field: field
        )
    }

    private static func requiredValue(_ value: String?, lineNumber: Int, field: String) throws -> String {
        guard let value else {
            throw ConfigParseError.invalidValue(lineNumber, "\(field) requires a value")
        }
        return value
    }

    private static func parseInt(_ raw: String, lineNumber: Int, field: String) throws -> Int {
        guard let parsed = Int(parseScalar(raw)) else {
            throw ConfigParseError.invalidValue(lineNumber, "\(field) must be an integer")
        }
        return parsed
    }

    private static func parseDouble(_ raw: String, lineNumber: Int, field: String) throws -> Double {
        guard let parsed = Double(parseScalar(raw)) else {
            throw ConfigParseError.invalidValue(lineNumber, "\(field) must be a number")
        }
        return parsed
    }

    private static func parseRetileMode(
        _ raw: String,
        lineNumber: Int,
        field: String
    ) throws -> MoveEverythingRetileShortcutMode {
        let scalar = parseScalar(raw).trimmingCharacters(in: .whitespacesAndNewlines)
        switch scalar.lowercased() {
        case "full": return .full
        case "mini": return .mini
        case "iterm": return .iterm
        case "noniterm", "non-iterm": return .nonITerm
        case "hybrid": return .hybrid
        default:
            throw ConfigParseError.invalidValue(
                lineNumber,
                "\(field) must be one of: full, mini, iterm, nonITerm, hybrid"
            )
        }
    }

    private static func parseHotkey(_ raw: String, lineNumber: Int, field: String) throws -> Hotkey? {
        let scalar = parseScalar(raw)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if scalar.isEmpty || scalar == "none" || scalar == "null" {
            return nil
        }

        let rawParts = scalar
            .split(separator: "+", omittingEmptySubsequences: false)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard let key = rawParts.last else {
            throw ConfigParseError.invalidValue(lineNumber, "\(field) must include a key")
        }

        let modifiers = rawParts.dropLast()
        for modifier in modifiers {
            guard hotkeyModifierOrder.contains(modifier) else {
                throw ConfigParseError.invalidValue(
                    lineNumber,
                    "\(field) has unsupported modifier '\(modifier)'"
                )
            }
        }

        let normalizedModifiers = Array(Set(modifiers)).sorted(by: modifierCompare)
        return Hotkey(key: key, modifiers: normalizedModifiers)
    }

    private static func encodeHotkey(_ hotkey: Hotkey?) -> String {
        guard let hotkey else {
            return "\"\""
        }
        let key = hotkey.key
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !key.isEmpty else {
            return "\"\""
        }

        let modifiers = Array(
            Set(
                hotkey.modifiers.map {
                    $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                }
            )
        )
        .filter { !$0.isEmpty }
        .sorted(by: modifierCompare)

        return encodeScalar((modifiers + [key]).joined(separator: "+"))
    }

    private static func modifierCompare(_ left: String, _ right: String) -> Bool {
        let leftIndex = hotkeyModifierOrder.firstIndex(of: left) ?? Int.max
        let rightIndex = hotkeyModifierOrder.firstIndex(of: right) ?? Int.max
        if leftIndex == rightIndex {
            return left < right
        }
        return leftIndex < rightIndex
    }

    private static let hotkeyModifierOrder: [String] = ["cmd", "ctrl", "alt", "shift", "fn"]
}
