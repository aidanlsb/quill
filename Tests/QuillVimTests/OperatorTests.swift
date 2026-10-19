import XCTest
@testable import QuillVim

final class OperatorTests: XCTestCase {
    func testDeleteWord() {
        XCTAssertVim("█hello world", keys: "dw", "█world")
        XCTAssertVim("hello █world", keys: "dw", "hello█ ")
        XCTAssertVim("█hello world", keys: "de", "█ world")
        XCTAssertVim("█hello world", keys: "d$", "█")
        XCTAssertVim("hello █world", keys: "d0", "█world")
        XCTAssertVim("  he█llo", keys: "d^", "  █llo")
    }

    func testDeleteFind() {
        XCTAssertVim("█hello world", keys: "dfw", "█orld")
        XCTAssertVim("█hello world", keys: "dtw", "█world")
    }

    func testDeleteLinewiseJK() {
        XCTAssertVim("█aaa\nbbb\nccc", keys: "dj", "█ccc")
        XCTAssertVim("aaa\n█bbb\nccc", keys: "dk", "█ccc")
    }

    func testDD() {
        XCTAssertVim("aaa\n█bbb\nccc", keys: "dd", "aaa\n█ccc")
        XCTAssertVim("█aaa\nbbb", keys: "2dd", "█")
        XCTAssertVim("█only", keys: "dd", "█")
    }

    func testChangeWordLikeCE() {
        let e = vim("█hello world", keys: "cwX<Esc>")
        XCTAssertEqual(e.text, "X world")
        XCTAssertEqual(e.mode, .normal)
    }

    func testChangeWordOnWhitespace() {
        let e = vim("hello█ world", keys: "cwX<Esc>")
        XCTAssertEqual(e.text, "helloXworld")
    }

    func testYankDoesNotModify() {
        let e = vim("█hello world", keys: "yw")
        XCTAssertEqual(e.text, "hello world")
        XCTAssertEqual(e.cursor, 0)
        e.type("wP")
        XCTAssertEqual(e.text, "hello hello world")
    }

    func testYankLine() {
        let e = vim("█aaa\nbbb", keys: "yyjp")
        XCTAssertEqual(e.text, "aaa\nbbb\naaa")
    }

    func testCountOperators() {
        XCTAssertVim("█one two three four", keys: "d2w", "█three four")
        XCTAssertVim("█one two three four", keys: "2dw", "█three four")
        XCTAssertVim("█one two three four", keys: "2d2w", "█")
    }

    func testIndent() {
        XCTAssertVim("█hello", keys: ">>", "  █hello")
        XCTAssertVim("  █hello", keys: "<<", "█hello")
        XCTAssertVim("█aaa\nbbb", keys: ">j", "  █aaa\n  bbb")
    }

    func testDeleteParagraph() {
        XCTAssertVim("█aaa\nbbb\n\nccc", keys: "d}", "█\n\nccc")
    }

    func testDeleteSentence() {
        XCTAssertVim("█Hello world. Next.", keys: "d)", "█Next.")
    }

    func testDAndCAndY() {
        XCTAssertVim("he█llo", keys: "D", "h█e")
        let e = vim("he█llo", keys: "Cxyz<Esc>")
        XCTAssertEqual(e.text, "hexyz")
        let y = vim("█hello\nworld", keys: "Yp")
        XCTAssertEqual(y.text, "hello\nhello\nworld")
    }

    func testDeleteLastWordExclusiveLine() {
        // dw on the last word of a line should not pull in the next line
        XCTAssertVim("█hello\nworld", keys: "dw", "█\nworld")
    }
}
