import Foundation
import Testing
@testable import VibeGrid

@Test func normalizedMakesShortcutAndPlacementIDsUnique() {
    let config = AppConfig(
        version: 1,
        settings: .default,
        shortcuts: [
            ShortcutConfig(
                id: "dup",
                name: "One",
                hotkey: Hotkey(key: "left", modifiers: ["cmd", "alt"]),
                placements: [
                    PlacementStep(
                        id: "placement",
                        title: "",
                        mode: .grid,
                        display: .active,
                        grid: GridPlacement(columns: 12, rows: 8, x: 0, y: 0, width: 6, height: 8),
                        rect: nil
                    ),
                    PlacementStep(
                        id: "placement",
                        title: "Second placement",
                        mode: .grid,
                        display: .active,
                        grid: GridPlacement(columns: 12, rows: 8, x: 6, y: 0, width: 6, height: 8),
                        rect: nil
                    ),
                ]
            ),
            ShortcutConfig(
                id: "dup",
                name: "Two",
                hotkey: Hotkey(key: "right", modifiers: ["cmd", "alt"]),
                placements: [
                    PlacementStep(
                        id: "placement",
                        title: "",
                        mode: .freeform,
                        display: .active,
                        grid: nil,
                        rect: FreeformRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8)
                    ),
                ]
            ),
        ]
    )

    let normalized = config.normalized()

    #expect(normalized.shortcuts.map(\.id) == ["dup", "dup-2"])
    #expect(normalized.shortcuts[0].placements.map(\.id) == ["placement", "placement-2"])
    #expect(normalized.shortcuts[0].placements[0].title == "")
    #expect(normalized.shortcuts[0].placements[1].title == "Second placement")
    #expect(normalized.shortcuts[1].placements[0].id == "placement")
    #expect(normalized.shortcuts[1].placements[0].title == "")
}

@Test func yamlRoundTripPreservesBlankStepTitles() throws {
    let yaml = YAMLConfigCodec.encode(AppConfig.default)
    let decoded = try YAMLConfigCodec.decode(yaml)
    let titles = decoded.shortcuts.flatMap(\.placements).map(\.title)
    #expect(!titles.isEmpty)
    #expect(titles.allSatisfy { $0.isEmpty })
}

@Test func settingsDecodeFillsMissingDefaults() throws {
    let data = Data("{}".utf8)
    let decoded = try JSONDecoder().decode(Settings.self, from: data)
    #expect(decoded.defaultGridColumns == 12)
    #expect(decoded.defaultGridRows == 8)
    #expect(decoded.gap == 2)
    #expect(decoded.defaultCycleDisplaysOnWrap == false)
    #expect(decoded.animationDuration == 0)
    #expect(decoded.controlCenterScale == 1)
    #expect(decoded.largerFonts == true)
    #expect(decoded.themeMode == .system)
    #expect(decoded.moveEverythingMoveOnSelection == .miniControlCenterOnTop)
    #expect(decoded.moveEverythingCenterWidthPercent == 33)
    #expect(decoded.moveEverythingCenterHeightPercent == 70)
    #expect(decoded.moveEverythingOverlayMode == .persistent)
    #expect(decoded.moveEverythingOverlayDuration == 2)
    #expect(decoded.moveEverythingStartAlwaysOnTop == false)
    #expect(decoded.moveEverythingStartMoveToBottom == false)
    #expect(decoded.moveEverythingAdvancedControlCenterHover == true)
    #expect(decoded.moveEverythingStickyHoverStealFocus == false)
    #expect(decoded.moveEverythingCloseHideHotkeysOutsideMode == false)
    #expect(decoded.moveEverythingITermRecentActivityTimeout == 10)
    #expect(decoded.moveEverythingITermRecentActivityActiveText == "[ACTIVE]")
    #expect(decoded.moveEverythingITermRecentActivityIdleText == "")
    #expect(decoded.moveEverythingITermRecentActivityBadgeEnabled == false)
    #expect(decoded.moveEverythingITermRecentActivityColorize == true)
    #expect(decoded.moveEverythingActiveWindowHighlightColorize == true)
    #expect(decoded.moveEverythingActiveWindowHighlightColor == "#4D88D4")
    #expect(decoded.moveEverythingITermRecentActivityActiveColor == "#2F8F4E")
    #expect(decoded.moveEverythingITermRecentActivityIdleColor == "#BA4D4D")
    #expect(decoded.moveEverythingCloseWindowHotkey == nil)
    #expect(decoded.moveEverythingHideWindowHotkey == nil)
}

