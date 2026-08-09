import XCTest
@testable import MarkdownReader

final class MemoryNotePackingTests: XCTestCase {
    func testTenNotesAtOneAnchorPackWithoutOverlap() {
        let inputs = (0..<10).map { _ in
            MemoryNoteLayoutInput(id: UUID(), desiredTop: 120, height: 84)
        }

        let result = MemoryNotePacking.pack(inputs)

        XCTAssertEqual(result.count, 10)
        XCTAssertEqual(result.first?.top, 120)
        for pair in zip(result, result.dropFirst()) {
            XCTAssertGreaterThanOrEqual(pair.1.top, pair.0.bottom + 12)
        }
        XCTAssertGreaterThan(result.last?.leaderDrop ?? 0, 0)
    }

    func testPackingPreservesDesiredPositionWhenThereIsRoom() {
        let first = MemoryNoteLayoutInput(id: UUID(), desiredTop: 20, height: 40)
        let second = MemoryNoteLayoutInput(id: UUID(), desiredTop: 100, height: 40)

        XCTAssertEqual(
            MemoryNotePacking.pack([second, first]).map(\.top),
            [20, 100]
        )
    }

    func testMeasuredDenseStackExtendsDocumentUntilLastNoteIsReachable() throws {
        let measuredHeights: [CGFloat] = [72, 91, 64, 118, 83, 76, 105, 69, 97, 88, 112, 74]
        let inputs = measuredHeights.map {
            MemoryNoteLayoutInput(id: UUID(), desiredTop: 140, height: $0)
        }
        let layouts = MemoryNotePacking.pack(inputs)
        let last = try XCTUnwrap(layouts.last)
        let baseDocumentHeight: CGFloat = 760
        let viewportHeight: CGFloat = 420
        let inset = MemoryNotePacking.requiredBottomInset(
            contentBottom: last.bottom,
            baseDocumentHeight: baseDocumentHeight
        )
        let extendedDocumentHeight = baseDocumentHeight + inset
        let maximumScrollOffset = extendedDocumentHeight - viewportHeight
        let lastTopInViewport = last.top - maximumScrollOffset
        let lastBottomInViewport = last.bottom - maximumScrollOffset

        XCTAssertEqual(layouts.map(\.height), measuredHeights)
        XCTAssertGreaterThan(inset, 0)
        XCTAssertGreaterThanOrEqual(lastTopInViewport, 0)
        XCTAssertLessThanOrEqual(
            lastBottomInViewport,
            viewportHeight - MemoryNotePacking.scrollReachabilityPadding
        )
    }

    func testBottomInsetDoesNotCompoundAnExistingInset() {
        let baseDocumentHeight: CGFloat = 900
        let contentBottom: CGFloat = 1_180
        let first = MemoryNotePacking.requiredBottomInset(
            contentBottom: contentBottom,
            baseDocumentHeight: baseDocumentHeight
        )
        let refreshedBase = baseDocumentHeight + first - first

        XCTAssertEqual(first, 304)
        XCTAssertEqual(
            MemoryNotePacking.requiredBottomInset(
                contentBottom: contentBottom,
                baseDocumentHeight: refreshedBase
            ),
            first
        )
        XCTAssertEqual(
            MemoryNotePacking.requiredBottomInset(
                contentBottom: 700,
                baseDocumentHeight: baseDocumentHeight
            ),
            0
        )
    }

    func testWebGeometryConvertsCSSPixelsAtReaderZoom() {
        let geometry = WebDocumentGeometry(
            scrollY: 120,
            documentHeight: 1_200,
            baseDocumentHeight: 1_100,
            viewportWidth: 600,
            viewportHeight: 400,
            bottomInset: 100
        )

        let scale = geometry.nativeScale(forViewportHeight: 600)

        XCTAssertEqual(scale, 1.5)
        XCTAssertEqual(CGFloat(geometry.scrollY) * scale, 180)
        XCTAssertEqual(CGFloat(geometry.baseDocumentHeight) * scale, 1_650)
        XCTAssertEqual(CGFloat(150) / scale, 100)
    }

    func testWebGeometryScaleFailsClosedForMissingViewport() {
        XCTAssertEqual(WebDocumentGeometry.empty.nativeScale(forViewportHeight: 700), 1)
    }
}
