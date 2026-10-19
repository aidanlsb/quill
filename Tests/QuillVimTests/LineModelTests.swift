import QuillText
import XCTest
@testable import QuillVim

/// The buffer's line model under every kind of edit the engine makes. Each
/// step checks the incrementally kept `LineIndex` against line starts
/// recomputed from the text, plus the caret invariants that depend on it.
final class LineModelFuzzTests: XCTestCase {
    static let initial = [
        "", "a", "a\n", "one\ntwo\nthree", "one\ntwo\nthree\n", "\n\n", "😀 e\u{301}\n\tx\n\n# h\nlast",
        "word 👩‍💻 word\n\n  indented\n| a | b |\n", "İx ab\nİx\n",
    ]

    /// Commands that start and end in normal mode.
    static let commands = [
        "x", "X", "dd", "2dd", "dj", "dk", "yyp", "yyP", "yjp", "yjP", "p", "P", "J", "3J",
        "ccnew<Esc>", "cjX<Esc>", "D", "C<Esc>", ">>", "<<", ">j", "2>>", "Vj>", "Vjd", "Vjy", "vjd",
        "u", "u", "<C-r>", "j", "k", "gg", "G", "w", "b", "e", "$", "0", "^", "dw", "de", "db",
        "diw", "daw", "dip", "dap", "d}", "d{", "dG", "dgg", ":2<CR>", ":$<CR>", ":%s/a/b/g<CR>",
        ":s/x/YY/<CR>", "~", "rZ", "5l", "3j", "fa", "ta", ";", ".", "ciw😀<Esc>", "yiwP", "otwo<Esc>",
        "O<Esc>", "o<Esc>", "ihello<Esc>", "a😀<Esc>", "ie\u{301}<Esc>", "i<CR><Esc>", "A\tx<Esc>",
        "i<BS><Esc>", "di(", "da\"", "vip>", "Vjc<Esc>", "S<Esc>", "/b<CR>", "n", "N", "*",
    ]

    static let pastes = ["a\r\nb", "\r\n", "x\ry", "line\nline\n", "😀\n", "\n", "e\u{301}"]

    func testEditSequencesKeepTheLineIndexExact() {
        for seed in UInt64(1)...200 {
            var rng = Rng(state: seed)
            let start = Self.initial.randomElement(using: &rng)!
            let engine = Engine(text: start)
            var trail: [String] = []
            for _ in 0..<150 {
                let roll = Int.random(in: 0..<10, using: &rng)
                if roll == 0 {
                    let paste = Self.pastes.randomElement(using: &rng)!
                    trail.append("paste \(paste.debugDescription)")
                    engine.type("i")
                    engine.handle(KeyEvent(.text(paste)))
                    engine.type("<Esc>")
                } else if roll == 1 {
                    let paste = Self.pastes.randomElement(using: &rng)!
                    let count = engine.buffer.count
                    let a = engine.buffer.clampedCursor(Int.random(in: 0...count, using: &rng), normalMode: false)
                    let b = engine.buffer.clampedCursor(min(count, a + Int.random(in: 0...6, using: &rng)), normalMode: false)
                    trail.append("host \(a)..<\(max(a, b)) \(paste.debugDescription)")
                    engine.applyHostEdit(replacing: a..<max(a, b), with: paste)
                    engine.type("<Esc>")
                } else {
                    let keys = Self.commands.randomElement(using: &rng)!
                    trail.append(keys)
                    engine.type(keys)
                }
                if !checkInvariants(engine, "seed \(seed) start \(start.debugDescription) after \(trail.suffix(4))") { return }
            }
            // A trailing `u` leaves redo entries; the tip of the history is past them.
            for _ in 0..<400 { engine.type("<C-r>") }
            let final = engine.text
            for _ in 0..<400 { engine.type("u") }
            XCTAssertEqual(engine.text, LineIndex.normalizingNewlines(start), "seed \(seed): undoing everything")
            _ = checkInvariants(engine, "seed \(seed) after undo-all")
            for _ in 0..<400 { engine.type("<C-r>") }
            XCTAssertEqual(engine.text, final, "seed \(seed): redoing everything")
            _ = checkInvariants(engine, "seed \(seed) after redo-all")
        }
    }

