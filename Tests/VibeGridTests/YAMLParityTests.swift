import Foundation
import Testing
@testable import VibeGrid

// MARK: - Shared assertion helper

/// Verifies the parsed config matches expected values from the parity fixtures.
/// Both parity_2space.yaml and parity_4space.yaml encode the same config,
/// so every assertion here applies to both.
private func assertParityConfig(_ config: AppConfig, sourceContext: SourceLocation = #_sourceLocation) {
    // Settings
    #expect(config.settings.defaultGridColumns == 12, sourceLocation: sourceContext)
    #expect(config.settings.defaultGridRows == 8, sourceLocation: sourceContext)
    #expect(config.settings.gap == 4, sourceLocation: sourceContext)
    #expect(config.settings.defaultCycleDisplaysOnWrap == true, sourceLocation: sourceContext)
    #expect(config.settings.animationDuration == 0.5, sourceLocation: sourceContext)
    #expect(config.settings.controlCenterScale == 1.25, sourceLocation: sourceContext)
    #expect(config.settings.largerFonts == true, sourceLocation: sourceContext)
    #expect(config.settings.themeMode == .dark, sourceLocation: sourceContext)
    #expect(config.settings.moveEverythingMoveOnSelection == .always, sourceLocation: sourceContext)
    #expect(config.settings.moveEverythingCenterWidthPercent == 50, sourceLocation: sourceContext)
    #expect(config.settings.moveEverythingCenterHeightPercent == 80, sourceLocation: sourceContext)
    #expect(config.settings.moveEverythingOverlayMode == .timed, sourceLocation: sourceContext)
    #expect(config.settings.moveEverythingOverlayDuration == 3, sourceLocation: sourceContext)
    #expect(config.settings.moveEverythingStartAlwaysOnTop == true, sourceLocation: sourceContext)
    #expect(config.settings.moveEverythingStartMoveToBottom == true, sourceLocation: sourceContext)
    #expect(config.settings.moveEverythingAdvancedControlCenterHover == false, sourceLocation: sourceContext)
    #expect(config.settings.moveEverythingStickyHoverStealFocus == true, sourceLocation: sourceContext)
    #expect(config.settings.moveEverythingCloseHideHotkeysOutsideMode == true, sourceLocation: sourceContext)
    #expect(config.settings.moveEverythingCloseWindowHotkey?.key == "w", sourceLocation: sourceContext)
    #expect(config.settings.moveEverythingCloseWindowHotkey?.modifiers == ["cmd", "shift"], sourceLocation: sourceContext)
    #expect(config.settings.moveEverythingHideWindowHotkey?.key == "h", sourceLocation: sourceContext)
    #expect(config.settings.moveEverythingHideWindowHotkey?.modifiers == ["alt", "cmd"], sourceLocation: sourceContext)

    // Shortcuts
    #expect(config.shortcuts.count == 2, sourceLocation: sourceContext)

    let left = config.shortcuts[0]
    #expect(left.name == "Left Half", sourceLocation: sourceContext)
    #expect(left.enabled == true, sourceLocation: sourceContext)
    #expect(left.cycleDisplaysOnWrap == false, sourceLocation: sourceContext)
    #expect(left.controlCenterOnly == false, sourceLocation: sourceContext)
    #expect(left.hotkey.key == "left", sourceLocation: sourceContext)
    #expect(Set(left.hotkey.modifiers) == Set(["cmd", "alt"]), sourceLocation: sourceContext)
    #expect(left.placements.count == 1, sourceLocation: sourceContext)
    #expect(left.placements[0].mode == .grid, sourceLocation: sourceContext)
    #expect(left.placements[0].display == .active, sourceLocation: sourceContext)
    #expect(left.placements[0].grid?.columns == 12, sourceLocation: sourceContext)
    #expect(left.placements[0].grid?.rows == 8, sourceLocation: sourceContext)
    #expect(left.placements[0].grid?.x == 0, sourceLocation: sourceContext)
    #expect(left.placements[0].grid?.y == 0, sourceLocation: sourceContext)
    #expect(left.placements[0].grid?.width == 6, sourceLocation: sourceContext)
    #expect(left.placements[0].grid?.height == 8, sourceLocation: sourceContext)

    let center = config.shortcuts[1]
    #expect(center.name == "Center Float", sourceLocation: sourceContext)
    #expect(center.enabled == true, sourceLocation: sourceContext)
    #expect(center.cycleDisplaysOnWrap == true, sourceLocation: sourceContext)
    #expect(center.controlCenterOnly == true, sourceLocation: sourceContext)
    #expect(center.hotkey.key == "c", sourceLocation: sourceContext)
    #expect(Set(center.hotkey.modifiers) == Set(["cmd", "ctrl"]), sourceLocation: sourceContext)
    #expect(center.placements.count == 2, sourceLocation: sourceContext)

    let big = center.placements[0]
    #expect(big.title == "Big", sourceLocation: sourceContext)
    #expect(big.mode == .freeform, sourceLocation: sourceContext)
    #expect(big.display == .main, sourceLocation: sourceContext)
    #expect(big.rect?.x == 0.1, sourceLocation: sourceContext)
    #expect(big.rect?.y == 0.15, sourceLocation: sourceContext)
    #expect(big.rect?.width == 0.8, sourceLocation: sourceContext)
    #expect(big.rect?.height == 0.7, sourceLocation: sourceContext)

    let small = center.placements[1]
    #expect(small.title == "Small", sourceLocation: sourceContext)
    #expect(small.mode == .freeform, sourceLocation: sourceContext)
    #expect(small.display == .active, sourceLocation: sourceContext)
    #expect(small.rect?.x == 0.25, sourceLocation: sourceContext)
    #expect(small.rect?.y == 0.2, sourceLocation: sourceContext)
    #expect(small.rect?.width == 0.5, sourceLocation: sourceContext)
    #expect(small.rect?.height == 0.6, sourceLocation: sourceContext)
}

