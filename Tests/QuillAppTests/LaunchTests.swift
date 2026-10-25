import AppKit
import XCTest
@testable import Quill
import QuillWorkspace

/// What a launched process proves is `AppSmoke`. This checks the same wiring in process.
final class LaunchTests: QuillAppTestCase {
    @MainActor
    func testTypingThroughKeyDownEditsTheStorage() {
        let harness = EditorHarness(text: "")
        defer { harness.close() }
        harness.type("ihello<Esc>")
        XCTAssertEqual(harness.engine.text, "hello")
        XCTAssertEqual(harness.view.string, "hello")
    }

    @MainActor
    func testModelHostUsesTheModelsEngine() {
        let model = AppModel()
        let harness = EditorHarness(model: model)
        defer { harness.close() }
        XCTAssertTrue(harness.view.engine === model.engine)
        XCTAssertTrue(harness.scroll.documentView === harness.view)
        harness.resize(to: NSSize(width: 900, height: 500))
        XCTAssertEqual(harness.engine.text, model.engine.text)
    }

    @MainActor
    func testAppKitMustNotOpenAnUntitledFile() throws {
        let delegate = AppDelegate()
        let app = NSApplication.shared
        XCTAssertFalse(delegate.applicationShouldOpenUntitledFile(app))
        XCTAssertFalse(delegate.applicationOpenUntitledFile(app))
        let coder = try NSKeyedArchiver(requiringSecureCoding: true)
        XCTAssertFalse(delegate.application(app, shouldRestoreApplicationState: coder))
        XCTAssertFalse(delegate.application(app, shouldSaveApplicationState: coder))
    }

    @MainActor
    func testNoArgLaunchOpensOneUntitledWindow() {
        let delegate = AppDelegate()
        defer { delegate.closeLaunchWindow() }
        delegate.openAtLaunch(arguments: [])
        XCTAssertNil(delegate.model.fileURL)
        XCTAssertEqual(delegate.model.engine.text, "")
        XCTAssertEqual(delegate.model.document.kind, .untitled)
        assertSingleEditor(delegate)
    }

    @MainActor
    func testFileArgumentOpensThatFileInOneWindow() throws {
        let fixture = try TempDirectory()
        try fixture.write("note.md", "from argv\n")
        let note = fixture.url.appendingPathComponent("note.md")
        let delegate = AppDelegate()
        defer { delegate.closeLaunchWindow() }
        delegate.openAtLaunch(arguments: ["--wait", note.path])
        XCTAssertEqual(delegate.model.fileURL?.path, note.path)
        XCTAssertEqual(delegate.model.engine.text, "from argv\n")
        assertSingleEditor(delegate)
    }

    @MainActor
    func testQuillURLArgumentOpensThatFileInOneWindow() throws {
        let fixture = try TempDirectory()
        try fixture.write("via-url.md", "from quill url\n")
        let note = fixture.url.appendingPathComponent("via-url.md")
        let url = LaunchRequest.url(for: LaunchTarget(path: note.path, line: 1))
        let delegate = AppDelegate()
        defer { delegate.closeLaunchWindow() }
        delegate.openAtLaunch(arguments: [url.absoluteString])
        XCTAssertEqual(delegate.model.fileURL?.path, note.path)
        XCTAssertEqual(delegate.model.engine.text, "from quill url\n")
        assertSingleEditor(delegate)
    }

    @MainActor
    func testOpenURLsBeforeTheWindowOpensTheFileOnce() throws {
        let fixture = try TempDirectory()
        try fixture.write("event.md", "from open urls\n")
        let note = fixture.url.appendingPathComponent("event.md")
        let delegate = AppDelegate()
        defer { delegate.closeLaunchWindow() }
        delegate.application(NSApplication.shared, open: [note])
        delegate.openAtLaunch(arguments: [])
        XCTAssertEqual(delegate.model.fileURL?.path, note.path)
        XCTAssertEqual(delegate.model.engine.text, "from open urls\n")
        assertSingleEditor(delegate)
    }

    @MainActor
    func testGetURLBeforeTheModelIsQueuedThenOpenedOnce() throws {
        let fixture = try TempDirectory()
        try fixture.write("queued.md", "from pending url\n")
        let note = fixture.url.appendingPathComponent("queued.md")
        let url = LaunchRequest.url(for: LaunchTarget(path: note.path))
        let delegate = AppDelegate()
        defer { delegate.closeLaunchWindow() }
        delegate.accept(url)
        XCTAssertNil(delegate.editorWindow)
        delegate.openAtLaunch(arguments: [])
        XCTAssertEqual(delegate.model.fileURL?.path, note.path)
        XCTAssertEqual(delegate.model.engine.text, "from pending url\n")
        assertSingleEditor(delegate)
    }

    @MainActor
    func testWarmFileOpenReusesTheWindow() async throws {
        let fixture = try TempDirectory()
        try fixture.write("warm.md", "opened later\n")
        let note = fixture.url.appendingPathComponent("warm.md")
        let delegate = AppDelegate()
        defer { delegate.closeLaunchWindow() }
        delegate.openAtLaunch(arguments: [])
        let window = delegate.editorWindow
        XCTAssertNil(delegate.model.fileURL)
        delegate.application(NSApplication.shared, open: [note])
        let clock = ContinuousClock()
        let start = clock.now
        while delegate.model.engine.text != "opened later\n" {
            if clock.now - start > .seconds(3) {
                XCTFail("warm open did not install the file")
                return
            }
            await Task.yield()
        }
        XCTAssertEqual(delegate.model.fileURL?.path, note.path)
        XCTAssertTrue(delegate.editorWindow === window)
        assertSingleEditor(delegate)
    }

    @MainActor
    func testReopenWithNoVisibleWindowsShowsTheSameEditor() {
        let delegate = AppDelegate()
        defer { delegate.closeLaunchWindow() }
        delegate.openAtLaunch(arguments: [])
        let window = delegate.editorWindow
        window?.orderOut(nil)
        XCTAssertFalse(delegate.applicationShouldHandleReopen(NSApplication.shared, hasVisibleWindows: false))
        XCTAssertTrue(delegate.editorWindow === window)
        assertSingleEditor(delegate)
    }

    @MainActor
    func testConsumeLaunchArgumentsEmptyStaysUntitled() throws {
        let fixture = try TempDirectory()
        let model = AppModel(config: .default, home: fixture.url, isDark: { false })
        model.consumeLaunchArguments([], immediate: true)
        XCTAssertNil(model.fileURL)
        XCTAssertEqual(model.document.kind, .untitled)
        XCTAssertEqual(model.engine.text, "")
    }

    @MainActor
    func testConsumeLaunchArgumentsOpensTheLastFile() throws {
        let fixture = try TempDirectory()
        try fixture.write("first.md", "one\n")
        try fixture.write("second.md", "two\n")
        let first = fixture.url.appendingPathComponent("first.md")
        let second = fixture.url.appendingPathComponent("second.md")
        let model = AppModel(config: .default, home: fixture.url, isDark: { false })
        model.consumeLaunchArguments([first.path, second.path], immediate: true)
        XCTAssertEqual(model.fileURL?.path, second.path)
        XCTAssertEqual(model.engine.text, "two\n")
    }

    @MainActor
    private func assertSingleEditor(_ delegate: AppDelegate) {
        XCTAssertNotNil(delegate.editorWindow)
        XCTAssertTrue(delegate.editorWindow?.contentViewController is EditorShell)
        XCTAssertEqual(
            NSApplication.shared.windows.filter { $0 === delegate.editorWindow }.count,
            1
        )
    }
}
