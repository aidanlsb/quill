import QuillText
import XCTest
@testable import QuillVim

/// Rows given per buffer line, the way TextKit reports them for a heading at a
/// larger font or a monospaced table. Lines without an entry wrap at `fallback`.
final class PerLineWrapLayout: ScreenLayout {
    var widths: [Int: Int]
    var fallback: Int

    init(widths: [Int: Int], fallback: Int) {
        self.widths = widths
        self.fallback = fallback
    }

    func rowRanges(of line: BufferLine, in buffer: TextBuffer) -> [Range<Int>]? {
        WrapLayout(width: widths[line.index] ?? fallback).rowRanges(of: line, in: buffer)
    }
}

/// Returns whatever ranges it was given, to feed the model malformed answers.
final class FixedRowsLayout: ScreenLayout {
    var rows: [Range<Int>]?
    init(_ rows: [Range<Int>]?) { self.rows = rows }
    func rowRanges(of line: BufferLine, in buffer: TextBuffer) -> [Range<Int>]? { rows }
}

private struct Rng: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

private let pieces = [
    "a", "b", "word", " ", "  ", "\t", "\n", "\n\n", "😀", "👩‍💻", "日本", "é", "e\u{301}",
    "**", "`", "| a | bb |", "# ", "[[link]]", "-", "Ａ",
]

private func randomText(_ rng: inout Rng, pieces count: Int) -> String {
    var text = ""
    for _ in 0..<count {
        text += pieces.randomElement(using: &rng)!
    }
    return text
}

private func graphemeStarts(_ buffer: TextBuffer, line: Int) -> [Int] {
    buffer.graphemes(in: buffer.line(line).content).map(\.span.lowerBound)
}

final class ScreenModelTests: XCTestCase {
    func testRowsOfAWrappedLine() {
        let buffer = TextBuffer(text: "abcdefghij\n\nxy")
        let model = ScreenModel(buffer: buffer, layout: WrapLayout(width: 4))
        XCTAssertEqual(model.screenLines(of: 0).map(\.range), [0..<4, 4..<8, 8..<10])
        XCTAssertEqual(model.screenLines(of: 0).map(\.isLastRow), [false, false, true])
        XCTAssertEqual(model.screenLines(of: 1).map(\.range), [11..<11])
        XCTAssertEqual(model.screenLine(containing: 4).row, 1, "a wrap boundary belongs to the row it starts")
        XCTAssertEqual(model.screenLine(containing: 10).row, 2, "the end of the content is on the last row")
        XCTAssertEqual(model.displayColumn(of: 6), 2)
        XCTAssertEqual(model.displayColumn(of: 10), 2)
    }

    func testWideGraphemesWrapWhole() {
        let buffer = TextBuffer(text: "ab😀cd日")
        let model = ScreenModel(buffer: buffer, layout: WrapLayout(width: 3))
        // ab | 😀c | d日
        XCTAssertEqual(model.screenLines(of: 0).map(\.range), [0..<2, 2..<5, 5..<7])
        XCTAssertEqual(model.displayColumn(of: 4), 2)
        XCTAssertEqual(model.offset(on: model.screenLines(of: 0)[1], want: .column(1)), 2, "column 1 is the second cell of 😀")
    }

    func testTabStopsCountFromTheBufferLine() {
        let buffer = TextBuffer(text: "abcde\tx")
        let model = ScreenModel(buffer: buffer, layout: WrapLayout(width: 5))
        // abcde | <tab>x : the tab runs from buffer column 5 to 8, so it is 3 cells, not 4.
        let rows = model.screenLines(of: 0)
        XCTAssertEqual(rows.map(\.range), [0..<5, 5..<7])
        XCTAssertEqual(model.cells(of: rows[1]).map(\.start), [0, 3])
    }