    @discardableResult
    func checkInvariants(_ engine: Engine, _ context: @autoclosure () -> String) -> Bool {
        let buffer = engine.buffer
        let units = Array(engine.text.utf16)
        var starts = [0]
        for (i, unit) in units.enumerated() where unit == 10 { starts.append(i + 1) }
        guard buffer.lines.starts == starts, buffer.lines.utf16Count == units.count else {
            XCTFail("line starts \(buffer.lines.starts) want \(starts): \(context())")
            return false
        }
        let breaks = starts.count - 1
        XCTAssertEqual(buffer.lastLine, units.last == 10 ? breaks - 1 : breaks, context())
        XCTAssertFalse(units.contains(13), "a carriage return reached the buffer: \(context())")
        let cursor = engine.cursor
        XCTAssertTrue(cursor >= 0 && cursor <= buffer.count, "cursor \(cursor) of \(buffer.count): \(context())")
        if cursor < buffer.count {
            XCTAssertEqual(buffer.graphemeSpan(containing: cursor).lowerBound, cursor, "cursor inside a grapheme: \(context())")
        }
        guard engine.mode == .normal else {
            XCTFail("left in \(engine.mode): \(context())")
            return false
        }
        if !buffer.isEmpty {
            let line = buffer.lineIndex(containing: cursor)
            XCTAssertLessThanOrEqual(line, buffer.lastLine, "normal caret past the last line: \(context())")
            let content = buffer.line(line).content
            if !content.isEmpty {
                XCTAssertLessThan(cursor, content.upperBound, "normal caret on a newline: \(context())")
            }
        }
        return true
    }
}

final class LineModelColumnTests: XCTestCase {
    /// Every grapheme start maps to a (line, character column) and back, and every
    /// UTF-16 offset to an LSP position and back, on text that mixes widths.
    func testColumnsRoundTrip() {
        let text = "a😀b\ne\u{301}e\u{301}\n\t\tx👩‍💻\n\n日本語\nlast 👍🏽"
        let buffer = TextBuffer(text: text)
        for offset in 0...buffer.count {
            XCTAssertEqual(buffer.offset(of: buffer.position(of: offset)), offset, "UTF-16 round trip at \(offset)")
        }
        for line in 0...buffer.lastLine {
            let graphemes = buffer.graphemes(in: buffer.line(line).content)
            for (column, grapheme) in graphemes.enumerated() {
                XCTAssertEqual(buffer.graphemeColumn(of: grapheme.span.lowerBound), column)
                XCTAssertEqual(buffer.offset(line: line, graphemeColumn: column), grapheme.span.lowerBound)
            }
            if let last = graphemes.last {
                XCTAssertEqual(buffer.offset(line: line, graphemeColumn: graphemes.count + 5), last.span.lowerBound, "clamps to the last character")
            }
        }
        XCTAssertEqual(buffer.position(of: 3), TextPosition(line: 0, utf16Column: 3), "LSP columns stay UTF-16: 😀 is two units")
        XCTAssertEqual(buffer.graphemeColumn(of: 3), 2, "but it is one character")
    }

    func testCarriageReturnsNeverReachTheBuffer() {
        XCTAssertEqual(Engine(text: "a\r\nb\rc").text, "a\nb\nc")
        let engine = Engine(text: "ab")
        engine.type("a")
        engine.handle(KeyEvent(.text("1\r\n2")))
        engine.type("<Esc>")
        XCTAssertEqual(engine.text, "a1\n2b")
        engine.applyHostEdit(replacing: 0..<0, with: "x\r")
        XCTAssertEqual(engine.text, "x\na1\n2b")
        engine.applyHostEdits([TextEdit(range: 0..<0, replacement: "\r\n")])
        XCTAssertEqual(engine.text, "\nx\na1\n2b")
        let clip = MemoryClipboard("c\r\nd\r\n")
        let pasted = Engine(text: "top", clipboard: clip)
        pasted.type("\"+p")
        XCTAssertEqual(pasted.text, "top\nc\nd")
    }