// MARK: - Parity tests

@Test func yamlParityTwoSpaceFixture() throws {
    let url = Bundle.module.url(forResource: "parity_2space", withExtension: "yaml", subdirectory: "Fixtures")!
    let text = try String(contentsOf: url, encoding: .utf8)
    let config = try YAMLConfigCodec.decode(text)
    assertParityConfig(config)
}

@Test func yamlParityFourSpaceFixture() throws {
    let url = Bundle.module.url(forResource: "parity_4space", withExtension: "yaml", subdirectory: "Fixtures")!
    let text = try String(contentsOf: url, encoding: .utf8)
    let config = try YAMLConfigCodec.decode(text)
    assertParityConfig(config)
}

@Test func yamlParityTwoAndFourSpaceProduceSameConfig() throws {
    let url2 = Bundle.module.url(forResource: "parity_2space", withExtension: "yaml", subdirectory: "Fixtures")!
    let url4 = Bundle.module.url(forResource: "parity_4space", withExtension: "yaml", subdirectory: "Fixtures")!
    let config2 = try YAMLConfigCodec.decode(String(contentsOf: url2, encoding: .utf8))
    let config4 = try YAMLConfigCodec.decode(String(contentsOf: url4, encoding: .utf8))

    // Both must produce identical settings
    #expect(config2.settings.defaultGridColumns == config4.settings.defaultGridColumns)
    #expect(config2.settings.gap == config4.settings.gap)
    #expect(config2.settings.themeMode == config4.settings.themeMode)
    #expect(config2.settings.moveEverythingCloseWindowHotkey?.key == config4.settings.moveEverythingCloseWindowHotkey?.key)

    // Both must produce identical shortcuts
    #expect(config2.shortcuts.count == config4.shortcuts.count)
    for i in 0..<config2.shortcuts.count {
        #expect(config2.shortcuts[i].name == config4.shortcuts[i].name)
        #expect(config2.shortcuts[i].hotkey.key == config4.shortcuts[i].hotkey.key)
        #expect(Set(config2.shortcuts[i].hotkey.modifiers) == Set(config4.shortcuts[i].hotkey.modifiers))
        #expect(config2.shortcuts[i].placements.count == config4.shortcuts[i].placements.count)
        for j in 0..<config2.shortcuts[i].placements.count {
            let p2 = config2.shortcuts[i].placements[j]
            let p4 = config4.shortcuts[i].placements[j]
            #expect(p2.mode == p4.mode)
            #expect(p2.display == p4.display)
            #expect(p2.grid?.columns == p4.grid?.columns)
            #expect(p2.grid?.width == p4.grid?.width)
            #expect(p2.rect?.x == p4.rect?.x)
            #expect(p2.rect?.width == p4.rect?.width)
        }
    }
}

// MARK: - Encoder round-trip tests

