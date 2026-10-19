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

    func testDotRepeatsHelloInsert() {
        let e = vim("█", keys: "ihello<Esc>")
        XCTAssertEqual(e.text, "hello")
        XCTAssertEqual(e.registers.lastInsert.text, "hello")
        e.type(".")
        XCTAssertEqual(e.text, "hellhelloo")
    }

    func testDotRepeatsChangeWordInsert() {
        let e = vim("█one two", keys: "cwfoo<Esc>")
        XCTAssertEqual(e.text, "foo two")
        XCTAssertEqual(e.registers.lastInsert.text, "foo")
        e.type("w.")
        XCTAssertEqual(e.text, "foo foo")
    }

    func testDotRepeatsOpenLineAfterBackspace() {
        let e = vim("█a", keys: "ofoo<BS>x<Esc>")
        XCTAssertEqual(e.text, "a\nfox")
        XCTAssertEqual(e.registers.lastInsert.text, "fox")
        e.type(".")
        XCTAssertEqual(e.text, "a\nfox\nfox")
    }

    func testArrowRestartsInsertRepeat() {
        let e = vim("█", keys: "iab<Left>c<Esc>")
        XCTAssertEqual(e.text, "acb")
        XCTAssertEqual(e.registers.lastInsert.text, "c")
        e.type(".")
        XCTAssertEqual(e.text, "accb")
    }

    func testInsertSpanKeepsNewlineAndEmoji() {
        let e = vim("█ab", keys: "a")
        e.handle(KeyEvent(.text("1\r\n2😀")))
        e.type("<Esc>")
        XCTAssertEqual(e.text, "a1\n2😀b")
        XCTAssertEqual(e.registers.lastInsert.text, "1\n2😀")
        e.type(".")
        XCTAssertEqual(e.text, "a1\n2😀1\n2😀b")
    }

    func testInsertSpanAtDocumentEnd() {
        let e = vim("█hi", keys: "A!<Esc>")
        XCTAssertEqual(e.text, "hi!")
        XCTAssertEqual(e.registers.lastInsert.text, "!")
        e.type(".")
        XCTAssertEqual(e.text, "hi!!")
    }

    func testMoveCursorReturnsNoTextChange() {
        let e = Engine(text: "hello")
        let result = e.moveCursor(to: 3)
        XCTAssertFalse(result.didChangeText)
        XCTAssertEqual(result.actions, [])
        XCTAssertEqual(result.cursorBefore, 0)
        XCTAssertEqual(result.cursorAfter, 3)
        XCTAssertEqual(e.cursor, 3)
        e.type("i")
        let broken = e.moveCursor(to: 1)
        XCTAssertEqual(broken.cursorAfter, 1)
        e.handle(KeyEvent(.character("Z")))
        e.type("<Esc>")
        XCTAssertEqual(e.registers.lastInsert.text, "Z")
        XCTAssertEqual(e.text, "hZello")
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
