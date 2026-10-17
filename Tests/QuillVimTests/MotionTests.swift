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

    func testDisplayLineJK() {
        let layout = WrapLayout(width: 4)
        let e = vim("█abcdefgh", keys: "j", layout: layout)
        XCTAssertEqual(e.cursor, 4)
        e.type("k")
        XCTAssertEqual(e.cursor, 0)
    }
}
