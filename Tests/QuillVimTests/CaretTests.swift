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
            baselineY: 40,
            beamPointWidth: CaretGeometry.beamPointWidth(backingScale: 2)
        )
        XCTAssertEqual(beam.width, 1, "2 device pixels at 2x")
        XCTAssertEqual(CaretGeometry.beamPointWidth(backingScale: 1), 2)
        XCTAssertEqual(beam.height, heading.height)
        XCTAssertEqual(beam.y, heading.y)
    }

    func testExtraLineBaselineIsNotTheFragmentTop() {
        let ascender = 19.3359375
        let descender = -4.3359375
        let previousBottom = 138.6
        let baseline = CaretGeometry.extraLineBaseline(
            previousLineMaxY: previousBottom,
            ascender: ascender,
            descender: descender,
            leading: 0,
            lineHeightMultiple: 1.65
        )
        let caretTop = baseline - ascender
        let lineHeight = CaretGeometry.lineFragmentHeight(
            ascender: ascender,
            descender: descender,
            leading: 0,
            lineHeightMultiple: 1.65
        )
        XCTAssertEqual(caretTop, previousBottom + lineHeight - (ascender - descender), accuracy: 0.001)
        // The broken extra-line fragment reports a caret whose top is the previous line's bottom.
        XCTAssertGreaterThan(caretTop - previousBottom, 2.5)
        XCTAssertEqual(
            CaretGeometry.lineFragmentHeight(
                ascender: 30.9375,
                descender: -6.9375,
                leading: 0,
                lineHeightMultiple: 1.65
            ),
            62.7,
            accuracy: 0.001
        )
    }

    func testLineFragmentDoesNotFitTheEmBox() {
        let em = 20.0
        let glyph = CaretBox(x: 0, y: 30, width: 240, height: em)
        let cell = CaretGeometry.box(
            shape: .block,
            glyphAdvance: 8,
            ascender: 16,
            descender: -4,
            originX: 12,
            baselineY: 46
        )
        XCTAssertTrue(CaretGeometry.heightFitsEm(caretHeight: cell.height, emHeight: em))
        XCTAssertTrue(CaretGeometry.sitsInGlyphBounds(caret: cell, glyph: glyph))

        let fragment = CaretBox(x: 12, y: 8, width: 8, height: em * 1.65)
        XCTAssertFalse(CaretGeometry.heightFitsEm(caretHeight: fragment.height, emHeight: em))
        XCTAssertFalse(CaretGeometry.sitsInGlyphBounds(caret: fragment, glyph: glyph))
    }

    func testSegmentBaselineReadsBothTextKitConventions() {
        // First line: an offset and an absolute y are the same number.
        XCTAssertEqual(
            CaretGeometry.resolvedBaseline(segmentMinY: 0, segmentHeight: 24, baselinePosition: 19),
            Optional(19.0)
        )
        // Later line, baseline passed as an offset from the segment top.
        XCTAssertEqual(
            CaretGeometry.resolvedBaseline(segmentMinY: 80, segmentHeight: 24, baselinePosition: 19),
            Optional(99.0)
        )
        // Later line, baseline passed as a container y.
        XCTAssertEqual(
            CaretGeometry.resolvedBaseline(segmentMinY: 80, segmentHeight: 24, baselinePosition: 99),
            Optional(99.0)
        )
    }

    func testDefaultThemesStayLegibleWithoutRedrawingTheGlyph() {
        let lightText = CaretRGB(r: 0.22, g: 0.22, b: 0.22)
        let lightBackground = CaretRGB(r: 0.965, g: 0.965, b: 0.965)
        let darkText = CaretRGB(r: 0.86, g: 0.86, b: 0.86)
        let darkBackground = CaretRGB(r: 0.11, g: 0.11, b: 0.11)
        let alpha = CaretGeometry.blockFillAlpha
        XCTAssertFalse(CaretContrast.needsRedraw(
            text: lightText,
            accent: CaretGeometry.lightAccent,
            background: lightBackground,
            fillAlpha: alpha
        ))
        XCTAssertFalse(CaretContrast.needsRedraw(
            text: darkText,
            accent: CaretGeometry.darkAccent,
            background: darkBackground,
            fillAlpha: alpha
        ))
        XCTAssertGreaterThan(
            CaretContrast.contrast(
                lightText,
                CaretContrast.blend(lightBackground, CaretGeometry.lightAccent, alpha)
            ),
            4.5
        )
        let washed = CaretRGB(r: 0.95, g: 0.95, b: 0.95)
        let pale = CaretRGB(r: 0.90, g: 0.90, b: 0.92)
        XCTAssertTrue(CaretContrast.needsRedraw(
            text: washed,
            accent: pale,
            background: CaretRGB(r: 0.96, g: 0.96, b: 0.96),
            fillAlpha: 0.15
        ))
        let ink = CaretContrast.glyphColor(accent: pale, background: washed)
        XCTAssertLessThan(ink.r, 0.3)
    }
}
