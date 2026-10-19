import XCTest
@testable import QuillVim

final class MotionTests: XCTestCase {
    func testHJKL() {
        XCTAssertVim("a█bc", keys: "l", "ab█c")
        XCTAssertVim("ab█c", keys: "h", "a█bc")
        XCTAssertVim("█abc", keys: "h", "█abc")
        XCTAssertVim("ab█c", keys: "l", "ab█c")
        XCTAssertVim("ab█c\ndef", keys: "j", "abc\nde█f")
        XCTAssertVim("abc\nde█f", keys: "k", "ab█c\ndef")
    }

    func testJKStayOnShorterLine() {
        XCTAssertVim("a█bcd\nxy", keys: "j", "abcd\nx█y")
        XCTAssertVim("abcd\nx█y", keys: "k", "a█bcd\nxy")
    }

    func testCountHJ() {
        XCTAssertVim("█abcde", keys: "3l", "abc█de")
        XCTAssertVim("abc█de", keys: "2h", "a█bcde")
        XCTAssertVim("█a\nb\nc\nd", keys: "2j", "a\nb\n█c\nd")
    }

    func testZeroAndCaretAndDollar() {
        XCTAssertVim("  he█llo", keys: "0", "█  hello")
        XCTAssertVim("  he█llo", keys: "^", "  █hello")
        XCTAssertVim("  █hello", keys: "$", "  hell█o")
        XCTAssertVim("█hello", keys: "$", "hell█o")
    }

    func testHalfPageScroll() {
        let lines = (0..<30).map { "l\($0)" }.joined(separator: "\n")
        let engine = Engine(text: lines)
        engine.scrollLineCount = 5
        _ = engine.type("<C-d>")
        XCTAssertEqual(engine.buffer.lineIndex(containing: engine.cursor), 5)
        _ = engine.type("<C-u>")
        XCTAssertEqual(engine.buffer.lineIndex(containing: engine.cursor), 0)
        _ = engine.type("3<C-d>")
        XCTAssertEqual(engine.scrollLineCount, 3)
        XCTAssertEqual(engine.buffer.lineIndex(containing: engine.cursor), 3)
        engine.openOnEnter = true
        _ = engine.type("<C-d>")
        XCTAssertTrue(engine.openOnEnter)
    }

    func testDirectoryRenameKeepsAnchorAndEnter() {
        let engine = Engine(text: "notes.md\nsub/\n")
        engine.setDirectoryAnchor(line: 0, id: 7, sourcePath: "/tmp/notes.md", isDirectory: false)
        engine.setDirectoryAnchor(line: 1, id: 8, sourcePath: "/tmp/sub", isDirectory: true)
        engine.openOnEnter = true
        XCTAssertEqual(engine.type("<CR>").actions, [.openUnderCursor])
        engine.type("0c$renamed.md<Esc>")
        XCTAssertEqual(engine.lineTextUnderCursor(), "renamed.md")
        XCTAssertEqual(engine.buffer.anchors.first?.id.raw, 7)
        XCTAssertTrue(engine.openOnEnter)
        XCTAssertEqual(engine.type("-").actions, [.openParentDirectory])
    }

    func testGGAndG() {
        XCTAssertVim("aa\nbb\nc█c", keys: "gg", "█aa\nbb\ncc")
        XCTAssertVim("█aa\nbb\ncc", keys: "G", "aa\nbb\n█cc")
        XCTAssertVim("█aa\nbb\ncc", keys: "2G", "aa\n█bb\ncc")
        XCTAssertVim("aa\nb█b\ncc", keys: "gg", "█aa\nbb\ncc")
    }

    func testWordMotions() {
        XCTAssertVim("█hello world", keys: "w", "hello █world")
        XCTAssertVim("hello █world", keys: "b", "█hello world")
        XCTAssertVim("█hello world", keys: "e", "hell█o world")
        XCTAssertVim("hell█o world", keys: "e", "hello worl█d")
        XCTAssertVim("█foo,bar", keys: "w", "foo█,bar")
        XCTAssertVim("foo█,bar", keys: "w", "foo,█bar")
        XCTAssertVim("█foo,bar", keys: "e", "fo█o,bar")
    }

    func testWORDMotions() {
        XCTAssertVim("█foo,bar baz", keys: "W", "foo,bar █baz")
        XCTAssertVim("foo,bar █baz", keys: "B", "█foo,bar baz")
        XCTAssertVim("█foo,bar baz", keys: "E", "foo,ba█r baz")
    }

    func testCountWord() {
        XCTAssertVim("█one two three four", keys: "2w", "one two █three four")
        XCTAssertVim("one two █three four", keys: "2b", "█one two three four")
        XCTAssertVim("█one two three", keys: "2e", "one tw█o three")
    }

