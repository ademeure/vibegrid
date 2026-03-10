import Foundation
import Testing
@testable import VibeGrid

// MARK: - Grid placement normalization

@Test func gridNormalizedRectFullScreen() {
    let placement = PlacementStep(
        id: "full",
        title: "",
        mode: .grid,
        display: .active,
        grid: GridPlacement(columns: 12, rows: 8, x: 0, y: 0, width: 12, height: 8),
        rect: nil
    )
    let rect = placement.normalizedRect(defaultColumns: 12, defaultRows: 8)
    #expect(rect != nil)
    #expect(rect!.origin.x == 0)
    #expect(rect!.origin.y == 0)
    #expect(rect!.width == 1.0)
    #expect(rect!.height == 1.0)
}

@Test func gridNormalizedRectLeftHalf() {
    let placement = PlacementStep(
        id: "left",
        title: "",
        mode: .grid,
        display: .active,
        grid: GridPlacement(columns: 12, rows: 8, x: 0, y: 0, width: 6, height: 8),
        rect: nil
    )
    let rect = placement.normalizedRect(defaultColumns: 12, defaultRows: 8)
    #expect(rect != nil)
    #expect(rect!.origin.x == 0)
    #expect(rect!.width == 0.5)
    #expect(rect!.height == 1.0)
}

@Test func gridNormalizedRectRightHalf() {
    let placement = PlacementStep(
        id: "right",
        title: "",
        mode: .grid,
        display: .active,
        grid: GridPlacement(columns: 12, rows: 8, x: 6, y: 0, width: 6, height: 8),
        rect: nil
    )
    let rect = placement.normalizedRect(defaultColumns: 12, defaultRows: 8)
    #expect(rect != nil)
    #expect(rect!.origin.x == 0.5)
    #expect(rect!.width == 0.5)
}

@Test func gridNormalizedRectTopLeftQuarter() {
    let placement = PlacementStep(
        id: "tl",
        title: "",
        mode: .grid,
        display: .active,
        grid: GridPlacement(columns: 2, rows: 2, x: 0, y: 0, width: 1, height: 1),
        rect: nil
    )
    let rect = placement.normalizedRect(defaultColumns: 12, defaultRows: 8)
    #expect(rect != nil)
    #expect(rect!.origin.x == 0)
    #expect(rect!.origin.y == 0)
    #expect(rect!.width == 0.5)
    #expect(rect!.height == 0.5)
}

@Test func gridNormalizedRectBottomRightQuarter() {
    let placement = PlacementStep(
        id: "br",
        title: "",
        mode: .grid,
        display: .active,
        grid: GridPlacement(columns: 2, rows: 2, x: 1, y: 1, width: 1, height: 1),
        rect: nil
    )
    let rect = placement.normalizedRect(defaultColumns: 12, defaultRows: 8)
    #expect(rect != nil)
    #expect(rect!.origin.x == 0.5)
    #expect(rect!.origin.y == 0.5)
    #expect(rect!.width == 0.5)
    #expect(rect!.height == 0.5)
}

@Test func gridNormalizedRectThirds() {
    let placement = PlacementStep(
        id: "center-third",
        title: "",
        mode: .grid,
        display: .active,
        grid: GridPlacement(columns: 3, rows: 1, x: 1, y: 0, width: 1, height: 1),
        rect: nil
    )
    let rect = placement.normalizedRect(defaultColumns: 12, defaultRows: 8)
    #expect(rect != nil)
    let expectedX = 1.0 / 3.0
    let expectedW = 1.0 / 3.0
    #expect(abs(rect!.origin.x - expectedX) < 0.0001)
    #expect(abs(rect!.width - expectedW) < 0.0001)
}

@Test func gridNormalizedRectUsesDefaultsWhenGridIsNil() {
    let placement = PlacementStep(
        id: "no-grid",
        title: "",
        mode: .grid,
        display: .active,
        grid: nil,
        rect: nil
    )
    let rect = placement.normalizedRect(defaultColumns: 12, defaultRows: 8)
    #expect(rect != nil)
    #expect(rect!.origin.x == 0)
    #expect(rect!.origin.y == 0)
    #expect(rect!.width == 1.0)
    #expect(rect!.height == 1.0)
}

@Test func gridNormalizedRectReturnsNilForZeroColumns() {
    let placement = PlacementStep(
        id: "zero",
        title: "",
        mode: .grid,
        display: .active,
        grid: GridPlacement(columns: 0, rows: 8, x: 0, y: 0, width: 0, height: 8),
        rect: nil
    )
    let rect = placement.normalizedRect(defaultColumns: 12, defaultRows: 8)
    #expect(rect == nil)
}

