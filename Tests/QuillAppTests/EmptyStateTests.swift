import AppKit
import XCTest
@testable import Quill
import QuillSearch
import QuillWorkspace

/// An empty buffer shows a quiet overlay that is not in the file. Insert, typing,
/// and opening a non-empty file all take it down. Hinted actions work from a
/// fresh untitled window even when cwd would have been `/`.
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

    func testNormalModeDoesNotInsertOverTheOverlay() {
        let harness = EditorHarness(text: "")
        defer { harness.close() }
        let tv = harness.view
        tv.layoutSubtreeIfNeeded()
        XCTAssertTrue(tv.isEmptyCanvasVisible)
        XCTAssertFalse(tv.isEditable)
        XCTAssertFalse(tv.acceptsTypedInput)

        _ = tv.press("hjkl")
        tv.layoutSubtreeIfNeeded()
        XCTAssertEqual(harness.engine.mode, .normal)
        XCTAssertEqual(harness.engine.text, "", "stray keys inserted on the empty canvas")
        XCTAssertEqual(tv.string, "")
        XCTAssertTrue(tv.isEmptyCanvasVisible, "stray keys hid the canvas")

        tv.insertText("typed", replacementRange: NSRange(location: 0, length: 0))
        tv.paste(nil)
        XCTAssertEqual(harness.engine.text, "", "insertText wrote behind the canvas")
        XCTAssertTrue(tv.isEmptyCanvasVisible)
    }

    func testInsertFromEmptyUntitledStartsARealBuffer() {
        let model = AppModel(config: .default, home: isolatedHome(), isDark: { false })
        let harness = EditorHarness(model: model)
        defer { harness.close() }
        XCTAssertEqual(model.document.kind, .untitled)
        XCTAssertTrue(harness.view.isEmptyCanvasVisible)
        XCTAssertNotEqual(model.browseRoot.path, "/")

        _ = harness.view.press("i") { model.afterEdit($0) }
        harness.view.layoutSubtreeIfNeeded()
        XCTAssertEqual(model.engine.mode, .insert)
        XCTAssertEqual(model.document.kind, .untitled)
        XCTAssertFalse(harness.view.isEmptyCanvasVisible, "i left the canvas up")
        XCTAssertTrue(harness.view.isEditable)
        XCTAssertEqual(model.engine.text, "")

        _ = harness.view.press("hi") { model.afterEdit($0) }
        XCTAssertEqual(model.engine.text, "hi")
        XCTAssertEqual(harness.view.string, "hi")
        XCTAssertFalse(harness.view.isEmptyCanvasVisible)
    }

    func testNonEmptyFileHidesCanvasAndEmptyNamedFileShowsIt() throws {
        let fixture = try TempDirectory()
        try fixture.write("note.md", "body\n")
        try fixture.write("blank.md", "")
        let model = AppModel(config: .default, home: fixture.url, isDark: { false })
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
        let model = AppModel(config: .default, home: fixture.url, isDark: { false })
        let harness = EditorHarness(model: model)
        defer { harness.close() }
        model.open(url: fixture.url, immediate: true)
        harness.view.reload()
        harness.view.layoutSubtreeIfNeeded()
        XCTAssertTrue(model.document.isDirectory)
        XCTAssertFalse(harness.view.isEmptyCanvasVisible, "directory showed the writing canvas")
        withExtendedLifetime(fixture) {}
    }

    func testMinusFromUntitledOpensHomeNotFilesystemRoot() throws {
        let fixture = try TempDirectory()
        try fixture.write("notes.md", "from home\n")
        let model = AppModel(
            config: .default,
            home: fixture.url,
            lastDirectory: URL(fileURLWithPath: "/"),
            isDark: { false }
        )
        XCTAssertEqual(model.document.kind, .untitled)
        XCTAssertEqual(model.browseRoot.standardizedFileURL.path, fixture.url.standardizedFileURL.path)
        XCTAssertNotEqual(model.browseRoot.path, "/")

        model.openParent()
        XCTAssertTrue(model.document.isDirectory, "minus from untitled did not open a folder (\(model.message))")
        XCTAssertEqual(model.document.url?.standardizedFileURL.path, fixture.url.standardizedFileURL.path)
        XCTAssertTrue(model.engine.text.contains("notes.md"), "home listing missing notes.md")
        withExtendedLifetime(fixture) {}
    }

    func testMinusFromUntitledOpensLastUsedDirectory() throws {
        let home = try TempDirectory()
        let last = try TempDirectory()
        try last.write("kept.md", "from last\n")
        let model = AppModel(config: .default, home: home.url, lastDirectory: last.url, isDark: { false })
        XCTAssertEqual(model.document.kind, .untitled)
        XCTAssertEqual(model.browseRoot.standardizedFileURL.path, last.url.standardizedFileURL.path)

        model.afterEdit(model.engine.type("-"))
        XCTAssertTrue(model.isDirectory)
        XCTAssertEqual(model.document.url?.standardizedFileURL.path, last.url.standardizedFileURL.path)
        XCTAssertTrue(model.engine.text.contains("kept.md"))
        withExtendedLifetime(home) {}
        withExtendedLifetime(last) {}
    }

    func testEmptyStateFilePickerUsesHomeWhenCwdWouldBeRoot() async throws {
        let fixture = try TempDirectory()
        try fixture.write("notes.md", "alpha notes\n")
        let model = AppModel(
            config: .default,
            home: fixture.url,
            lastDirectory: URL(fileURLWithPath: "/"),
            isDark: { false }
        )
        XCTAssertEqual(model.document.kind, .untitled)
        model.afterEdit(model.engine.type(" sf"))
        await waitUntil("find files") {
            model.pickerKind == .files && model.picker?.items.contains { $0.title.contains("notes.md") } == true
        }
        XCTAssertNotEqual(model.browseRoot.path, "/")
        withExtendedLifetime(fixture) {}
    }

    func testEmptyStateGrepUsesLastUsedDirectory() async throws {
        let home = try TempDirectory()
        let last = try TempDirectory()
        try last.write("notes.md", "alpha notes\n")
        try last.write("ideas.md", "beta ideas\n")
        let model = AppModel(config: .default, home: home.url, lastDirectory: last.url, isDark: { false })
        XCTAssertEqual(model.document.kind, .untitled)
        model.afterEdit(model.engine.type(" sg"))
        XCTAssertEqual(model.pickerKind, .grep)
        for character in "alpha" {
            model.handlePicker(.character(character))
        }
        await waitUntil("live grep") {
            model.picker?.items.contains { $0.title.contains("notes.md") } == true
                && model.picker?.items.contains { $0.title.contains("ideas.md") } != true
        }
        withExtendedLifetime(home) {}
        withExtendedLifetime(last) {}
    }

    func testEmptyStateEditOpensARelativePathAgainstHome() async throws {
        let fixture = try TempDirectory()
        try fixture.write("notes.md", "opened by edit\n")
        let model = AppModel(
            config: .default,
            home: fixture.url,
            lastDirectory: URL(fileURLWithPath: "/"),
            isDark: { false }
        )
        XCTAssertEqual(model.document.kind, .untitled)
        model.edit(CommandArgs(text: "notes.md"))
        await waitUntil("edit") { model.engine.text == "opened by edit\n" }
        XCTAssertEqual(
            model.document.url?.standardizedFileURL.path,
            fixture.url.appendingPathComponent("notes.md").standardizedFileURL.path
        )
        withExtendedLifetime(fixture) {}
    }

    func testEmptyStateCommandPaletteOpens() {
        let model = AppModel(config: .default, home: isolatedHome(), isDark: { false })
        XCTAssertEqual(model.document.kind, .untitled)
        model.afterEdit(model.engine.type("i"))
        XCTAssertEqual(model.engine.mode, .insert)
        XCTAssertTrue(model.runCommand("search.commands"))
        XCTAssertEqual(model.pickerKind, .commands)
        XCTAssertFalse(model.picker?.items.isEmpty ?? true)
        model.dismissCommandPalette(restore: true)
        XCTAssertNil(model.pickerKind)
        XCTAssertEqual(model.engine.mode, .insert)
    }

    func testSessionStateRemembersLastDirectoryWithoutDroppingTheme() throws {
        let fixture = try TempDirectory()
        let notes = fixture.url.appendingPathComponent("notes", isDirectory: true)
        try FileManager.default.createDirectory(at: notes, withIntermediateDirectories: true)
        let url = SessionState.url(home: fixture.url)
        try SessionState.save(SessionState(theme: .dark, lastDirectory: notes), to: url)
        let loaded = SessionState.load(from: url)
        XCTAssertEqual(loaded.theme, .dark)
        XCTAssertEqual(loaded.lastDirectory?.standardizedFileURL.path, notes.standardizedFileURL.path)
        try ThemeMemory.save(.light, to: url)
        let afterTheme = SessionState.load(from: url)
        XCTAssertEqual(afterTheme.theme, .light)
        XCTAssertEqual(afterTheme.lastDirectory?.standardizedFileURL.path, notes.standardizedFileURL.path)
        withExtendedLifetime(fixture) {}
    }

    func testNoArgLaunchBrowseRootIsNeverFilesystemRoot() {
        let delegate = AppDelegate()
        defer { delegate.closeLaunchWindow() }
        delegate.openAtLaunch(arguments: [])
        XCTAssertEqual(delegate.model.document.kind, .untitled)
        XCTAssertNotEqual(delegate.model.browseRoot.path, "/")
        XCTAssertTrue(BrowseRoot.isUsable(delegate.model.browseRoot))
    }

    private func isolatedHome() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("quill-empty-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func waitUntil(
        _ description: String,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ predicate: @MainActor @escaping () -> Bool
    ) async {
        let clock = ContinuousClock()
        let start = clock.now
        while !predicate() {
            if clock.now - start > .seconds(3) {
                XCTFail(description, file: file, line: line)
                return
            }
            await Task.yield()
        }
    }
}
