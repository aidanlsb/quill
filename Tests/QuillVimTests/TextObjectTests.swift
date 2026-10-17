import XCTest
@testable import QuillVim

final class TextObjectTests: XCTestCase {
    func testInnerWord() {
        XCTAssertVim("hello wo█rld now", keys: "diw", "hello █ now")
        XCTAssertVim("hello wo█rld now", keys: "daw", "hello █now")
    }

    func testInnerWordOnWhitespace() {
        XCTAssertVim("hello█ world", keys: "diw", "hello█world")
    }

    func testAWordIncludesTrailingSpace() {
        XCTAssertVim("█hello world", keys: "daw", "█world")
    }

    func testSentenceObjects() {
        XCTAssertVim("Hi. █Hello world. Next.", keys: "dis", "Hi. █ Next.")
        XCTAssertVim("Hi. █Hello world. Next.", keys: "das", "Hi. █Next.")
    }

    func testParagraphObjects() {
        XCTAssertVim("aa\n\n█bb\ncc\n\ndd", keys: "dip", "aa\n\n█\ndd")
        let e = vim("aa\n\n█bb\ncc\n\ndd", keys: "dap")
        XCTAssertFalse(e.text.contains("bb"))
        XCTAssertTrue(e.text.contains("dd"))
    }

    func testQuoteObjects() {
        XCTAssertVim("say \"he█llo\" now", keys: "di\"", "say \"█\" now")
        XCTAssertVim("say \"he█llo\" now", keys: "da\"", "say █ now")
        XCTAssertVim("a 'x█y' b", keys: "di'", "a '█' b")
        XCTAssertVim("a `x█y` b", keys: "di`", "a `█` b")
    }

    func testBracketObjects() {
        XCTAssertVim("foo (ba█r) baz", keys: "di(", "foo (█) baz")
        XCTAssertVim("foo (ba█r) baz", keys: "da(", "foo █ baz")
        XCTAssertVim("foo (ba█r) baz", keys: "dib", "foo (█) baz")
        XCTAssertVim("a[b█c]d", keys: "di[", "a[█]d")
        XCTAssertVim("a{b█c}d", keys: "di{", "a{█}d")
        XCTAssertVim("a{b█c}d", keys: "diB", "a{█}d")
        XCTAssertVim("a<b█c>d", keys: "di<", "a<█>d")
    }

    func testNestedBrackets() {
        XCTAssertVim("(a (b█c) d)", keys: "di(", "(a (█) d)")
        XCTAssertVim("(a (bc) d█)", keys: "di(", "(█)")
    }

    func testChangeInnerWord() {
        let e = vim("hello wo█rld now", keys: "ciwX<Esc>")
        XCTAssertEqual(e.text, "hello X now")
    }

    func testYankInnerWord() {
        let e = vim("hello wo█rld now", keys: "yiwP")
        XCTAssertEqual(e.text, "hello woworldrld now")
    }
}