@Test func gridNormalizedRectReturnsNilForZeroRows() {
    let placement = PlacementStep(
        id: "zero-rows",
        title: "",
        mode: .grid,
        display: .active,
        grid: GridPlacement(columns: 12, rows: 0, x: 0, y: 0, width: 12, height: 0),
        rect: nil
    )
    let rect = placement.normalizedRect(defaultColumns: 12, defaultRows: 8)
    #expect(rect == nil)
}

// MARK: - Freeform placement normalization

@Test func freeformNormalizedRectPassesThrough() {
    let placement = PlacementStep(
        id: "free",
        title: "",
        mode: .freeform,
        display: .active,
        grid: nil,
        rect: FreeformRect(x: 0.1, y: 0.2, width: 0.8, height: 0.6)
    )
    let rect = placement.normalizedRect(defaultColumns: 12, defaultRows: 8)
    #expect(rect != nil)
    #expect(rect!.origin.x == 0.1)
    #expect(rect!.origin.y == 0.2)
    #expect(rect!.width == 0.8)
    #expect(rect!.height == 0.6)
}

@Test func freeformNormalizedRectReturnsNilWhenRectIsNil() {
    let placement = PlacementStep(
        id: "no-rect",
        title: "",
        mode: .freeform,
        display: .active,
        grid: nil,
        rect: nil
    )
    let rect = placement.normalizedRect(defaultColumns: 12, defaultRows: 8)
    #expect(rect == nil)
}

// MARK: - Config normalization edge cases

@Test func normalizedClampsGridBoundsOverflow() {
    let config = AppConfig(
        version: 1,
        settings: .default,
        shortcuts: [
            ShortcutConfig(
                id: "overflow",
                name: "Overflow",
                hotkey: Hotkey(key: "x", modifiers: ["cmd"]),
                placements: [
                    PlacementStep(
                        id: "step",
                        title: "",
                        mode: .grid,
                        display: .active,
                        grid: GridPlacement(columns: 4, rows: 4, x: 3, y: 3, width: 4, height: 4),
                        rect: nil
                    ),
                ]
            ),
        ]
    )
    let normalized = config.normalized()
    let grid = normalized.shortcuts[0].placements[0].grid!
    #expect(grid.x + grid.width <= grid.columns)
    #expect(grid.y + grid.height <= grid.rows)
    #expect(grid.width >= 1)
    #expect(grid.height >= 1)
}

@Test func normalizedClampsFreeformBoundsOverflow() {
    let config = AppConfig(
        version: 1,
        settings: .default,
        shortcuts: [
            ShortcutConfig(
                id: "overflow",
                name: "Overflow",
                hotkey: Hotkey(key: "x", modifiers: ["cmd"]),
                placements: [
                    PlacementStep(
                        id: "step",
                        title: "",
                        mode: .freeform,
                        display: .active,
                        grid: nil,
                        rect: FreeformRect(x: 0.8, y: 0.9, width: 0.5, height: 0.3)
                    ),
                ]
            ),
        ]
    )
    let normalized = config.normalized()
    let rect = normalized.shortcuts[0].placements[0].rect!
    #expect(rect.x + rect.width <= 1.0)
    #expect(rect.y + rect.height <= 1.0)
    #expect(rect.width >= 0.05)
    #expect(rect.height >= 0.05)
}

@Test func normalizedRemovesGridFromFreeformPlacements() {
    let config = AppConfig(
        version: 1,
        settings: .default,
        shortcuts: [
            ShortcutConfig(
                id: "mixed",
                name: "Mixed",
                hotkey: Hotkey(key: "x", modifiers: ["cmd"]),
                placements: [
                    PlacementStep(
                        id: "step",
                        title: "",
                        mode: .freeform,
                        display: .active,
                        grid: GridPlacement(columns: 12, rows: 8, x: 0, y: 0, width: 6, height: 8),
                        rect: FreeformRect(x: 0.1, y: 0.1, width: 0.5, height: 0.5)
                    ),
                ]
            ),
        ]
    )
    let normalized = config.normalized()
    #expect(normalized.shortcuts[0].placements[0].grid == nil)
    #expect(normalized.shortcuts[0].placements[0].rect != nil)
}

@Test func normalizedRemovesRectFromGridPlacements() {
    let config = AppConfig(
        version: 1,
        settings: .default,
        shortcuts: [
            ShortcutConfig(
                id: "mixed",
                name: "Mixed",
                hotkey: Hotkey(key: "x", modifiers: ["cmd"]),
                placements: [
                    PlacementStep(
                        id: "step",
                        title: "",
                        mode: .grid,
                        display: .active,
                        grid: GridPlacement(columns: 12, rows: 8, x: 0, y: 0, width: 6, height: 8),
                        rect: FreeformRect(x: 0.1, y: 0.1, width: 0.5, height: 0.5)
                    ),
                ]
            ),
        ]
    )
    let normalized = config.normalized()
    #expect(normalized.shortcuts[0].placements[0].grid != nil)
    #expect(normalized.shortcuts[0].placements[0].rect == nil)
}
