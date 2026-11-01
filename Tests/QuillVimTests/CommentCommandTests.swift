import XCTest
@testable import QuillVim

final class CommentCommandTests: XCTestCase {
    func testAmbiguousLeaderCWaitsThenFlushes() {
        let engine = Engine(text: "hello", cursor: 5)
        bindCommentMaps(engine)
        let partial = engine.type(" c")
        XCTAssertTrue(partial.actions.isEmpty)
        XCTAssertTrue(engine.hasPendingAmbiguousMap)
        XCTAssertEqual(engine.statusMessage, "<leader>c")
        XCTAssertEqual(engine.flushPendingMap().actions, [.command("edit.comment")])
        XCTAssertFalse(engine.hasPendingAmbiguousMap)
        XCTAssertEqual(engine.statusMessage, "")
    }

    func testLeaderCRAndCAAreUnambiguous() {
        let engine = Engine(text: "hello")
        bindCommentMaps(engine)
        XCTAssertEqual(engine.type(" cr").actions, [.command("edit.commentResolve")])
        XCTAssertFalse(engine.hasPendingAmbiguousMap)
        XCTAssertEqual(engine.type(" ca").actions, [.command("navigate.codeAction")])
    }

    func testLeftoverKeyAfterAmbiguousComment() {
        let engine = Engine(text: "hello")
        bindCommentMaps(engine)
        let result = engine.type(" cx")
        XCTAssertEqual(result.actions, [.command("edit.comment")])
        XCTAssertEqual(result.pendingKeys, "x")
        XCTAssertFalse(engine.hasPendingAmbiguousMap)
    }

    func testVisualLeaderCDispatches() {
        let engine = Engine(text: "hello", cursor: 0)
        bindCommentMaps(engine)
        _ = engine.type("vl")
        XCTAssertEqual(engine.mode, .visual)
        XCTAssertEqual(engine.type(" c").actions, [])
        XCTAssertTrue(engine.hasPendingAmbiguousMap)
        XCTAssertEqual(engine.flushPendingMap().actions, [.command("edit.comment")])
        XCTAssertEqual(engine.mode, .visual)
    }

    func testJumpKeysDispatch() {
        let engine = Engine(text: "hello")
        bindCommentMaps(engine)
        XCTAssertEqual(engine.type("]c").actions, [.command("navigate.nextComment")])
        XCTAssertEqual(engine.type("[c").actions, [.command("navigate.prevComment")])
        XCTAssertEqual(engine.type("]x").beep, true)
    }

    func testInsertOpensAnEmptyCommentAndUndoesAsOne() {
        let engine = Engine(text: "hello", cursor: 5)
        let result = engine.applyHostEdit(replacing: 5..<5, with: "{>><<}", insertAt: 8)
        XCTAssertTrue(result.didChangeText)
        XCTAssertEqual(engine.text, "hello{>><<}")
        XCTAssertEqual(engine.mode, .insert)
        XCTAssertEqual(engine.cursor, 8)
        _ = engine.type("note<Esc>")
        XCTAssertEqual(engine.text, "hello{>>note<<}")
        _ = engine.type("u")
        XCTAssertEqual(engine.text, "hello")
        XCTAssertEqual(engine.mode, .normal)
    }

    func testWrapSelectionThenUndo() {
        let engine = Engine(text: "hello", cursor: 0)
        _ = engine.applyHostEdit(replacing: 0..<5, with: "{==hello==}{>><<}", insertAt: 14)
        XCTAssertEqual(engine.text, "{==hello==}{>><<}")
        XCTAssertEqual(engine.mode, .insert)
        XCTAssertEqual(engine.cursor, 14)
        _ = engine.type("fix<Esc>")
        XCTAssertEqual(engine.text, "{==hello==}{>>fix<<}")
        _ = engine.type("u")
        XCTAssertEqual(engine.text, "hello")
    }

    func testResolveIsOneUndoAndDotReplaysTheCommand() {
        let engine = Engine(text: "keep{>>drop<<}end", cursor: 4)
        _ = engine.applyHostEdit(replacing: 4..<14, with: "")
        engine.rememberRepeatableCommand("edit.commentResolve")
        XCTAssertEqual(engine.text, "keepend")
        _ = engine.type("u")
        XCTAssertEqual(engine.text, "keep{>>drop<<}end")
        _ = engine.type("<C-r>")
        XCTAssertEqual(engine.text, "keepend")
        engine.load(text: "a{>>one<<} b{>>two<<}", cursor: 1)
        engine.rememberRepeatableCommand("edit.commentResolve")
        XCTAssertEqual(engine.type(".").actions, [.command("edit.commentResolve")])
    }

    func testEscapeCancelsAnAmbiguousLeader() {
        let engine = Engine(text: "hello")
        bindCommentMaps(engine)
        _ = engine.type(" c")
        XCTAssertTrue(engine.hasPendingAmbiguousMap)
        _ = engine.type("<Esc>")
        XCTAssertFalse(engine.hasPendingAmbiguousMap)
        XCTAssertEqual(engine.statusMessage, "")
        XCTAssertEqual(engine.text, "hello")
    }

    private func bindCommentMaps(_ engine: Engine) {
        engine.keymap.bind(" c", command: "edit.comment")
        engine.keymap.bind(" cr", command: "edit.commentResolve")
        engine.keymap.bind(" ca", command: "navigate.codeAction")
        engine.keymap.bind("]c", command: "navigate.nextComment")
        engine.keymap.bind("[c", command: "navigate.prevComment")
    }
}