    func testDirectoryEntryLinesFollowTheIndex() {
        var buffer = TextBuffer(text: "a/\nb.md\n")
        buffer.addAnchor(Anchor(id: AnchorID(raw: 1), offset: 0, gravity: .left, kind: .directoryEntry(sourcePath: "/a", isDirectory: true, transfer: .identity)))
        buffer.addAnchor(Anchor(id: AnchorID(raw: 2), offset: 3, gravity: .left, kind: .directoryEntry(sourcePath: "/b.md", isDirectory: false, transfer: .identity)))
        let lines = buffer.directoryEntryLines()
        XCTAssertEqual(lines.map(\.text), ["a/", "b.md", ""])
        XCTAssertEqual(lines.map { $0.anchor?.id.raw }, [1, 2, nil])
    }
}

/// One case per bug the line-model audit found. Each failed before the fix.
final class LineModelRegressionTests: XCTestCase {
    func testLinewiseEditsAtALastLineWithoutANewline() {
        XCTAssertVim("a\nb\nc", keys: "yjGp", "a\nb\nc\n█a\nb")
        XCTAssertVim("a", keys: "yy3p", "a\n█a\na\na")
        XCTAssertVim("a\nb", keys: "Gdd", "█a")
        XCTAssertVim("a\nb\nc", keys: "Gdk", "█a")
        XCTAssertVim("a\nb\nc", keys: "jdj", "█a")
        XCTAssertVim("a\nb\nc", keys: "jVjd", "█a")
        XCTAssertVim("a\nb\n", keys: "Gdd", "█a\n")
        XCTAssertVim("a\nb\n", keys: "ggyyGp", "a\nb\n█a\n")
        XCTAssertVim("", keys: "yyp", "\n█\n")
    }

    func testChangeLineKeepsTheLine() {
        XCTAssertVim("a\nb\nc", keys: "jccX<Esc>", "a\n█X\nc")
        XCTAssertVim("a\nb\nc", keys: "jcjX<Esc>", "a\n█X")
        XCTAssertVim("a\nb\nc", keys: "GccX<Esc>", "a\nb\n█X")
    }

    func testIndentCoversEveryLineInRange() {
        XCTAssertVim("a\nb\nc", keys: ">j", "  a\n  b\nc")
        XCTAssertVim("a\nb\nc", keys: "2>>", "  a\n  b\nc")
        XCTAssertVim("a\nb\nc", keys: "Vj>", "  a\n  b\nc")
        XCTAssertVim("a\nb\n", keys: ">G", "  a\n  b\n")
        XCTAssertVim("a\n\nb", keys: ">G", "  a\n\n  b")
    }

    func testLastLineIgnoresTheEmptyTextAfterAFinalNewline() {
        XCTAssertVim("a\nb\n", keys: "G", "a\n█b\n")
        XCTAssertVim("a\nb\n", keys: ":$<CR>", "a\n█b\n")
        XCTAssertVim("a\nb\n", keys: ":9<CR>", "a\n█b\n")
        XCTAssertVim("a\nb\n", keys: "jj", "a\n█b\n")
        XCTAssertVim("a\nb\n", keys: "J", "a█ b\n")
        XCTAssertVim("a\nb\n", keys: "jJ", "a\n█b\n")
        XCTAssertVim("a\n\nb\n", keys: "jd}", "a\n█\n")
    }

    func testMotionsStepByGrapheme() {
        XCTAssertVim("ab😀 cd", keys: "e", "a█b😀 cd")
        XCTAssertVim("ab😀 cd", keys: "ee", "ab█😀 cd")
        XCTAssertVim("ab😀", keys: "w", "ab█😀")
        XCTAssertVim("a😀b", keys: "tb", "a█😀b")
        XCTAssertVim("a😀😀b", keys: "f😀;", "a😀█😀b")
        XCTAssertVim("x e\u{301}e\u{301} y", keys: "ee", "x e\u{301}e\u{301} █y")
        XCTAssertVim("x 😀😀", keys: "$b", "x █😀😀")
        XCTAssertVim("Hi. 😀 there", keys: ")", "Hi. █😀 there")
        XCTAssertVim("a😀 b", keys: "E", "a█😀 b")
    }

