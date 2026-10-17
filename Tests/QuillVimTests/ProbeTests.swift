import XCTest
@testable import QuillVim

final class ProbeTests: XCTestCase {
    func testChangeWordUndoRestoresInOneStep() {
        let engine = vim("█one two", keys: "cwX<Esc>")
        XCTAssertEqual(engine.text, "X two")
        let undone = engine.handle(KeyEvent(.character("u")))
        XCTAssertFalse(undone.beep)
        XCTAssertEqual(engine.text, "one two")
    }

    func testChangeLineUndoRestoresInOneStep() {
        let engine = vim("█one two", keys: "ccX<Esc>u")
        XCTAssertEqual(engine.text, "one two")
    }

    func testSubstituteUndoRestoresInOneStep() {
        let engine = vim("█one two", keys: "sX<Esc>u")
        XCTAssertEqual(engine.text, "one two")
    }

    func testOpenLineUndoRemovesTheBlankLine() {
        let engine = vim("█a\nb", keys: "o<Esc>")
        XCTAssertEqual(engine.text, "a\n\nb")
        let undone = engine.handle(KeyEvent(.character("u")))
        XCTAssertFalse(undone.beep)
        XCTAssertEqual(engine.text, "a\nb")
    }

    func testUndoRedoRoundTrip() {
        let engine = vim("█one two", keys: "cwX<Esc>u")
        XCTAssertEqual(engine.text, "one two")
        engine.type("<C-r>")
        XCTAssertEqual(engine.text, "X two")
    }

    func testEditStreamMirrorsTheBuffer() {
        let cases: [(String, String)] = [
            ("█a\nb\nc\nd", "3J"),
            ("█a\nb\nc", ">>"),
            ("█a\nb\nc", "Vj>"),
            ("█a\nb\nc", "Vj<"),
            ("█ab", "3ix<Esc>"),
            ("█hello", "yl3p"),
            ("█one two", "dwu"),
            ("█a\nb", "ox<Esc>"),
            ("█one two three", "dw.."),
            ("█Hello", "~~~"),
        ]
        for (initial, keys) in cases {
            let parsed = splitMarked(initial)
            let engine = Engine(text: parsed.text, cursor: parsed.cursor)
            var mirror = parsed.text
            for event in KeyEvent.parse(keys) {
                let result = engine.handle(event)
                for edit in result.edits {
                    mirror = applyUTF16(edit, to: mirror)
                }
                XCTAssertEqual(
                    mirror,
                    engine.text,
                    "desync after \(keys) edit \(result.edits)"
                )
            }
        }
    }

    func testHostEditIsUndoableAndReported() {
        let engine = Engine(text: "[[", cursor: 2)
        let result = engine.applyHostEdit(replacing: 2..<2, with: "note")
        XCTAssertEqual(engine.text, "[[note")
        XCTAssertEqual(result.edits.count, 1)
        engine.type("u")
        XCTAssertEqual(engine.text, "[[")
    }

    func testHostEditsAreOneUndoGroup() {
        let engine = Engine(text: "aaa\nbbb\nccc")
        engine.markSaved()
        let noop = engine.applyHostEdits([])
        XCTAssertFalse(noop.didChangeText)
        XCTAssertFalse(engine.isModified)
        let result = engine.applyHostEdits([
            TextEdit(range: 0..<3, replacement: "AA"),
            TextEdit(range: 8..<11, replacement: "CCCC"),
        ])
        XCTAssertEqual(engine.text, "AA\nbbb\nCCCC")
        XCTAssertEqual(result.edits.count, 2)
        XCTAssertTrue(engine.isModified)
        engine.type("u")
        XCTAssertEqual(engine.text, "aaa\nbbb\nccc")
        XCTAssertFalse(engine.isModified)
    }

    func testBufferIsNotWritableFromOutside() {
        let engine = Engine(text: "abc", cursor: 0)
        XCTAssertEqual(engine.buffer.text, "abc")
    }

    func testCommittedTextInsertsInInsertMode() {
        let engine = vim("█", keys: "i")
        let result = engine.handle(KeyEvent(.text("é")))
        XCTAssertEqual(result.edits.map(\.replacement), ["é"])
        engine.handle(KeyEvent(.text("😀")))
        engine.type("<Esc>")
        XCTAssertTrue(engine.text.hasPrefix("é😀"))
    }

    func testEmojiMotionStaysOnGraphemeBoundaries() {
        let engine = Engine(text: "a😀b", cursor: 0)
        engine.type("l")
        XCTAssertEqual(engine.cursor, 1)
        engine.type("l")
        XCTAssertEqual(engine.cursor, 3)
        engine.type("h")
        XCTAssertEqual(engine.cursor, 1)
        engine.type("x")
        XCTAssertEqual(engine.text, "ab")
        XCTAssertEqual(engine.cursor, 1)
    }

    func testDirectoryYankIsCopyAndDeleteIsMove() {
        let engine = Engine(text: "a.md\nb.md\n", cursor: 0)
        engine.setDirectoryAnchor(line: 0, id: 1, sourcePath: "/notes/a.md", isDirectory: false)
        engine.setDirectoryAnchor(line: 1, id: 2, sourcePath: "/notes/b.md", isDirectory: false)
        engine.type("yy")
        guard case .directoryEntry(_, _, let yanked) = engine.unnamedRegister.anchors.first?.kind else {
            return XCTFail("yy did not carry an anchor")
        }
        XCTAssertEqual(yanked, .copy)
        XCTAssertEqual(engine.buffer.anchors.count, 2)

        engine.type("jdd")
        guard case .directoryEntry(let path, _, let moved) = engine.unnamedRegister.anchors.first?.kind else {
            return XCTFail("dd did not carry an anchor")
        }
        XCTAssertEqual(moved, .move)
        XCTAssertEqual(path, "/notes/b.md")
        XCTAssertFalse(engine.buffer.anchors.contains { $0.id.raw == 2 })

        engine.type("P")
        XCTAssertTrue(engine.buffer.anchors.contains { anchor in
            if case .directoryEntry(_, _, .move) = anchor.kind { return anchor.id.raw == 2 }
            return false
        })
    }

    func testRopeEditsAndLineIndex() {
        var rope = Rope("hello\nworld")
        XCTAssertEqual(rope.utf16Count, 11)
        XCTAssertEqual(rope.newlineCount, 1)
        rope.replace(5..<6, with: "!\n")
        XCTAssertEqual(rope.content, "hello!\nworld")
        XCTAssertEqual(rope.substring(0..<6), "hello!")
        let copy = rope
        rope.replace(0..<0, with: "X")
        XCTAssertEqual(rope.content, "Xhello!\nworld")
        XCTAssertEqual(copy.content, "hello!\nworld")
    }

    private func applyUTF16(_ edit: TextEdit, to text: String) -> String {
        let units = Array(text.utf16)
        let lower = min(max(0, edit.range.lowerBound), units.count)
        let upper = min(max(lower, edit.range.upperBound), units.count)
        var out: [UInt16] = []
        out.reserveCapacity(units.count - (upper - lower) + edit.replacement.utf16.count)
        out.append(contentsOf: units[..<lower])
        out.append(contentsOf: edit.replacement.utf16)
        out.append(contentsOf: units[upper...])
        return String(decoding: out, as: UTF16.self)
    }
}
