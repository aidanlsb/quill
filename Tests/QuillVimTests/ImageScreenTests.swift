import QuillText
import XCTest
@testable import QuillVim

/// One text row per buffer line, plus a chosen number of image rows.
final class ImageGapLayout: ScreenLayout {
    var gaps: [Int: Int] = [:]
    var wrap = 0

    func rowRanges(of line: BufferLine, in buffer: TextBuffer) -> [Range<Int>]? {
        if wrap > 0, line.index == 0 {
            return WrapLayout(width: wrap).rowRanges(of: line, in: buffer)
        }
        return [line.content]
    }

    func gapRows(after line: BufferLine, in buffer: TextBuffer) -> Int {
        gaps[line.index] ?? 0
    }
}

final class ImageScreenTests: XCTestCase {
    func testGapRowsAreScreenSpaceAndNotACaretStop() {
        let rows = ImageScreenRows.appending(textRows: [0..<4, 4..<9], gapRows: 3, contentEnd: 9)
        XCTAssertEqual(rows.map(\.isGap), [false, false, true, true, true])
        XCTAssertEqual(rows[2].range, 9..<9)
        XCTAssertEqual(ImageScreenRows.landable(in: rows, from: 0, delta: 1), 1)
        XCTAssertNil(ImageScreenRows.landable(in: rows, from: 1, delta: 1), "j on the last text row steps over the image")
        XCTAssertEqual(ImageScreenRows.landable(in: rows, from: 1, delta: -1), 0)
        XCTAssertNil(ImageScreenRows.landable(in: rows, from: 0, delta: -1))
    }

    func testJAndKStepOverImageRows() {
        let text = "abcdefgh\n![a](pic.png)\nafter"
        let layout = ImageGapLayout()
        layout.wrap = 4
        layout.gaps = [0: 2, 1: 5]
        let engine = Engine(text: text, layout: layout)
        let model = engine.screen
        XCTAssertEqual(model.screenLines(of: 0).map(\.isGap), [false, false, true, true])
        XCTAssertEqual(model.screenLines(of: 0).map(\.isLastRow), [false, true, false, false])
        XCTAssertEqual(model.screenLines(of: 1).filter(\.isGap).count, 5)
        XCTAssertFalse(model.screenLine(containing: engine.buffer.line(1).contentEnd).isGap)

        engine.moveCursor(to: 0)
        engine.type("j")
        XCTAssertEqual(engine.cursor, 4, "the first j stays on the wrapped text")
        engine.type("j")
        XCTAssertEqual(engine.buffer.lineIndex(containing: engine.cursor), 1, "the next j crosses the preview")
        engine.type("j")
        XCTAssertEqual(engine.buffer.lineIndex(containing: engine.cursor), 2, "one j crosses every image row")
        engine.type("k")
        XCTAssertEqual(engine.buffer.lineIndex(containing: engine.cursor), 1)
        engine.type("k")
        XCTAssertEqual(engine.cursor, 4)
        XCTAssertEqual(engine.text, text)
    }

    func testALineWithoutAnImageHasNoGap() {
        let rows = ImageScreenRows.appending(textRows: [0..<3], gapRows: 0, contentEnd: 3)
        XCTAssertEqual(rows.count, 1)
        XCTAssertFalse(rows[0].isGap)
        XCTAssertNil(ImageScreenRows.landable(in: rows, from: 0, delta: 1))
    }
}