    func testFindChar() {
        XCTAssertVim("█hello world", keys: "fo", "hell█o world")
        XCTAssertVim("█hello world", keys: "to", "hel█lo world")
        XCTAssertVim("hello worl█d", keys: "Fw", "hello █world")
        XCTAssertVim("hello worl█d", keys: "Tw", "hello w█orld")
        XCTAssertVim("█abXabX", keys: "2fX", "abXab█X")
    }

    func testFindRepeat() {
        XCTAssertVim("█a_b_c_d", keys: "f_;", "a_b█_c_d")
        XCTAssertVim("█a_b_c_d", keys: "f_,", "a█_b_c_d")
        XCTAssertVim("a_b_c_█d", keys: "F_;", "a_b█_c_d")
    }

    func testFindMissingBeeps() {
        let e = vim("█hello", keys: "fx")
        XCTAssertEqual(e.cursor, 0)
        XCTAssertEqual(e.text, "hello")
    }

    func testParagraph() {
        XCTAssertVim("█aaa\n\nbbb\n\nccc", keys: "}", "aaa\n█\nbbb\n\nccc")
        XCTAssertVim("aaa\n█\nbbb\n\nccc", keys: "}", "aaa\n\nbbb\n█\nccc")
        XCTAssertVim("aaa\n\nbbb\n█\nccc", keys: "{", "aaa\n█\nbbb\n\nccc")
    }

    func testSentence() {
        XCTAssertVim("█Hello world. Next one.", keys: ")", "Hello world. █Next one.")
        XCTAssertVim("Hello world. █Next one.", keys: "(", "█Hello world. Next one.")
    }

    func testSearch() {
        XCTAssertVim("█one two one", keys: "/one<CR>", "one two █one")
        XCTAssertVim("█one two one", keys: "/one<CR>n", "█one two one")
        XCTAssertVim("█one two one", keys: "/two<CR>N", "one █two one")
        XCTAssertVim("alpha █beta gamma", keys: "?alpha<CR>", "█alpha beta gamma")
    }

    // MARK: Screen lines: j / k / gj / gk / 0 / $

    func testJKStepScreenRowsOfAWrappedLine() {
        let layout = WrapLayout(width: 4)
        // abcd / efgh / ij, then XYZW
        let e = vim("a█bcdefghij\nXYZW", keys: "j", layout: layout)
        XCTAssertEqual(e.cursor, 5)
        e.type("j")
        XCTAssertEqual(e.cursor, 9)
        e.type("j")
        XCTAssertEqual(e.cursor, 12)
        e.type("k")
        XCTAssertEqual(e.cursor, 9)
        e.type("kk")
        XCTAssertEqual(e.cursor, 1)
    }

    func testGJAndGKAliasJAndK() {
        let text = "a█bcdefghij\nXY\nABCDEFGH"
        for keys in [("jjj", "gjgjgj"), ("jjjkk", "gjgjgjgkgk"), ("3j", "3gj"), ("$jj", "$gjgj")] {
            let plain = vim(text, keys: keys.0, layout: WrapLayout(width: 4))
            let g = vim(text, keys: keys.1, layout: WrapLayout(width: 4))
            XCTAssertEqual(plain.cursor, g.cursor, "\(keys.0) vs \(keys.1)")
        }
    }

    func testCountsStepScreenRowsAndStopAtTheEdge() {
        let layout = WrapLayout(width: 4)
        let e = vim("█abcdefghij\nXYZ", keys: "3j", layout: layout)
        XCTAssertEqual(e.cursor, 11)
        e.type("2k")
        XCTAssertEqual(e.cursor, 4)
        let far = vim("█abcdefghij\nXYZ", keys: "9j", layout: layout)
        XCTAssertEqual(far.cursor, 11)
        XCTAssertTrue(far.type("j").beep)
        XCTAssertEqual(far.cursor, 11)
        XCTAssertVim("█a\nb\nc\nd\ne\nf\ng", keys: "5j", "a\nb\nc\nd\ne\n█f\ng")
        XCTAssertVim("a\nb\nc\nd\ne\n█f\ng", keys: "5k", "█a\nb\nc\nd\ne\nf\ng")
    }

    func testContinuationStartStaysOnTheLeftEdge() {
        let layout = WrapLayout(width: 4)
        let e = vim("█abcdefghij", keys: "4lj", layout: layout)
        XCTAssertEqual(e.cursor, 8)
        e.type("k")
        XCTAssertEqual(e.cursor, 4)
        e.type("k")
        XCTAssertEqual(e.cursor, 0)
    }