@Test func settingsDecodeMigratesLegacyDarkModeField() throws {
    let data = Data(#"{"darkMode":true}"#.utf8)
    let decoded = try JSONDecoder().decode(Settings.self, from: data)
    #expect(decoded.themeMode == .dark)
}

@Test func settingsDecodeMigratesLegacyControlCenterOnlySelectionMode() throws {
    let data = Data(#"{"moveEverythingMoveOnSelection":"controlCenterOnly"}"#.utf8)
    let decoded = try JSONDecoder().decode(Settings.self, from: data)
    #expect(decoded.moveEverythingMoveOnSelection == .miniControlCenterOnTop)
}

@Test func settingsDecodeAcceptsAdvancedControlCenterSelectionModeAlias() throws {
    let data = Data(#"{"moveEverythingMoveOnSelection":"advancedControlCenterOnTop"}"#.utf8)
    let decoded = try JSONDecoder().decode(Settings.self, from: data)
    #expect(decoded.moveEverythingMoveOnSelection == .miniControlCenterOnTop)
}

@Test func settingsDecodeDefaultsMoveToBottomStartBySelectionModeWhenMissing() throws {
    let data = Data(#"{"moveEverythingMoveOnSelection":"firstSelection"}"#.utf8)
    let decoded = try JSONDecoder().decode(Settings.self, from: data)
    #expect(decoded.moveEverythingMoveOnSelection == .firstSelection)
    #expect(decoded.moveEverythingStartMoveToBottom == false)
}

@Test func settingsDecodeMigratesLegacyDarkModeFalseToSystem() throws {
    let data = Data(#"{"darkMode":false}"#.utf8)
    let decoded = try JSONDecoder().decode(Settings.self, from: data)
    #expect(decoded.themeMode == .system)
}

@Test func normalizedClampsControlCenterScale() {
    let config = AppConfig(
        version: 1,
        settings: Settings(
            defaultGridColumns: 12,
            defaultGridRows: 8,
            gap: 2,
            defaultCycleDisplaysOnWrap: false,
            animationDuration: 0,
            controlCenterScale: 8
        ),
        shortcuts: []
    )

    let normalized = config.normalized()
    #expect(normalized.settings.controlCenterScale == 2)
}

@Test func normalizedClampsWindowListITermActivitySettings() {
    let config = AppConfig(
        version: 1,
        settings: Settings(
            defaultGridColumns: 12,
            defaultGridRows: 8,
            gap: 2,
            defaultCycleDisplaysOnWrap: false,
            animationDuration: 0,
            moveEverythingITermRecentActivityTimeout: 999,
            moveEverythingITermRecentActivityActiveText: "  [LIVE]  ",
            moveEverythingITermRecentActivityIdleText: "  ",
            moveEverythingActiveWindowHighlightColor: "invalid",
            moveEverythingITermRecentActivityActiveColor: "#1a2",
            moveEverythingITermRecentActivityIdleColor: "invalid"
        ),
        shortcuts: []
    )

    let normalized = config.normalized()
    #expect(normalized.settings.moveEverythingITermRecentActivityTimeout == 300)
    #expect(normalized.settings.moveEverythingITermRecentActivityActiveText == "[LIVE]")
    #expect(normalized.settings.moveEverythingITermRecentActivityIdleText == "")
    #expect(normalized.settings.moveEverythingActiveWindowHighlightColor == "#4D88D4")
    #expect(normalized.settings.moveEverythingITermRecentActivityActiveColor == "#11AA22")
    #expect(normalized.settings.moveEverythingITermRecentActivityIdleColor == "#BA4D4D")
}

@Test func yamlShortcutWrapDefaultsToSettingsValueWhenMissing() throws {
    let yaml = """
version: 1
settings:
  defaultGridColumns: 12
  defaultGridRows: 8
  gap: 2
  defaultCycleDisplaysOnWrap: true
  animationDuration: 0
shortcuts:
  - id: sample
    name: Sample
    hotkey:
      key: left
      modifiers:
        - cmd
    placements:
      - id: left
        title: ""
        mode: grid
        display: active
        grid:
          columns: 12
          rows: 8
          x: 0
          y: 0
          width: 6
          height: 8
"""

    let decoded = try YAMLConfigCodec.decode(yaml)
    #expect(decoded.shortcuts.count == 1)
    #expect(decoded.shortcuts[0].cycleDisplaysOnWrap == true)
    #expect(decoded.shortcuts[0].controlCenterOnly == false)
    #expect(decoded.settings.themeMode == .system)
}

@Test func yamlShortcutParsesControlCenterOnlyFlag() throws {
    let yaml = """
version: 1
settings:
  defaultGridColumns: 12
  defaultGridRows: 8
  gap: 2
  defaultCycleDisplaysOnWrap: false
  animationDuration: 0
shortcuts:
  - id: control-center
    name: Control Center
    controlCenterOnly: true
    hotkey:
      key: c
      modifiers:
        - cmd
    placements:
      - id: center
        title: ""
        mode: freeform
        display: active
        rect:
          x: 0.1
          y: 0.1
          width: 0.8
          height: 0.8
"""

    let decoded = try YAMLConfigCodec.decode(yaml)
    #expect(decoded.shortcuts.count == 1)
    #expect(decoded.shortcuts[0].controlCenterOnly == true)
}

@Test func yamlRoundTripPreservesEscapedQuotesAndBackslashes() throws {
    let config = AppConfig(
        version: 1,
        settings: .default,
        shortcuts: [
            ShortcutConfig(
                id: "quote-test",
                name: "Say \"Hi\" \\ Now",
                hotkey: Hotkey(key: "k", modifiers: ["cmd"]),
                placements: [
                    PlacementStep(
                        id: "step",
                        title: "Path: C:\\Tools\\\"VibeGrid\"",
                        mode: .freeform,
                        display: .active,
                        grid: nil,
                        rect: FreeformRect(x: 0.2, y: 0.2, width: 0.5, height: 0.5)
                    ),
                ]
            ),
        ]
    )

    let yaml = YAMLConfigCodec.encode(config)
    let decoded = try YAMLConfigCodec.decode(yaml)
    #expect(decoded.shortcuts.count == 1)
    #expect(decoded.shortcuts[0].name == "Say \"Hi\" \\ Now")
    #expect(decoded.shortcuts[0].placements.count == 1)
    #expect(decoded.shortcuts[0].placements[0].title == "Path: C:\\Tools\\\"VibeGrid\"")
}

@Test func yamlDecodeParseRealWin11Config() throws {
    // Parse a real config file exported from the Windows 11 Go binary.
    let url = URL(fileURLWithPath: "/Users/ademeure/Downloads/vibegrid-config_win11.yaml")
    guard FileManager.default.fileExists(atPath: url.path) else { return }
    let text = try String(contentsOf: url, encoding: .utf8)
    let decoded = try YAMLConfigCodec.decode(text)
    #expect(decoded.shortcuts.count == 12)
    #expect(decoded.shortcuts[0].name == "Max")
    #expect(decoded.shortcuts[0].hotkey.key == "keypad_asterisk")
    #expect(decoded.settings.themeMode == .dark)
    #expect(decoded.settings.moveEverythingCloseWindowHotkey?.key == "keypad_slash")
    #expect(decoded.settings.moveEverythingHideWindowHotkey == nil)
}

@Test func yamlDecodeParseFourSpaceIndentation() throws {
    // Go's yaml.v3 (used by the Windows binary) defaults to 4-space mapping
    // indent but uses 2-char offsets after YAML sequence indicators (- ),
    // producing indent levels 0,4,6,8,10,12 instead of the 0,2,4,6,8,10
    // that the parser expects. Verify the normalizer handles this.
    let yaml = """
version: 1
settings:
    defaultGridColumns: 12
    defaultGridRows: 8
    gap: 0
    defaultCycleDisplaysOnWrap: false
    animationDuration: 0
    controlCenterScale: 1
    themeMode: dark
    moveEverythingCloseWindowHotkey: cmd+ctrl+alt+keypad_slash
shortcuts:
    - id: shortcut-1
      name: Max
      enabled: true
      cycleDisplaysOnWrap: true
      controlCenterOnly: false
      hotkey:
        key: keypad_asterisk
        modifiers:
            - ctrl
            - alt
      placements:
        - id: step-1
          title:
          mode: grid
          display: active
          grid:
            columns: 12
            rows: 8
            x: 0
            y: 0
            width: 12
            height: 8
        - id: step-2
          title:
          mode: freeform
          display: main
          rect:
            x: 0.1
            y: 0.2
            width: 0.5
            height: 0.6
"""

    let decoded = try YAMLConfigCodec.decode(yaml)
    #expect(decoded.settings.defaultGridColumns == 12)
    #expect(decoded.settings.gap == 0)
    #expect(decoded.settings.themeMode == .dark)
    #expect(decoded.settings.moveEverythingCloseWindowHotkey?.key == "keypad_slash")
    #expect(decoded.settings.moveEverythingCloseWindowHotkey?.modifiers == ["alt", "cmd", "ctrl"])
    #expect(decoded.shortcuts.count == 1)
    #expect(decoded.shortcuts[0].name == "Max")
    #expect(decoded.shortcuts[0].cycleDisplaysOnWrap == true)
    #expect(decoded.shortcuts[0].hotkey.key == "keypad_asterisk")
    #expect(Set(decoded.shortcuts[0].hotkey.modifiers) == Set(["ctrl", "alt"]))
    #expect(decoded.shortcuts[0].placements.count == 2)
    #expect(decoded.shortcuts[0].placements[0].mode == .grid)
    #expect(decoded.shortcuts[0].placements[0].grid?.width == 12)
    #expect(decoded.shortcuts[0].placements[1].mode == .freeform)
    #expect(decoded.shortcuts[0].placements[1].display == .main)
    #expect(decoded.shortcuts[0].placements[1].rect?.x == 0.1)
    #expect(decoded.shortcuts[0].placements[1].rect?.height == 0.6)
}

@Test func yamlDecodeIgnoresRemovedMoveEverythingHotkeysButStillRejectsUnknownSettings() throws {
    let legacyYaml = """
version: 1
settings:
  defaultGridColumns: 12
  defaultGridRows: 8
  gap: 2
  defaultCycleDisplaysOnWrap: false
  animationDuration: 0
  moveEverythingSplitITermTabHotkey: cmd+shift+i
  moveEverythingStartStopHotkey: ctrl+alt+space
shortcuts: []
"""

    let decoded = try YAMLConfigCodec.decode(legacyYaml)
    let reencoded = YAMLConfigCodec.encode(decoded)

    #expect(!reencoded.contains("moveEverythingSplitITermTabHotkey"))
    #expect(!reencoded.contains("moveEverythingStartStopHotkey"))

    let invalidYaml = """
version: 1
settings:
  defaultGridColumnsTypo: 12
shortcuts: []
"""

    #expect(throws: ConfigParseError.self) {
        try YAMLConfigCodec.decode(invalidYaml)
    }
}

@Test func yamlDecodeParsesMoveEverythingHotkeyStrings() throws {
    let yaml = """
version: 1
settings:
  defaultGridColumns: 12
  defaultGridRows: 8
  gap: 2
  defaultCycleDisplaysOnWrap: false
  animationDuration: 0
  controlCenterScale: 1
  themeMode: system
  moveEverythingMoveOnSelection: always
  moveEverythingCenterWidthPercent: 40
  moveEverythingCenterHeightPercent: 60
  moveEverythingOverlayMode: timed
  moveEverythingOverlayDuration: 2.4
  moveEverythingAdvancedControlCenterHover: false
  moveEverythingStickyHoverStealFocus: true
  moveEverythingCloseHideHotkeysOutsideMode: true
  moveEverythingCloseWindowHotkey: cmd+shift+w
  moveEverythingHideWindowHotkey: alt+cmd+h
shortcuts:
"""

    let decoded = try YAMLConfigCodec.decode(yaml)
    #expect(decoded.settings.moveEverythingMoveOnSelection == .always)
    #expect(decoded.settings.moveEverythingCenterWidthPercent == 40)
    #expect(decoded.settings.moveEverythingCenterHeightPercent == 60)
    #expect(decoded.settings.moveEverythingOverlayMode == .timed)
    #expect(decoded.settings.moveEverythingOverlayDuration == 2.4)
    #expect(decoded.settings.moveEverythingStartMoveToBottom == false)
    #expect(decoded.settings.moveEverythingAdvancedControlCenterHover == false)
    #expect(decoded.settings.moveEverythingStickyHoverStealFocus == true)
    #expect(decoded.settings.moveEverythingCloseHideHotkeysOutsideMode == true)
    #expect(decoded.settings.moveEverythingCloseWindowHotkey?.key == "w")
    #expect(decoded.settings.moveEverythingCloseWindowHotkey?.modifiers == ["cmd", "shift"])
    #expect(decoded.settings.moveEverythingHideWindowHotkey?.key == "h")
    #expect(decoded.settings.moveEverythingHideWindowHotkey?.modifiers == ["alt", "cmd"])
}
