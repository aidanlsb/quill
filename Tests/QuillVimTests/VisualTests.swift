import XCTest
@testable import QuillVim

final class VisualTests: XCTestCase {
    func testVisualDelete() {
        XCTAssertVim("█hello world", keys: "vlld", "█lo world")
        XCTAssertVim("█hello world", keys: "ve d", "█ world")
    }

    func testVisualLineDelete() {
        XCTAssertVim("█aaa\nbbb\nccc", keys: "Vjd", "█ccc")
        XCTAssertVim("aaa\n█bbb\nccc", keys: "Vjd", "aa█a\n")
    }

    func testVisualYank() {
        let e = vim("█hello world", keys: "veyP")
        XCTAssertEqual(e.text, "hellhelloo world")
    }

    func testVisualChange() {
        let e = vim("█hello world", keys: "vecX<Esc>")
        XCTAssertEqual(e.text, "X world")
    }

    func testVisualIndent() {
        XCTAssertVim("█aaa\nbbb", keys: "Vj>", "  █aaa\n  bbb")
    }

    func testVisualTilde() {
        XCTAssertVim("█hello", keys: "ve~", "HELL█O")
    }

    func testEscapeLeavesVisual() {
        let e = vim("█hello", keys: "vll<Esc>")
        XCTAssertEqual(e.mode, .normal)
        XCTAssertEqual(e.text, "hello")
    }

    func testVisualLineToggle() {
        let e = vim("█hello", keys: "V")
        XCTAssertEqual(e.mode, .visualLine)
        e.type("V")
        XCTAssertEqual(e.mode, .normal)
    }
}