    func testShortRowDoesNotForgetTheColumn() {
        let layout = WrapLayout(width: 4)
        XCTAssertEqual(vim("█abcdef\nX\nabcdefgh", keys: "4ljj", layout: layout).cursor, 9)
        XCTAssertEqual(vim("█abcdef\nXYZW", keys: "4ljk", layout: layout).cursor, 4)
        XCTAssertEqual(vim("abcdefghij\n█X", keys: "k", layout: layout).cursor, 8)
        let e = vim("ab█cd\nxy\nABCDEFGH", keys: "jj", layout: layout)
        XCTAssertEqual(e.cursor, 10)
        e.type("kk")
        XCTAssertEqual(e.cursor, 2)
    }

    func testDesiredColumnClampsAndRestores() {
        XCTAssertVim("abcde█fghij\nab\nABCDEFGHIJ", keys: "jj", "abcdefghij\nab\nABCDE█FGHIJ")
        XCTAssertVim("abcde█fghij\nab\nABCDEFGHIJ", keys: "jjkk", "abcde█fghij\nab\nABCDEFGHIJ")
        XCTAssertVim("abcde█fghij\n\nABCDEFGHIJ", keys: "jj", "abcdefghij\n\nABCDE█FGHIJ")
    }

    func testHorizontalMotionResetsDesiredColumn() {
        // j clamps onto "ab". h resets the desired column to 0, so the next j does not restore column 5.
        XCTAssertVim("abcde█fghij\nab\nABCDEFGHIJ", keys: "jhj", "abcdefghij\nab\n█ABCDEFGHIJ")
    }

    func testEditResetsDesiredColumn() {
        XCTAssertVim("abcde█fghij\nab\nABCDEFGHIJ", keys: "jxj", "abcdefghij\na\n█ABCDEFGHIJ")
    }

    func testScreenDollarAndZero() {
        let layout = WrapLayout(width: 4)
        let e = vim("█abcdefghij", keys: "$", layout: layout)
        XCTAssertEqual(e.cursor, 3)
        e.type("j")
        XCTAssertEqual(e.cursor, 7)
        e.type("j")
        XCTAssertEqual(e.cursor, 9)
        e.type("0")
        XCTAssertEqual(e.cursor, 8)
        e.type("g0")
        XCTAssertEqual(e.cursor, 0)
        e.type("g$")
        XCTAssertEqual(e.cursor, 9)
        XCTAssertEqual(vim("█abcdefghij", keys: "2$", layout: layout).cursor, 7)
    }

    func testDollarSetsEndColumnAcrossLines() {
        XCTAssertVim("█abc\nxyz", keys: "$j", "abc\nxy█z")
        XCTAssertVim("█abc\nwxyz\nqq", keys: "$jj", "abc\nwxyz\nq█q")
        XCTAssertVim("█abc\nwxyz\nqqqq", keys: "$jhj", "abc\nwxyz\nqq█qq")
    }

    func testWideCharactersTakeTwoCells() {
        // a😀x: 😀 covers display columns 1-2, x is column 3.
        let emoji = Engine(text: "a😀x\nabcd")
        emoji.type("l")
        XCTAssertEqual(emoji.cursor, 1)
        emoji.type("j")
        XCTAssertEqual(emoji.cursor, 6)
        emoji.type("k")
        XCTAssertEqual(emoji.cursor, 1)
        emoji.type("lj")
        XCTAssertEqual(emoji.cursor, 8)
        let cjk = Engine(text: "日本語\nabcdef")
        cjk.type("lj")
        XCTAssertEqual(cjk.cursor, 6)
        cjk.type("hk")
        XCTAssertEqual(cjk.cursor, 0, "column 1 is the second cell of 日")
    }

    func testTabsAdvanceToTabStops() {
        let e = Engine(text: "\tx\nabcdefgh")
        e.type("lj")
        XCTAssertEqual(e.cursor, 7, "x sits at display column 4")
        e.type("hhk")
        XCTAssertEqual(e.cursor, 0, "column 2 is inside the tab")
    }

    // MARK: h / l: one grapheme, one buffer line

    func testHLVisitEveryGraphemeOnce() {
        let line = "**b** 😀|x é"
        let e = Engine(text: line + "\nnext")
        var seen = [e.cursor]
        while !e.type("l").beep {
            seen.append(e.cursor)
        }
        let starts = line.indices.map { line.utf16.distance(from: line.utf16.startIndex, to: $0) }
        XCTAssertEqual(seen, starts)
        var back = [e.cursor]
        while !e.type("h").beep {
            back.append(e.cursor)
        }
        XCTAssertEqual(back, starts.reversed())
        XCTAssertEqual(e.buffer.lineIndex(containing: e.cursor), 0)
    }

