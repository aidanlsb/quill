import XCTest
@testable import QuillVim

final class ExCommandTests: XCTestCase {
    func testWriteAndQuitAreExCalls() {
        let e = vim("█hello", keys: "i!<Esc>")
        XCTAssertTrue(e.isModified)
        let write = e.type(":w<CR>")
        XCTAssertEqual(write.actions, [.ex(ExCall(name: "w"))])
        XCTAssertFalse(write.beep)
        XCTAssertEqual(e.type(":w foo<CR>").actions, [.ex(ExCall(name: "w", args: "foo"))])
        XCTAssertEqual(e.type(":write<CR>").actions, [.ex(ExCall(name: "write"))])
        // The dirty check lives in the host. The engine only reports the call.
        let quit = e.type(":q<CR>")
        XCTAssertEqual(quit.actions, [.ex(ExCall(name: "q"))])
        XCTAssertFalse(quit.beep)
        XCTAssertEqual(e.type(":q!<CR>").actions, [.ex(ExCall(name: "q", bang: true))])
        XCTAssertEqual(e.type(":wq<CR>").actions, [.ex(ExCall(name: "wq"))])
        XCTAssertEqual(e.type(":x<CR>").actions, [.ex(ExCall(name: "x"))])
        e.markSaved()
        XCTAssertFalse(e.isModified)
    }

    func testEditThemeAndSplitsAreExCalls() {
        let e = Engine(text: "hello")
        XCTAssertEqual(e.type(":e<CR>").actions, [.ex(ExCall(name: "e"))])
        XCTAssertEqual(e.type(":edit notes.md<CR>").actions, [.ex(ExCall(name: "edit", args: "notes.md"))])
        XCTAssertEqual(e.type(":e!<CR>").actions, [.ex(ExCall(name: "e", bang: true))])
        XCTAssertEqual(e.type(":theme dark<CR>").actions, [.ex(ExCall(name: "theme", args: "dark"))])
        XCTAssertEqual(e.type(":theme<CR>").actions, [.ex(ExCall(name: "theme"))])
        XCTAssertEqual(e.type(":theme blue<CR>").actions, [.ex(ExCall(name: "theme", args: "blue"))])
        XCTAssertEqual(e.type(":sp<CR>").actions, [.ex(ExCall(name: "sp"))])
        XCTAssertEqual(e.type(":vs<CR>").actions, [.ex(ExCall(name: "vs"))])
        let unknown = e.type(":foo<CR>")
        XCTAssertEqual(unknown.actions, [.ex(ExCall(name: "foo"))])
        XCTAssertFalse(unknown.beep)
    }

    func testTableFormatResolvesLines() {
        let text = "| a | bb |\n| - | -- |\n| c | d |\n"
        let engine = Engine(text: text)
        let result = engine.type(":TableFormat<CR>")
        XCTAssertFalse(result.beep)
        XCTAssertEqual(result.actions, [.ex(ExCall(name: "TableFormat"))])
        let all = engine.type(":%TableFormat<CR>")
        XCTAssertEqual(engine.buffer.lastLine, 2)
        XCTAssertEqual(
            all.actions,
            [.ex(ExCall(name: "TableFormat", lines: 0...2))]
        )
        let extra = engine.type(":TableFormat extra<CR>")
        XCTAssertEqual(extra.actions, [.ex(ExCall(name: "TableFormat", args: "extra"))])
        let lines = Engine(text: "0\n1\n2\n3\n4\n5")
        XCTAssertEqual(
            lines.type(":3,5TableFormat<CR>").actions,
            [.ex(ExCall(name: "TableFormat", lines: 2...4))]
        )
    }

    func testInsertLeaveDoesNotAskTheHostToFormat() {
        let engine = Engine(text: "| a | b |\n| - | - |\n")
        let result = engine.type("ix<Esc>")
        XCTAssertTrue(result.actions.isEmpty)
    }

    func testUnboundHostKeysDoNotDispatch() {
        let engine = Engine(text: "hello\nworld")
        let definition = engine.type("gd")
        XCTAssertTrue(definition.actions.isEmpty)
        XCTAssertTrue(definition.beep)
        XCTAssertTrue(Engine(text: "hello").type("gr").actions.isEmpty)
        XCTAssertTrue(Engine(text: "hello").type("-").actions.isEmpty)
        XCTAssertTrue(Engine(text: "hello").type("-").beep)
        let down = Engine(text: "hello\nworld")
        XCTAssertTrue(down.type("<CR>").actions.isEmpty)
        XCTAssertEqual(down.buffer.lineIndex(containing: down.cursor), 1)
        XCTAssertTrue(Engine(text: "hello").type(" sf").actions.isEmpty)
    }