    func testHeadingRowsHoldFewerCellsButKeepTheColumn() {
        // A heading at a larger font fits 6 cells per row where body text fits 12.
        let text = "# Heading here\nbody text that wraps"
        let layout = PerLineWrapLayout(widths: [0: 6], fallback: 12)
        let e = Engine(text: text, layout: layout)
        let bodyStart = 15
        e.moveCursor(to: bodyStart + 8)
        e.type("k")
        XCTAssertEqual(e.cursor, 13, "row \"re\" clamps to its last cell")
        e.type("k")
        XCTAssertEqual(e.cursor, 11, "row \"ing he\" clamps to column 5")
        e.type("jj")
        XCTAssertEqual(e.cursor, bodyStart + 8, "column 8 comes back on the body row")
    }

    func testTableRowsWrapLikeText() {
        let text = "| a | bb |\n| c | d  |"
        let e = Engine(text: text, layout: WrapLayout(width: 6))
        // | a |  /  bb |  /  | c |  /  d  |
        e.type("3l")
        XCTAssertEqual(e.cursor, 3)
        e.type("j")
        XCTAssertEqual(e.cursor, 9, "column 3 on \" bb |\" is the pipe")
        e.type("j")
        XCTAssertEqual(e.cursor, 14)
        e.type("j")
        XCTAssertEqual(e.cursor, 20)
    }

    func testMalformedRowsFallBackToOneRow() {
        let buffer = TextBuffer(text: "a😀bcdef")
        let malformed: [[Range<Int>]?] = [
            nil,
            [],
            [0..<3, 4..<8],
            [0..<4, 3..<8],
            [0..<2, 2..<8],
            [0..<4],
            [1..<8],
        ]
        for rows in malformed {
            let model = ScreenModel(buffer: buffer, layout: FixedRowsLayout(rows))
            XCTAssertEqual(model.screenLines(of: 0).map(\.range), [0..<8], "rows \(String(describing: rows))")
        }
        let clipped = ScreenModel(buffer: TextBuffer(text: "abcdef\nxy"), layout: FixedRowsLayout([0..<3, 3..<7]))
        XCTAssertEqual(clipped.screenLines(of: 0).map(\.range), [0..<3, 3..<6], "the newline is not part of a row")
    }

    func testRowsThatChangeBetweenReadsDoNotTrap() {
        // TextKit lays out lazily: a line read as three rows can come back as one.
        let buffer = TextBuffer(text: "abcdefghi\nxyz")
        let layout = FixedRowsLayout([0..<3, 3..<6, 6..<9])
        let model = ScreenModel(buffer: buffer, layout: layout)
        let middle = model.screenLines(of: 0)[1]
        let last = model.screenLines(of: 0)[2]
        layout.rows = nil
        XCTAssertEqual(model.next(after: middle)?.bufferLine, 1)
        XCTAssertNil(model.previous(before: last), "line 0 is now one row, and it holds `last`")
        layout.rows = [0..<3, 3..<9]
        XCTAssertEqual(model.previous(before: last)?.range, 0..<3)
    }

    // MARK: Properties over random documents

    func testRowsPartitionEveryLine() {
        for seed in UInt64(1)...60 {
            var rng = Rng(state: seed)
            let buffer = TextBuffer(text: randomText(&rng, pieces: 40))
            let width = Int.random(in: 1...9, using: &rng)
            let model = ScreenModel(buffer: buffer, layout: WrapLayout(width: width))
            for index in 0..<buffer.lineCount {
                let line = buffer.line(index)
                let rows = model.screenLines(of: index)
                XCTAssertEqual(rows.first?.range.lowerBound, line.start, "seed \(seed)")
                XCTAssertEqual(rows.last?.range.upperBound, line.contentEnd, "seed \(seed)")
                for (a, b) in zip(rows, rows.dropFirst()) {
                    XCTAssertEqual(a.range.upperBound, b.range.lowerBound, "seed \(seed)")
                    XCTAssertFalse(a.range.isEmpty, "seed \(seed)")
                }
                for row in rows {
                    let cells = model.cells(of: row)
                    if cells.count > 1 {
                        XCTAssertLessThanOrEqual(cells.last!.end, width, "seed \(seed) row \(row)")
                    }
                }
            }
        }
    }

