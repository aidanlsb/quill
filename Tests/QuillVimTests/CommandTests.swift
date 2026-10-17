import XCTest
@testable import QuillVim

final class CommandTests: XCTestCase {
    func testX() {
        XCTAssertVim("he█llo", keys: "x", "he█lo")
        XCTAssertVim("hell█o", keys: "x", "hel█l")
        XCTAssertVim("█abc", keys: "2x", "█c")
    }

    func testR() {
        XCTAssertVim("he█llo", keys: "rx", "he█xlo")
        XCTAssertVim("█hello", keys: "3rx", "xx█xlo")
    }

    func testS() {
        let e = vim("he█llo", keys: "sX<Esc>")
        XCTAssertEqual(e.text, "heXlo")
    }

    func testOpenLines() {
        let o = vim("he█llo\nworld", keys: "oX<Esc>")
        XCTAssertEqual(o.text, "hello\nX\nworld")
        let O = vim("hello\nwo█rld", keys: "OX<Esc>")
        XCTAssertEqual(O.text, "hello\nX\nworld")
    }

    func testIAAppend() {
        let i = vim("he█llo", keys: "iX<Esc>")
        XCTAssertEqual(i.text, "heXllo")
        let a = vim("he█llo", keys: "aX<Esc>")
        XCTAssertEqual(a.text, "helXlo")
        let I = vim("  he█llo", keys: "IX<Esc>")
        XCTAssertEqual(I.text, "  Xhello")
        let A = vim("he█llo", keys: "AX<Esc>")
        XCTAssertEqual(A.text, "helloX")
    }

    func testInsertCount() {
        let e = vim("█_", keys: "3iab<Esc>")
        XCTAssertEqual(e.text, "ababab_")
    }

    func testTilde() {
        XCTAssertVim("█Hello", keys: "~", "h█ello")
        XCTAssertVim("█Hello", keys: "3~", "hEL█lo")
    }

    func testJoin() {
        XCTAssertVim("█hello\nworld", keys: "J", "hello█ world")
        XCTAssertVim("█a\nb\nc", keys: "3J", "a b█ c")
    }

    func testPutCharacterwise() {
        let e = vim("█hello", keys: "ylp")
        XCTAssertEqual(e.text, "hhello")
        let P = vim("█hello", keys: "ylP")
        XCTAssertEqual(P.text, "hhello")
    }

    func testClipboardRegister() {
        let clip = MemoryClipboard("XYZ")
        let engine = Engine(text: "ab", cursor: 0, clipboard: clip)
        engine.type("\"+p")
        XCTAssertEqual(engine.text, "aXYZb")
        engine.load(text: "hello", cursor: 0)
        engine.type("\"+yy")
        XCTAssertEqual(clip.text, "hello\n")
    }

    func testUnnamedRegisterRoundTrip() {
        let e = vim("█hello world", keys: "dwP")
        XCTAssertEqual(e.text, "hello world")
    }
}
