import XCTest
@testable import QuillVim

final class ExCommandTests: XCTestCase {
    func testWrite() {
        let e = vim("█hello", keys: "i!<Esc>")
        XCTAssertTrue(e.isModified)
        let result = e.type(":w<CR>")
        XCTAssertEqual(result.actions, [.write])
        e.markSaved()
        XCTAssertFalse(e.isModified)
    }

    func testQuitDirtyBeeps() {
        let e = vim("█hello", keys: "i!<Esc>")
        let result = e.type(":q<CR>")
        XCTAssertTrue(result.beep)
        XCTAssertTrue(result.actions.isEmpty)
        XCTAssertEqual(e.statusMessage, "No write since last change")
    }

    func testQuitClean() {
        let result = Engine(text: "hello").type(":q<CR>")
        XCTAssertEqual(result.actions, [.quit])
    }

    func testWriteQuit() {
        let r = Engine(text: "hello").type(":wq<CR>")
        XCTAssertEqual(r.actions, [.writeQuit])
    }

    func testUnknownEx() {
        let r = Engine(text: "hello").type(":foo<CR>")
        XCTAssertTrue(r.beep)
        XCTAssertEqual(Engine(text: "hello").type(":foo<CR>").beep, true)
    }

    func testGoToDefinition() {
        let r = Engine(text: "hello").type("gd")
        XCTAssertEqual(r.actions, [.goToDefinition])
    }

    func testReferencesAndCodeActionKeys() {
        let refs = Engine(text: "hello").type("gr")
        XCTAssertEqual(refs.actions, [.findReferences])
        XCTAssertFalse(refs.beep)
        XCTAssertEqual(Engine(text: "hello").type(" ca").actions, [.codeAction])
        XCTAssertVim("█hello", keys: "rx", "█xello")
    }

    func testMinusOpensParentDirectory() {
        let r = Engine(text: "hello").type("-")
        XCTAssertEqual(r.actions, [.openParentDirectory])
    }

    func testEnterOpensWhenEnabled() {
        let e = Engine(text: "notes.md\n")
        e.openOnEnter = true
        let r = e.type("<CR>")
        XCTAssertEqual(r.actions, [.openUnderCursor])
        XCTAssertEqual(e.lineTextUnderCursor(), "notes.md")
    }

    func testLeaderFindAndGrep() {
        let e = Engine(text: "hello")
        XCTAssertEqual(e.type(" sf").actions, [.findFiles])
        XCTAssertEqual(e.type(" sg").actions, [.liveGrep])
    }

    func testLeaderUnknownBeeps() {
        let r = Engine(text: "hello").type(" sx")
        XCTAssertTrue(r.beep)
    }

    func testForceQuitSubstituteSetAndSearch() {
        let dirty = vim("█hello", keys: "i!<Esc>")
        XCTAssertEqual(dirty.type(":q!<CR>").actions, [.quit])
        XCTAssertVim("█one two one", keys: ":%s/one/two/g<CR>", "█two two two")
        let engine = Engine(text: "hello")
        _ = engine.type(":set shiftwidth=4<CR>")
        XCTAssertEqual(engine.shiftWidth, 4)
        XCTAssertVim("█one two", keys: "/o.e<CR>", "█one two")
        XCTAssertVim("█One two", keys: "/one<CR>", "█One two")
        let missed = Engine(text: "one")
        XCTAssertTrue(missed.type("/One<CR>").beep)
    }

    func testMarksAndJumplist() {
        let engine = Engine(text: "hello\nworld")
        _ = engine.type("ma")
        _ = engine.type("j")
        XCTAssertEqual(engine.buffer.lineIndex(containing: engine.cursor), 1)
        _ = engine.type("'a")
        XCTAssertEqual(engine.buffer.lineIndex(containing: engine.cursor), 0)
        _ = engine.type("G")
        _ = engine.type("<C-o>")
        XCTAssertEqual(engine.buffer.lineIndex(containing: engine.cursor), 0)
    }

    func testKeymap() {
        let engine = Engine(text: "hello")
        engine.keymap.bind("Q", command: "format")
        XCTAssertEqual(engine.type("Q").actions, [.command("format")])
        XCTAssertEqual(Ex.parse("%s/a/b/g").name, "s")
        XCTAssertEqual(Ex.parse("%s/a/b/g").rangeStart, .all)
        XCTAssertEqual(Ex.parse("1,3d").name, "d")
        XCTAssertEqual(Ex.parse("'<,'>s/a/b").rangeStart, .mark("<"))
    }

    func testLeaderCustomBinding() {
        let e = Engine(text: "hello")
        e.leaderBindings["x"] = .command("custom")
        XCTAssertEqual(e.type(" x").actions, [.command("custom")])
    }
}

final class SemanticsTests: XCTestCase {
    func testInclusiveDollar() {
        XCTAssertVim("he█llo", keys: "d$", "h█e")
    }

    func testExclusiveWord() {
        XCTAssertVim("█hello world", keys: "dw", "█world")
    }

    func testInclusiveWordEnd() {
        XCTAssertVim("█hello world", keys: "de", "█ world")
    }

    func testLinewiseGG() {
        XCTAssertVim("aaa\nbbb\n█ccc", keys: "dgg", "█")
    }

    func testLinewiseG() {
        XCTAssertVim("█aaa\nbbb\nccc", keys: "dG", "█")
    }

    func testVisualCharwiseInclusive() {
        XCTAssertVim("█abc", keys: "vld", "█c")
    }
}
