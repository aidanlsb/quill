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

/// Line facts computed the slow, obvious way, to check `LineIndex` against.
enum NaiveLines {
    static func starts(_ units: [UInt16]) -> [Int] {
        var out = [0]
        for (i, unit) in units.enumerated() where unit == 10 { out.append(i + 1) }
        return out
    }

    static func line(containing offset: Int, _ units: [UInt16]) -> Int {
        units[..<min(max(0, offset), units.count)].filter { $0 == 10 }.count
    }

    /// vim's `line('$') - 1`: lines of text, a final newline ending the last one.
    static func lastLine(_ units: [UInt16]) -> Int {
        let breaks = units.filter { $0 == 10 }.count
        return units.last == 10 ? breaks - 1 : breaks
    }
}

final class LineIndexPropertyTests: XCTestCase {
    /// Pieces that stress line starts: runs of newlines, multi-line pastes, wide graphemes.
    static let pieces = [
        "", "a", "bc", "\n", "\n\n", "\n\n\n", "x\ny", "😀", "👩‍💻", "e\u{301}", "\t", "  ",
        "line one\nline two\nline three\n", "\nlead", "trail\n", "日本",
    ]

    func check(_ index: LineIndex, _ units: [UInt16], _ context: @autoclosure () -> String) -> Bool {
        let starts = NaiveLines.starts(units)
        guard index.starts == starts, index.utf16Count == units.count else {
            XCTFail("starts \(index.starts) want \(starts) count \(index.utf16Count) want \(units.count): \(context())")
            return false
        }
        XCTAssertEqual(index.lineCount, starts.count, context())
        XCTAssertEqual(index.lastLine, NaiveLines.lastLine(units), context())
        XCTAssertEqual(index.endsWithNewline, units.last == 10, context())
        for offset in 0...units.count {
            let want = NaiveLines.line(containing: offset, units)
            guard index.line(containing: offset) == want else {
                XCTFail("line(containing: \(offset)) \(index.line(containing: offset)) want \(want): \(context())")
                return false
            }
            let position = index.position(of: offset)
            XCTAssertEqual(position.line, want, context())
            XCTAssertEqual(position.utf16Column, offset - starts[want], context())
            XCTAssertEqual(index.offset(of: position), offset, "round trip \(offset): \(context())")
        }
        for line in 0..<starts.count {
            let bufferLine = index.line(line)
            XCTAssertEqual(bufferLine.start, starts[line], context())
            let next = line + 1 < starts.count ? starts[line + 1] : units.count
            XCTAssertEqual(bufferLine.end, next, context())
            XCTAssertEqual(bufferLine.contentEnd, line + 1 < starts.count ? next - 1 : units.count, context())
        }
        return true
    }

    /// Random inserts, deletes, multi-line pastes, and replacements, each applied
    /// incrementally and checked against line starts recomputed from scratch.
    func testIncrementalEditsMatchNaiveLineStarts() {
        for seed in UInt64(1)...60 {
            var rng = SplitMix64(seed: seed)
            var units: [UInt16] = []
            var index = LineIndex()
            var history: [(Range<Int>, String)] = []
            for step in 0..<150 {
                let lower = Int.random(in: 0...units.count, using: &rng)
                let span = Int.random(in: 0...10, using: &rng) == 0 ? units.count : Int.random(in: 0...6, using: &rng)
                let upper = min(units.count, lower + span)
                let insert = Self.pieces.randomElement(using: &rng)!
                units.replaceSubrange(lower..<upper, with: Array(insert.utf16))
                index.replace(lower..<upper, with: insert)
                history.append((lower..<upper, insert))
                if !check(index, units, "seed \(seed) step \(step) edits \(history.suffix(3))") { return }
            }
        }
    }