    func testTextObjectsStepByGrapheme() {
        XCTAssertVim("a (█😀) b", keys: "di(", "a (█) b")
        XCTAssertVim("a (😀) b", keys: "f😀da(", "a █ b")
        XCTAssertVim("a \"😀\" b", keys: "f😀di\"", "a \"█\" b")
        let engine = vim("a 😀😀", keys: "$viw")
        XCTAssertEqual(engine.cursor, 4, "visual iw ends on the last emoji's first unit")
    }

    func testParagraphObjectsFromABlankLine() {
        XCTAssertVim("aa\n\nbb\n\ncc", keys: "jdip", "aa\n█bb\n\ncc")
        XCTAssertVim("aa\n\nbb\n\ncc", keys: "jdap", "aa\n█\ncc")
        XCTAssertVim("aa\n\nbb", keys: "Gdap", "█aa")
    }

    /// Empty text after a final newline is not a line, so an empty last line has to
    /// end in a newline to exist. Edits that make or empty one keep it.
    func testEmptyLastLinesSurvive() {
        XCTAssertVim("a", keys: "o<Esc>", "a\n█\n")
        XCTAssertVim("a", keys: "A<CR><Esc>", "a\n█\n")
        XCTAssertVim("", keys: "o<Esc>", "\n█\n")
        XCTAssertVim("a", keys: "o<Esc>.", "a\n\n█\n")
        XCTAssertVim("a\nx", keys: "Gx", "a\n█\n")
        XCTAssertVim("a\nxy", keys: "GD", "a\n█\n")
        XCTAssertVim("a\n ", keys: "G<<", "a\n█\n")
        XCTAssertVim("a\nx", keys: "Gxu<C-r>", "a\n█\n")
        XCTAssertVim("\na", keys: "yyGp", "\na\n█\n")
        let formatted = Engine(text: "a")
        formatted.applyHostEdits([TextEdit(range: 1..<1, replacement: "\n")])
        XCTAssertEqual(formatted.text, "a\n", "a formatter's final newline does not add a line")
    }

    func testRepeatAfterVisualAndChangeEdits() {
        XCTAssertVim("\n\n", keys: "Vjc<Esc>.", "█\n", mode: .normal)
        XCTAssertVim("ab\ncd", keys: "v>.", "    █ab\ncd")
        XCTAssertVim("a\nb\nc", keys: "vj>j.", "  a\n    █b\n  c")
        XCTAssertVim("abcdef", keys: "vlx", "█cdef", mode: .normal)
        XCTAssertVim("abc", keys: "vls<Esc>", "█c")
        XCTAssertVim("😀😀abcd", keys: "vld.", "█cd")
        XCTAssertVim("😀 a", keys: "$a😀<Esc>.", "😀 a😀█😀")
        XCTAssertVim("😀 ab cd", keys: "wciwX<Esc>w.", "😀 X █X")
    }

    func testSubstituteLeavesTheCaretOnTheLastChangedLine() {
        XCTAssertVim("ab\n  xé\nend", keys: ":%s/x/YY/<CR>", "ab\n  █YYé\nend")
        XCTAssertVim("x\nx\nz", keys: ":%s/x/1\\n2/<CR>", "1\\n2\n█1\\n2\nz")
    }

    func testFoldedSearchKeepsOffsetsWhenLowercaseChangesLength() {
        XCTAssertVim("İx İx ab", keys: "/ab<CR>", "İx İx █ab")
        XCTAssertVim("İx İx ab", keys: "/x<CR>n", "İx İ█x ab")
        XCTAssertVim("İx ab İx", keys: ":s/x/Y/g<CR>", "İY ab İY")
        XCTAssertEqual(Searcher.literalMatches(in: "e\u{301}e", pattern: "e"), [2..<3], "never matches inside a grapheme")
    }
}