    func testBoundHostKeysDispatch() {
        let engine = Engine(text: "hello\nworld")
        engine.keymap.bind("gd", command: "navigate.definition")
        engine.keymap.bind("gr", command: "navigate.references")
        engine.keymap.bind("-", command: "file.parent")
        engine.keymap.bind("<CR>", command: "file.openEntry")
        engine.keymap.bind(" sf", command: "search.files")
        XCTAssertEqual(engine.type("gd").actions, [.command("navigate.definition")])
        XCTAssertEqual(engine.type("gr").actions, [.command("navigate.references")])
        XCTAssertEqual(engine.type("-").actions, [.command("file.parent")])
        XCTAssertEqual(engine.type("<CR>").actions, [.command("file.openEntry")])
        let shift = Engine(text: "  hello")
        shift.keymap.bind("<CR>", command: "file.openEntry")
        _ = shift.type("<<")
        XCTAssertEqual(shift.text, "hello")
        XCTAssertEqual(Engine(text: "hello").type(" sf").actions, [])
        let mapped = Engine(text: "hello")
        mapped.keymap.bind(" sf", command: "search.files")
        XCTAssertEqual(mapped.type(" sf").actions, [.command("search.files")])
    }

    func testFailedPrefixReplaysThroughVim() {
        let bound = Engine(text: "aa\nbb\ncc")
        bound.keymap.bind("gd", command: "navigate.definition")
        _ = bound.type("Ggg")
        XCTAssertEqual(bound.buffer.lineIndex(containing: bound.cursor), 0)

        let down = Engine(text: "hello\nworld")
        down.keymap.bind("gd", command: "navigate.definition")
        let plain = Engine(text: "hello\nworld")
        let mappedDown = down.type("gj")
        let plainDown = plain.type("gj")
        XCTAssertEqual(down.cursor, plain.cursor)
        XCTAssertEqual(down.text, plain.text)
        XCTAssertEqual(mappedDown.beep, plainDown.beep)
        XCTAssertEqual(mappedDown.actions, plainDown.actions)

        let end = Engine(text: "hello world")
        end.keymap.bind("gd", command: "navigate.definition")
        let plainEnd = Engine(text: "hello world")
        let mappedEnd = end.type("ge")
        let plainEndResult = plainEnd.type("ge")
        XCTAssertEqual(end.cursor, plainEnd.cursor)
        XCTAssertEqual(end.text, plainEnd.text)
        XCTAssertEqual(mappedEnd.beep, plainEndResult.beep)
        XCTAssertEqual(mappedEnd.actions, plainEndResult.actions)
    }

    func testUnboundLeaderReplaysAsSpaceThenTheKey() {
        let engine = Engine(text: "hello")
        engine.keymap.bind(" sf", command: "search.files")
        let partial = engine.type(" s")
        XCTAssertTrue(partial.actions.isEmpty)
        XCTAssertFalse(partial.beep)
        XCTAssertEqual(engine.statusMessage, "<leader>s")
        engine.type("<Esc>")
        XCTAssertEqual(engine.statusMessage, "")
        let replayed = engine.type(" x")
        XCTAssertTrue(replayed.actions.isEmpty)
        XCTAssertEqual(engine.text, "hllo")
        XCTAssertEqual(engine.statusMessage, "")
        XCTAssertEqual(engine.type(" sf").actions, [.command("search.files")])
    }

    func testCountSkipsTheKeymap() {
        let engine = Engine(text: "a\nb\nc\nd")
        engine.keymap.bind("gd", command: "navigate.definition")
        let counted = engine.type("3gd")
        XCTAssertTrue(counted.actions.isEmpty)
        XCTAssertTrue(counted.beep)
        XCTAssertEqual(engine.buffer.lineIndex(containing: engine.cursor), 0)
        _ = engine.type("<Esc>")
        _ = engine.type("3j")
        XCTAssertEqual(engine.buffer.lineIndex(containing: engine.cursor), 3)
    }

    func testForceQuitSubstituteSetAndSearch() {
        XCTAssertVim("█one two one", keys: ":%s/one/two/g<CR>", "█two two two")
        let engine = Engine(text: "hello")
        _ = engine.type(":set shiftwidth=4<CR>")
        XCTAssertEqual(engine.shiftWidth, 4)
        XCTAssertTrue(engine.type(":set nosuch<CR>").beep)
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

    func testKeymapCommandAndExParse() {
        let engine = Engine(text: "hello")
        engine.keymap.bind("Q", command: "format")
        XCTAssertEqual(engine.type("Q").actions, [.command("format")])
        XCTAssertEqual(Ex.parse("%s/a/b/g").name, "s")
        XCTAssertEqual(Ex.parse("%s/a/b/g").rangeStart, .all)
        XCTAssertEqual(Ex.parse("1,3d").name, "d")
        XCTAssertEqual(Ex.parse("'<,'>s/a/b").rangeStart, .mark("<"))
    }

    func testLineAddressStaysInTheEngine() {
        let engine = Engine(text: "a\nb\nc")
        _ = engine.type(":3<CR>")
        XCTAssertEqual(engine.buffer.lineIndex(containing: engine.cursor), 2)
        XCTAssertTrue(engine.type(":3<CR>").actions.isEmpty)
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