    /// Undo is the inverse replace; replaying inverses must walk back through every
    /// earlier index exactly, and replaying forward must reach the final one.
    func testUndoAndRedoRestoreEveryIndex() {
        for seed in UInt64(100)...130 {
            var rng = SplitMix64(seed: seed)
            var text = ""
            var index = LineIndex()
            var snapshots: [(String, LineIndex)] = [(text, index)]
            var inverses: [(Range<Int>, String)] = []
            var forwards: [(Range<Int>, String)] = []
            for _ in 0..<60 {
                let units = Array(text.utf16)
                let lower = Int.random(in: 0...units.count, using: &rng)
                let upper = min(units.count, lower + Int.random(in: 0...8, using: &rng))
                let insert = Self.pieces.randomElement(using: &rng)!
                let removed = String(decoding: units[lower..<upper], as: UTF16.self)
                var next = units
                next.replaceSubrange(lower..<upper, with: Array(insert.utf16))
                text = String(decoding: next, as: UTF16.self)
                index.replace(lower..<upper, with: insert)
                forwards.append((lower..<upper, insert))
                inverses.append((lower..<(lower + insert.utf16.count), removed))
                snapshots.append((text, index))
            }
            for (step, inverse) in inverses.enumerated().reversed() {
                index.replace(inverse.0, with: inverse.1)
                XCTAssertEqual(index, snapshots[step].1, "seed \(seed) undo to \(step)")
                XCTAssertEqual(index, LineIndex(snapshots[step].0), "seed \(seed) undo to \(step)")
            }
            for forward in forwards { index.replace(forward.0, with: forward.1) }
            XCTAssertEqual(index, snapshots.last!.1, "seed \(seed) redo")
        }
    }

    func testEdgeDocuments() {
        for (text, last) in [("", 0), ("a", 0), ("\n", 0), ("a\n", 0), ("a\n\n", 1), ("a\nb", 1), ("\n\n", 1)] {
            let index = LineIndex(text)
            XCTAssertEqual(index.lastLine, last, text.debugDescription)
            XCTAssertTrue(check(index, Array(text.utf16), text.debugDescription))
        }
        var index = LineIndex("a\nb\n")
        index.replace(0..<4, with: "")
        XCTAssertEqual(index, LineIndex(), "deleting everything leaves the empty document")
    }

    func testNormalizingNewlines() {
        XCTAssertEqual(LineIndex.normalizingNewlines("a\r\nb\rc\n"), "a\nb\nc\n")
        XCTAssertEqual(LineIndex.normalizingNewlines("\r\r\n\n\r"), "\n\n\n\n")
        XCTAssertEqual(LineIndex.normalizingNewlines("no breaks 😀"), "no breaks 😀")
        XCTAssertEqual(LineIndex.normalizingNewlines("e\u{301}\r\n😀"), "e\u{301}\n😀")
        var rng = SplitMix64(seed: 7)
        let parts = ["a", "\r", "\n", "\r\n", "😀", " "]
        for _ in 0..<200 {
            let text = (0..<12).map { _ in parts.randomElement(using: &rng)! }.joined()
            let normalized = LineIndex.normalizingNewlines(text)
            XCTAssertFalse(normalized.utf16.contains(13), text.debugDescription)
            let scalars = Array(text.unicodeScalars)
            var breaks = 0
            for (i, scalar) in scalars.enumerated() {
                if scalar == "\r" || (scalar == "\n" && (i == 0 || scalars[i - 1] != "\r")) { breaks += 1 }
            }
            XCTAssertEqual(LineIndex(normalized).lineCount, breaks + 1, text.debugDescription)
        }
    }

    func testContentsSplitWhereTheIndexDoes() {
        XCTAssertEqual(LineIndex.contents(of: "a\nb\n"), ["a", "b", ""])
        XCTAssertEqual(LineIndex.contents(of: ""), [""])
        XCTAssertEqual(LineIndex.contents(of: "one\r\ntwo\rthree"), ["one", "two", "three"], "CRLF is one Character in Swift; it must still split")
        var rng = SplitMix64(seed: 11)
        for _ in 0..<100 {
            let text = (0..<10).map { _ in LineIndexPropertyTests.pieces.randomElement(using: &rng)! }.joined()
            let index = LineIndex(text)
            let contents = LineIndex.contents(of: text)
            XCTAssertEqual(contents.count, index.lineCount)
            let units = Array(text.utf16)
            for (i, line) in contents.enumerated() {
                let range = index.line(i).content
                XCTAssertEqual(String(line), String(decoding: units[range], as: UTF16.self))
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
