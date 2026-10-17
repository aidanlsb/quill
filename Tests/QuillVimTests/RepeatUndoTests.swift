import XCTest
@testable import QuillVim

final class RepeatUndoTests: XCTestCase {
    func testDotRepeatsDeleteWord() {
        XCTAssertVim("█one two three", keys: "dw.", "█three")
    }

    func testDotRepeatsChange() {
        let e = vim("█one two three", keys: "cwX<Esc>")
        XCTAssertEqual(e.text, "X two three", "after cwX")
        XCTAssertEqual(e.mode, .normal)
        e.type("w.")
        XCTAssertEqual(e.text, "X X three")
    }

    func testDotRepeatsInsert() {
        let e = vim("█ab", keys: "iX<Esc>l.")
        XCTAssertEqual(e.text, "XXab")
    }

    func testDotRepeatsOpenLine() {
        let e = vim("█a\nb", keys: "oX<Esc>j.")
        XCTAssertEqual(e.text, "a\nX\nb\nX")
    }

    func testDotRepeatsReplace() {
        XCTAssertVim("█abcd", keys: "rxl.", "x█xcd")
    }

    func testDotRepeatsX() {
        XCTAssertVim("█abcd", keys: "x.", "█cd")
    }

    func testUndoInsertAsOneGroup() {
        let e = vim("█_", keys: "ihello<Esc>u")
        XCTAssertEqual(e.text, "_")
    }

    func testUndoRedo() {
        let e = vim("█hello world", keys: "dwu")
        XCTAssertEqual(e.text, "hello world")
        e.type("<C-r>")
        XCTAssertEqual(e.text, "world")
    }

    func testUndoDeleteThenDot() {
        let e = vim("█one two three", keys: "dwudw")
        XCTAssertEqual(e.text, "two three")
        e.type(".")
        XCTAssertEqual(e.text, "three")
    }

    func testYankIsNotRepeated() {
        let e = vim("█abc def", keys: "ywwdw.")
        // dw then . should delete two words from "def", not replay yank
        XCTAssertEqual(e.text, "abc ")
    }

    func testUndoJoin() {
        let e = vim("█a\nb", keys: "Ju")
        XCTAssertEqual(e.text, "a\nb")
    }
}
