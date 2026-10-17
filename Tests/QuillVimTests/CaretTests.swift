import XCTest
@testable import QuillVim

final class CaretTests: XCTestCase {
    func testBlockIsOneGlyphAndBeamIsThin() {
        let block = CaretGeometry.box(
            shape: .block,
            glyphAdvance: 8,
            ascender: 16,
            descender: -4,
            originX: 10,
            baselineY: 40
        )
        XCTAssertEqual(block, CaretBox(x: 10, y: 24, width: 8, height: 20))

        let wideLine = CaretGeometry.box(
            shape: .block,
            glyphAdvance: 8,
            ascender: 16,
            descender: -4,
            originX: 10,
            baselineY: 80
        )
        XCTAssertEqual(wideLine.width, 8)
        XCTAssertEqual(wideLine.height, 20)

        let heading = CaretGeometry.box(
            shape: .block,
            glyphAdvance: 18,
            ascender: 28,
            descender: -6,
            originX: 0,
            baselineY: 40
        )
        XCTAssertEqual(heading.width, 18)
        XCTAssertEqual(heading.height, 34)
        XCTAssertGreaterThan(heading.height, block.height)

        let beam = CaretGeometry.box(
            shape: .beam,
            glyphAdvance: 18,
            ascender: 28,
            descender: -6,
            originX: 4,
            baselineY: 40
        )
        XCTAssertEqual(beam.width, 1)
        XCTAssertEqual(beam.height, heading.height)
        XCTAssertEqual(beam.y, heading.y)
    }
}
