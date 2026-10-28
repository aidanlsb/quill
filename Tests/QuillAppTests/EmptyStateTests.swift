import AppKit
import XCTest
@testable import Quill

/// An empty buffer shows a quiet overlay that is not in the file. Insert, typing,
/// and opening a non-empty file all take it down.
@MainActor
final class EmptyStateTests: QuillAppTestCase {
    func testEmptyUntitledShowsCanvasAndInsertHidesIt() {
        let harness = EditorHarness(text: "")
        defer { harness.close() }
        let tv = harness.view
        tv.layoutSubtreeIfNeeded()
        XCTAssertTrue(tv.isEmptyCanvasVisible, "empty untitled hid the canvas")
        XCTAssertEqual(tv.emptyCanvas.accessibilityIdentifier(), "quill.emptyCanvas")
        XCTAssertEqual(harness.engine.text, "", "empty canvas rewrote the buffer")
        XCTAssertEqual(tv.string, "", "empty canvas inserted characters")

        _ = tv.press("i")
        tv.layoutSubtreeIfNeeded()
        XCTAssertEqual(harness.engine.mode, .insert)
        XCTAssertFalse(tv.isEmptyCanvasVisible, "insert left the canvas up")
        XCTAssertEqual(harness.engine.text, "", "insert rewrote the buffer")

        _ = tv.press("<Esc>")
        tv.layoutSubtreeIfNeeded()
        XCTAssertEqual(harness.engine.mode, .normal)
        XCTAssertTrue(tv.isEmptyCanvasVisible, "escape on an empty buffer hid the canvas")

        _ = tv.press("ihello")
        tv.layoutSubtreeIfNeeded()
        XCTAssertEqual(harness.engine.text, "hello")
        XCTAssertFalse(tv.isEmptyCanvasVisible, "typed text left the canvas up")
        XCTAssertEqual(tv.string, "hello", "canvas overlay changed the storage")
    }

    func testNonEmptyFileHidesCanvasAndEmptyNamedFileShowsIt() throws {
        let fixture = try TempDirectory()
        try fixture.write("note.md", "body\n")
        try fixture.write("blank.md", "")
        let model = AppModel()
        let harness = EditorHarness(model: model)
        defer { harness.close() }

        model.open(url: fixture.url.appendingPathComponent("note.md"), immediate: true)
        harness.view.reload()
        harness.view.layoutSubtreeIfNeeded()
        XCTAssertEqual(model.engine.text, "body\n")
        XCTAssertFalse(harness.view.isEmptyCanvasVisible, "named file with body showed the canvas")
        XCTAssertFalse(harness.view.emptyCanvasUntitled)

        model.open(url: fixture.url.appendingPathComponent("blank.md"), immediate: true)
        harness.view.reload()
        harness.view.layoutSubtreeIfNeeded()
        XCTAssertEqual(model.engine.text, "")
        XCTAssertEqual(model.document.title, "blank.md")
        XCTAssertTrue(harness.view.isEmptyCanvasVisible, "empty named file hid the canvas")
        XCTAssertEqual(harness.view.emptyCanvasTitle, "blank.md")
        XCTAssertFalse(harness.view.emptyCanvasUntitled)
        XCTAssertEqual(harness.view.string, "", "named empty canvas inserted characters")
    }

    func testDirectoryHidesEmptyCanvas() throws {
        let fixture = try TempDirectory()
        try fixture.write("notes.md", "hi\n")
        let model = AppModel()
        let harness = EditorHarness(model: model)
        defer { harness.close() }
        model.open(url: fixture.url, immediate: true)
        harness.view.reload()
        harness.view.layoutSubtreeIfNeeded()
        XCTAssertTrue(model.document.isDirectory)
        XCTAssertFalse(harness.view.isEmptyCanvasVisible, "directory showed the writing canvas")
        withExtendedLifetime(fixture) {}
    }
}