    func testHLDoNotCrossBufferLines() {
        let start = vim("ab\n█cd", keys: "")
        XCTAssertTrue(start.type("h").beep)
        XCTAssertEqual(start.cursor, 3)
        let end = vim("a█b\ncd", keys: "")
        XCTAssertTrue(end.type("l").beep)
        XCTAssertEqual(end.cursor, 1)
        XCTAssertVim("a█b\ncd", keys: "5l", "a█b\ncd")
    }

    func testHLIgnoreScreenRows() {
        let e = vim("█abcdefgh", keys: "4l", layout: WrapLayout(width: 4))
        XCTAssertEqual(e.cursor, 4)
        e.type("h")
        XCTAssertEqual(e.cursor, 3)
    }

    func testTableRowStepsEveryPipeAndPad() {
        let row = "| a  | bb |"
        let e = Engine(text: row)
        for expected in 1..<row.utf16.count {
            e.type("l")
            XCTAssertEqual(e.cursor, expected)
        }
    }

    // MARK: Operators and linewise commands stay on buffer lines

    func testDjStaysOnBufferLines() {
        let e = vim("█abcdefghij\nXYZ\nQ", keys: "dj", layout: WrapLayout(width: 4))
        XCTAssertEqual(e.text, "Q")
        XCTAssertEqual(e.cursor, 0)
    }

    func testOperatorDollarAndZeroUseTheBufferLine() {
        let layout = WrapLayout(width: 4)
        let d = vim("ab█cdefghij\nX", keys: "d$", layout: layout)
        XCTAssertEqual(d.text, "ab\nX")
        XCTAssertEqual(d.cursor, 1)
        XCTAssertEqual(vim("ab█cdefghij", keys: "D", layout: layout).text, "ab")
        XCTAssertEqual(vim("abcde█fghij", keys: "d0", layout: layout).text, "fghij")
        let y = vim("█abcdefghij", keys: "y$P", layout: layout)
        XCTAssertEqual(y.text, "abcdefghijabcdefghij")
    }

    func testLinewiseCommandsCoverWholeWrappedLines() {
        let layout = WrapLayout(width: 4)
        XCTAssertEqual(vim("abcde█fghij\nX", keys: ">>", layout: layout).text, "  abcdefghij\nX")
        XCTAssertEqual(vim("abcde█fghij\nX", keys: "yyp", layout: layout).text, "abcdefghij\nabcdefghij\nX")
        XCTAssertEqual(vim("abcde█fghij\nX", keys: "dd", layout: layout).text, "X")
        let colon = vim("abcdefghij\nX\nY", keys: ":3<CR>", layout: layout)
        XCTAssertEqual(colon.cursor, 13)
    }

    func testVisualLineMovesByScreenRowAndSelectsBufferLines() {
        let layout = WrapLayout(width: 4)
        let e = vim("█abcdefgh\nXY\nZ", keys: "Vj", layout: layout)
        XCTAssertEqual(e.cursor, 4)
        XCTAssertEqual(e.visualSelection, 0..<9)
        e.type("j")
        XCTAssertEqual(e.cursor, 9)
        XCTAssertEqual(e.visualSelection, 0..<12)
        e.type("d")
        XCTAssertEqual(e.text, "Z")
    }

    // MARK: Insert mode

    func testInsertDownKeepsTheColumnAcrossAShortLine() {
        let e = vim("ab█cd\nxy\nABCDEFGH", keys: "i<Down>", layout: WrapLayout(width: 4))
        XCTAssertEqual(e.cursor, 7, "insert mode may stand after the last character")
        e.type("<Down>")
        XCTAssertEqual(e.mode, .insert)
        XCTAssertEqual(e.cursor, 10)
    }

    func testInsertArrowsStayOnTheBufferLine() {
        let left = vim("ab\n█cd", keys: "i<Left>")
        XCTAssertEqual(left.cursor, 3)
        let right = vim("a█b\ncd", keys: "a<Right><Right>")
        XCTAssertEqual(right.cursor, 2)
    }

    // MARK: Multi-unit graphemes under operators

    func testOperatorsNeverSplitASurrogatePair() {
        XCTAssertEqual(vim("█a😀", keys: "d$").text, "")
        XCTAssertEqual(vim("█a😀b", keys: "lvd").text, "ab")
        XCTAssertEqual(vim("█😀😀b", keys: "2rx").text, "xxb")
        XCTAssertEqual(vim("█😀😀b", keys: "2rx").cursor, 1)
        XCTAssertEqual(vim("█é😀b", keys: "3~").text, "É😀B")
        let put = vim("█😀b", keys: "ylp")
        XCTAssertEqual(put.text, "😀😀b")
        XCTAssertEqual(put.cursor, 2)
        XCTAssertEqual(vim("█😀", keys: "ax<Esc>").cursor, 2)
    }
}
