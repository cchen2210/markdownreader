import XCTest
@testable import MarkdownReader

final class MemoryLayoutPolicyTests: XCTestCase {
    func testFullGutterBeginsOnlyWhenMeasureInsetsAndThreeHundredPointsFit() {
        let result = MemoryLayoutPolicy.resolve(
            availableWidth: 900,
            chosenTextMeasure: 552,
            documentInsets: 48
        )

        XCTAssertEqual(result.mode, .fullGutter(width: 300))
        XCTAssertEqual(result.documentViewportWidth, 600)
        XCTAssertEqual(result.availableTextWidth, 552)
    }

    func testRailUsesRemainderWithoutNarrowingChosenMeasure() {
        let result = MemoryLayoutPolicy.resolve(
            availableWidth: 820,
            chosenTextMeasure: 552,
            documentInsets: 48
        )

        XCTAssertEqual(result.mode, .rail(width: 220))
        XCTAssertEqual(result.availableTextWidth, 552)
    }

    func testRailClampsAtMaximumWidth() {
        let result = MemoryLayoutPolicy.resolve(
            availableWidth: 880,
            chosenTextMeasure: 552,
            documentInsets: 48
        )

        XCTAssertEqual(result.mode, .rail(width: 240))
        XCTAssertGreaterThanOrEqual(result.availableTextWidth, 552)
    }

    func testRemainderBelowRailMinimumUsesOverlayInspector() {
        let result = MemoryLayoutPolicy.resolve(
            availableWidth: 759,
            chosenTextMeasure: 552,
            documentInsets: 48
        )

        XCTAssertEqual(result.mode, .overlayInspector(width: 288))
        XCTAssertEqual(result.documentViewportWidth, 759)
        XCTAssertEqual(result.availableTextWidth, 711)
    }

    func testRailStartsAtExactMinimumWithoutNarrowingText() {
        let result = MemoryLayoutPolicy.resolve(
            availableWidth: 760,
            chosenTextMeasure: 552,
            documentInsets: 48
        )

        XCTAssertEqual(result.mode, .rail(width: 160))
        XCTAssertEqual(result.availableTextWidth, 552)
    }

    func testWindowNarrowerThanChosenMeasureStillUsesNonShrinkingOverlay() {
        let result = MemoryLayoutPolicy.resolve(
            availableWidth: 500,
            chosenTextMeasure: 620
        )

        XCTAssertEqual(result.mode, .overlayInspector(width: 288))
        XCTAssertEqual(result.documentViewportWidth, 500)
    }

    func testHiddenSurfaceReturnsAllWidthToDocument() {
        let result = MemoryLayoutPolicy.resolve(
            availableWidth: 1_100,
            chosenTextMeasure: 620,
            showsMemorySurface: false
        )

        XCTAssertEqual(result.mode, .hidden)
        XCTAssertEqual(result.documentViewportWidth, 1_100)
        XCTAssertEqual(result.availableTextWidth, 1_052)
    }

    func testInvalidDimensionsAreClampedRatherThanProducingInvalidFrames() {
        let result = MemoryLayoutPolicy.resolve(
            availableWidth: .infinity,
            chosenTextMeasure: -20,
            documentInsets: .nan
        )

        XCTAssertEqual(result.mode, .overlayInspector(width: 288))
        XCTAssertEqual(result.documentViewportWidth, 0)
        XCTAssertEqual(result.availableTextWidth, 0)
    }
}