    func testEveryCaretRoundTripsThroughItsColumn() {
        for seed in UInt64(1)...60 {
            var rng = Rng(state: seed)
            let buffer = TextBuffer(text: randomText(&rng, pieces: 30))
            let model = ScreenModel(buffer: buffer, layout: WrapLayout(width: Int.random(in: 2...8, using: &rng)))
            for index in 0..<buffer.lineCount {
                for offset in graphemeStarts(buffer, line: index) {
                    let row = model.screenLine(containing: offset)
                    XCTAssertTrue(row.range.contains(offset), "seed \(seed) offset \(offset)")
                    let column = model.displayColumn(of: offset)
                    XCTAssertEqual(model.offset(on: row, want: .column(column)), offset, "seed \(seed) offset \(offset)")
                }
            }
        }
    }

    func testJThenKComesBack() {
        for seed in UInt64(1)...40 {
            var rng = Rng(state: seed)
            let text = randomText(&rng, pieces: 30)
            let layout = WrapLayout(width: Int.random(in: 2...8, using: &rng))
            let probe = Engine(text: text, layout: layout)
            for index in 0..<probe.buffer.lineCount {
                for offset in graphemeStarts(probe.buffer, line: index) {
                    for (there, back) in [("j", "k"), ("k", "j")] {
                        let e = Engine(text: text, layout: layout)
                        e.moveCursor(to: offset)
                        if e.type(there).beep { continue }
                        e.type(back)
                        XCTAssertEqual(e.cursor, offset, "seed \(seed) \(there)\(back) from \(offset) in \(text.debugDescription)")
                    }
                }
            }
        }
    }

    func testCountedJMatchesRepeatedJ() {
        for seed in UInt64(1)...30 {
            var rng = Rng(state: seed)
            let text = randomText(&rng, pieces: 30)
            let layout = WrapLayout(width: Int.random(in: 2...8, using: &rng))
            let start = Engine(text: text, layout: layout).buffer.graphemes(in: 0..<min(6, text.utf16.count)).last?.span.lowerBound ?? 0
            for n in 2...5 {
                let counted = Engine(text: text, layout: layout)
                counted.moveCursor(to: start)
                counted.type("\(n)j")
                let stepped = Engine(text: text, layout: layout)
                stepped.moveCursor(to: start)
                for _ in 0..<n { stepped.type("j") }
                XCTAssertEqual(counted.cursor, stepped.cursor, "seed \(seed) \(n)j")
            }
        }
    }

    func testHAndLWalkEveryGraphemeAndNeverLeaveTheLine() {
        for seed in UInt64(1)...40 {
            var rng = Rng(state: seed)
            let text = randomText(&rng, pieces: 25)
            let e = Engine(text: text, layout: WrapLayout(width: 3))
            for index in 0...e.screen.lastReachableLine {
                let starts = graphemeStarts(e.buffer, line: index)
                e.moveCursor(to: e.buffer.line(index).start)
                var seen = [e.cursor]
                while !e.type("l").beep {
                    seen.append(e.cursor)
                }
                XCTAssertEqual(seen, starts.isEmpty ? [e.buffer.line(index).start] : starts, "seed \(seed) line \(index)")
                var back = [e.cursor]
                while !e.type("h").beep {
                    back.append(e.cursor)
                }
                XCTAssertEqual(back, Array(seen.reversed()), "seed \(seed) line \(index)")
            }
        }
    }

    func testEditsKeepTheLineIndexCanonical() {
        let keys = ["x", "dd", "p", "o<Esc>", "ihi\n<Esc>", "J", "u", "<C-r>", "j", "k", "l", "$", "yyP", "a😀<Esc>", ">>", "<<", "D"]
        for seed in UInt64(1)...25 {
            var rng = Rng(state: seed)
            let e = Engine(text: randomText(&rng, pieces: 20))
            for step in 0..<60 {
                let key = keys.randomElement(using: &rng)!
                e.type(key)
                XCTAssertEqual(e.buffer.lines, LineIndex(e.text), "seed \(seed) step \(step) after \(key)")
            }
        }
    }
}
