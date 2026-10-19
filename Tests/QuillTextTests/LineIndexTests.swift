import QuillText
import XCTest

/// Deterministic so a failure reproduces from the seed in its message.
struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

final class LineIndexTests: XCTestCase {
    func testLinesOfAMixedDocument() {
        let index = LineIndex("ab\n\ncafé 😀\nlast")
        XCTAssertEqual(index.starts, [0, 3, 4, 12])
        XCTAssertEqual(index.lineCount, 4)
        XCTAssertEqual(index.line(0), BufferLine(index: 0, start: 0, contentEnd: 2, end: 3))
        XCTAssertTrue(index.line(1).isEmpty)
        XCTAssertEqual(index.line(2).content, 4..<11)
        XCTAssertEqual(index.line(3), BufferLine(index: 3, start: 12, contentEnd: 16, end: 16))
        XCTAssertFalse(index.line(3).hasNewline)
        XCTAssertEqual(index.line(containing: 2), 0)
        XCTAssertEqual(index.line(containing: 3), 1)
        XCTAssertEqual(index.line(containing: 16), 3)
        XCTAssertEqual(index.line(containing: 999), 3)
    }

    func testTrailingNewlineEndsWithAnEmptyLine() {
        let index = LineIndex("a\n")
        XCTAssertEqual(index.lineCount, 2)
        XCTAssertEqual(index.line(1), BufferLine(index: 1, start: 2, contentEnd: 2, end: 2))
        XCTAssertEqual(index.line(containing: 2), 1)
    }

    func testLSPPositionsAreUTF16() {
        let index = LineIndex("a😀b\ncafé")
        XCTAssertEqual(index.position(of: 3), TextPosition(line: 0, utf16Column: 3))
        XCTAssertEqual(index.position(of: 5), TextPosition(line: 1, utf16Column: 0))
        XCTAssertEqual(index.offset(of: TextPosition(line: 0, utf16Column: 3)), 3)
        XCTAssertEqual(index.offset(of: TextPosition(line: 0, utf16Column: 40)), 4, "clamps to the line, not into the next")
        XCTAssertEqual(index.offset(of: TextPosition(line: 9, utf16Column: 0)), 9)
        XCTAssertEqual(index.offset(of: TextPosition(line: -1, utf16Column: 4)), 0)
    }

    func testEveryOffsetRoundTripsThroughAPosition() {
        let text = "x\n\n😀😀\n\tcafé\r\nend"
        let index = LineIndex(text)
        for offset in 0...text.utf16.count {
            XCTAssertEqual(index.offset(of: index.position(of: offset)), offset, "offset \(offset)")
        }
    }

    func testIncrementalEditsMatchARebuild() {
        let pieces = ["a", "bc", "\n", "\n\n", "😀", "é", "\t", "  ", "x\ny", ""]
        for seed in UInt64(1)...40 {
            var rng = SplitMix64(seed: seed)
            var text = ""
            var index = LineIndex()
            for step in 0..<120 {
                let units = Array(text.utf16)
                let lower = units.isEmpty ? 0 : Int.random(in: 0...units.count, using: &rng)
                let upper = min(units.count, lower + Int.random(in: 0...4, using: &rng))
                let insert = pieces.randomElement(using: &rng)!
                var next = units
                next.replaceSubrange(lower..<upper, with: Array(insert.utf16))
                // Edits that split a surrogate pair are fine for the index: it only counts units.
                text = String(decoding: next, as: UTF16.self)
                index.replace(lower..<upper, withUTF16: insert.utf16)
                let rebuilt = LineIndex(utf16: next)
                XCTAssertEqual(index, rebuilt, "seed \(seed) step \(step) replace \(lower)..<\(upper) with \(insert.debugDescription)")
                if index != rebuilt { return }
            }
        }
    }
}

final class DisplayWidthTests: XCTestCase {
    func testCellsPerGrapheme() {
        XCTAssertEqual(DisplayWidth.cells("a"), 1)
        XCTAssertEqual(DisplayWidth.cells("é"), 1)
        XCTAssertEqual(DisplayWidth.cells("e\u{301}"), 1, "combining mark stays in its base's cell")
        XCTAssertEqual(DisplayWidth.cells("日"), 2)
        XCTAssertEqual(DisplayWidth.cells("한"), 2)
        XCTAssertEqual(DisplayWidth.cells("Ａ"), 2, "fullwidth form")
        XCTAssertEqual(DisplayWidth.cells("😀"), 2)
        XCTAssertEqual(DisplayWidth.cells("👍🏽"), 2)
        XCTAssertEqual(DisplayWidth.cells("👩‍💻"), 2)
        XCTAssertEqual(DisplayWidth.cells("❤️"), 2)
        XCTAssertEqual(DisplayWidth.cells("|"), 1)
    }

    func testTabsAdvanceToTheNextStop() {
        XCTAssertEqual(DisplayWidth.advance(0, over: "\t", tabWidth: 4), 4)
        XCTAssertEqual(DisplayWidth.advance(3, over: "\t", tabWidth: 4), 4)
        XCTAssertEqual(DisplayWidth.advance(4, over: "\t", tabWidth: 4), 8)
        XCTAssertEqual(DisplayWidth.columns(of: "ab\tc", tabWidth: 4), 5)
        XCTAssertEqual(DisplayWidth.columns(of: "日本\t", tabWidth: 4), 8)
    }
}
