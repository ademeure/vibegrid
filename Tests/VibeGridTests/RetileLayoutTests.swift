import Foundation
import Testing
@testable import VibeGrid

private struct RetileLayoutFixtures: Decodable {
    let availableFrameCases: [AvailableFrameCase]
    let gridCases: [GridCase]
    let sliceCases: [SliceCase]
    let trailingSliceCases: [SliceCase]
}

private struct AvailableFrameCase: Decodable {
    let name: String
    let available: FixtureRect
    let occupied: FixtureRect
    let expected: FixtureRect
}

private struct GridCase: Decodable {
    let name: String
    let count: Int
    let gap: Double
    let aspectRatio: Double
    let available: FixtureRect
    let expectedRows: Int
    let expectedColumns: Int
    let expectedFrames: [FixtureRect]
}

private struct SliceCase: Decodable {
    let name: String
    let available: FixtureRect
    let widthFraction: Double
    let expected: FixtureRect
}

private struct FixtureRect: Decodable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double

    var cgRect: CGRect {
        CGRect(x: x, y: y, width: width, height: height)
    }
}

private func loadRetileFixtures(sourceContext: SourceLocation = #_sourceLocation) throws -> RetileLayoutFixtures {
    let url = try #require(
        Bundle.module.url(forResource: "retile_layout_cases", withExtension: "json", subdirectory: "Fixtures"),
        sourceLocation: sourceContext
    )
    let data = try Data(contentsOf: url)
    return try JSONDecoder().decode(RetileLayoutFixtures.self, from: data)
}

private func expectEqual(_ actual: CGRect, _ expected: CGRect, sourceContext: SourceLocation = #_sourceLocation) {
    #expect(actual.origin.x == expected.origin.x, sourceLocation: sourceContext)
    #expect(actual.origin.y == expected.origin.y, sourceLocation: sourceContext)
    #expect(actual.width == expected.width, sourceLocation: sourceContext)
    #expect(actual.height == expected.height, sourceLocation: sourceContext)
}

@Test func retileAvailableFrameCasesMatchFixtures() throws {
    let fixtures = try loadRetileFixtures()
    for testCase in fixtures.availableFrameCases {
        let actual = MoveEverythingRetileLayout.availableFrame(
            within: testCase.available.cgRect,
            excluding: testCase.occupied.cgRect
        )
        expectEqual(actual, testCase.expected.cgRect)
    }
}

@Test func retileGridCaseMatchesFixture() throws {
    let fixtures = try loadRetileFixtures()
    let testCase = try #require(fixtures.gridCases.first)
        let candidate = try #require(
        MoveEverythingRetileLayout.bestGrid(
            count: testCase.count,
            availableFrame: testCase.available.cgRect,
            aspectRatio: CGFloat(testCase.aspectRatio),
            gap: CGFloat(testCase.gap)
        )
    )
    #expect(candidate.rows == testCase.expectedRows)
    #expect(candidate.columns == testCase.expectedColumns)

    let frames = MoveEverythingRetileLayout.tiledFrames(
        count: testCase.count,
        availableFrame: testCase.available.cgRect,
        aspectRatio: CGFloat(testCase.aspectRatio),
        gap: CGFloat(testCase.gap)
    )
    #expect(frames.count == testCase.expectedFrames.count)
    for (actual, expected) in zip(frames, testCase.expectedFrames.map(\.cgRect)) {
        expectEqual(actual, expected)
    }
}

@Test func retileLeadingSliceMatchesFixture() throws {
    let fixtures = try loadRetileFixtures()
    let testCase = try #require(fixtures.sliceCases.first)
    let actual = MoveEverythingRetileLayout.leadingHorizontalSlice(
        of: testCase.available.cgRect,
        widthFraction: CGFloat(testCase.widthFraction)
    )
    expectEqual(actual, testCase.expected.cgRect)
}

@Test func retileTrailingSliceMatchesFixture() throws {
    let fixtures = try loadRetileFixtures()
    let testCase = try #require(fixtures.trailingSliceCases.first)
    let actual = MoveEverythingRetileLayout.trailingHorizontalSlice(
        of: testCase.available.cgRect,
        widthFraction: CGFloat(testCase.widthFraction)
    )
    expectEqual(actual, testCase.expected.cgRect)
}