@Test func yamlEncodeDecodeRoundTripPreservesAllSettings() throws {
    let url = Bundle.module.url(forResource: "parity_2space", withExtension: "yaml", subdirectory: "Fixtures")!
    let original = try YAMLConfigCodec.decode(String(contentsOf: url, encoding: .utf8))

    let encoded = YAMLConfigCodec.encode(original)
    let roundTripped = try YAMLConfigCodec.decode(encoded)

    // Settings
    #expect(roundTripped.settings.defaultGridColumns == original.settings.defaultGridColumns)
    #expect(roundTripped.settings.gap == original.settings.gap)
    #expect(roundTripped.settings.controlCenterScale == original.settings.controlCenterScale)
    #expect(roundTripped.settings.largerFonts == original.settings.largerFonts)
    #expect(roundTripped.settings.themeMode == original.settings.themeMode)
    #expect(roundTripped.settings.moveEverythingMoveOnSelection == original.settings.moveEverythingMoveOnSelection)
    #expect(roundTripped.settings.moveEverythingOverlayMode == original.settings.moveEverythingOverlayMode)
    #expect(roundTripped.settings.moveEverythingOverlayDuration == original.settings.moveEverythingOverlayDuration)
    #expect(roundTripped.settings.moveEverythingCloseWindowHotkey?.key == original.settings.moveEverythingCloseWindowHotkey?.key)
    #expect(roundTripped.settings.moveEverythingCloseWindowHotkey?.modifiers == original.settings.moveEverythingCloseWindowHotkey?.modifiers)
    #expect(roundTripped.settings.moveEverythingHideWindowHotkey?.key == original.settings.moveEverythingHideWindowHotkey?.key)

    // Shortcuts
    #expect(roundTripped.shortcuts.count == original.shortcuts.count)
    for i in 0..<original.shortcuts.count {
        #expect(roundTripped.shortcuts[i].name == original.shortcuts[i].name)
        #expect(roundTripped.shortcuts[i].enabled == original.shortcuts[i].enabled)
        #expect(roundTripped.shortcuts[i].cycleDisplaysOnWrap == original.shortcuts[i].cycleDisplaysOnWrap)
        #expect(roundTripped.shortcuts[i].controlCenterOnly == original.shortcuts[i].controlCenterOnly)
        #expect(roundTripped.shortcuts[i].hotkey.key == original.shortcuts[i].hotkey.key)
        #expect(roundTripped.shortcuts[i].hotkey.modifiers == original.shortcuts[i].hotkey.modifiers)
        #expect(roundTripped.shortcuts[i].placements.count == original.shortcuts[i].placements.count)
    }
}

@Test func yamlEncodeDecodePreservesFreeformPrecision() throws {
    let config = AppConfig(
        version: 1,
        settings: .default,
        shortcuts: [
            ShortcutConfig(
                id: "precision",
                name: "Precision",
                hotkey: Hotkey(key: "p", modifiers: ["cmd"]),
                placements: [
                    PlacementStep(
                        id: "step",
                        title: "",
                        mode: .freeform,
                        display: .active,
                        grid: nil,
                        rect: FreeformRect(x: 0.1234, y: 0.4321, width: 0.3, height: 0.45)
                    ),
                ]
            ),
        ]
    )

    let encoded = YAMLConfigCodec.encode(config)
    let decoded = try YAMLConfigCodec.decode(encoded)

    let rect = decoded.shortcuts[0].placements[0].rect!
    #expect(rect.x == 0.1234)
    #expect(rect.y == 0.4321)
    #expect(rect.width == 0.3)
    #expect(rect.height == 0.45)
}

@Test func yamlEncodeDecodePreservesDisplayTargets() throws {
    let config = AppConfig(
        version: 1,
        settings: .default,
        shortcuts: [
            ShortcutConfig(
                id: "multi-display",
                name: "Multi Display",
                hotkey: Hotkey(key: "m", modifiers: ["cmd"]),
                placements: [
                    PlacementStep(
                        id: "active",
                        title: "",
                        mode: .grid,
                        display: .active,
                        grid: GridPlacement(columns: 12, rows: 8, x: 0, y: 0, width: 12, height: 8),
                        rect: nil
                    ),
                    PlacementStep(
                        id: "main",
                        title: "",
                        mode: .grid,
                        display: .main,
                        grid: GridPlacement(columns: 12, rows: 8, x: 0, y: 0, width: 6, height: 8),
                        rect: nil
                    ),
                    PlacementStep(
                        id: "indexed",
                        title: "",
                        mode: .grid,
                        display: .index(2),
                        grid: GridPlacement(columns: 12, rows: 8, x: 6, y: 0, width: 6, height: 8),
                        rect: nil
                    ),
                ]
            ),
        ]
    )

    let encoded = YAMLConfigCodec.encode(config)
    let decoded = try YAMLConfigCodec.decode(encoded)

    #expect(decoded.shortcuts[0].placements[0].display == .active)
    #expect(decoded.shortcuts[0].placements[1].display == .main)
    #expect(decoded.shortcuts[0].placements[2].display == .index(2))
}
