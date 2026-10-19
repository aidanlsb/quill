import AppKit
import QuillFS
import QuillLSP
import QuillVim
import XCTest
@testable import Quill

/// Host edits, `K`, and completion go through one text view. Nothing here asks
/// for a language server unless a test installs one.
@MainActor
final class EditFunnelTests: XCTestCase {
    private var retained: [AnyObject] = []

    func testHostEditsUpdateTheViewWithoutReload() async throws {
        let url = try makeFile(named: "note.md", contents: "hello\n")
        let model = AppModel()
        let view = attach(model)
        var reloads = 0
        view.onReload = { reloads += 1 }
        await open(url, contents: "hello\n", in: model)
        XCTAssertGreaterThan(reloads, 0)

        model.engine.load(text: "| a | bb |\n| - | -- |\n| c | d |\n")
        view.reload()
        let afterLoad = reloads
        let beforeFormat = view.string
        model.formatTables(startLine: nil, endLine: nil, quiet: true)
        XCTAssertNotEqual(view.string, beforeFormat)
        XCTAssertEqual(view.string, model.engine.text)
        XCTAssertEqual(view.selectedRange().location, model.engine.cursor)
        XCTAssertEqual(reloads, afterLoad)

        let file = try XCTUnwrap(model.fileURL)
        let edit = WorkspaceEdit(changes: [
            file.absoluteString: [
                LSPTextEdit(
                    range: LSPRange(
                        start: LSPPosition(line: 0, character: 0),
                        end: LSPPosition(line: 0, character: 0)
                    ),
                    newText: "!"
                ),
            ],
        ])
        model.applyWorkspaceEdit(edit)
        XCTAssertTrue(model.engine.text.hasPrefix("!"))
        XCTAssertEqual(view.string, model.engine.text)
        XCTAssertEqual(view.selectedRange().location, model.engine.cursor)
        XCTAssertEqual(reloads, afterLoad)

        model.engine.load(text: "[[no")
        model.engine.type("i")
        model.engine.moveCursor(to: model.engine.buffer.count)
        view.reload()
        let afterLink = reloads
        model.applyCompletion("north")
        XCTAssertEqual(model.engine.text, "[[north")
        XCTAssertEqual(view.string, model.engine.text)
        XCTAssertTrue(model.completions.isEmpty)
        XCTAssertEqual(reloads, afterLink)

        model.engine.load(text: "one\ntwo\nthree\n")
        view.reload()
        let afterLines = reloads
        model.jumpToLine(3, column: 2)
        XCTAssertEqual(model.engine.cursor, model.engine.buffer.offset(line: 2, graphemeColumn: 1))
        XCTAssertEqual(view.string, model.engine.text)
        XCTAssertEqual(view.selectedRange().location, model.engine.cursor)
        XCTAssertEqual(reloads, afterLines)
    }

    func testTypingWithoutAServerDoesNotCreateALink() {
        let before = LSPLink.creationCount
        let model = AppModel()
        let view = attach(model)
        view.keyDown(with: key("i"))
        for _ in 0..<100 {
            view.keyDown(with: key("a"))
        }
        XCTAssertEqual(model.engine.text, String(repeating: "a", count: 100))
        XCTAssertEqual(view.string, model.engine.text)
        XCTAssertFalse(model.hasLanguageServer)
        XCTAssertEqual(LSPLink.creationCount, before)
    }

    func testShowHoverUsesDiagnosticsThenNothing() {
        let model = AppModel()
        model.engine.load(text: "hello\n")
        model.diagnostics = [
            Diagnostic(
                range: LSPRange(
                    start: LSPPosition(line: 0, character: 0),
                    end: LSPPosition(line: 0, character: 5)
                ),
                severity: 1,
                message: "broken link"
            ),
        ]
        XCTAssertEqual(model.diagnosticRanges.count, 1)
        XCTAssertEqual(model.diagnosticRanges[0].0, NSRange(location: 0, length: 5))
        model.showHover()
        XCTAssertEqual(model.message, "broken link")

        model.diagnostics = []
        model.showHover()
        XCTAssertEqual(model.message, "No info")
    }

    func testShowHoverUsesTheFirstHoverLine() async throws {
        let model = AppModel()
        model.engine.load(text: "hello\n")
        let (link, client) = try scriptedLink(text: "hello\n", onRequest: hoverServer)
        model.adoptLanguageLink(link)
        model.showHover()
        await waitUntil("hover did not arrive") { model.message == "Title line" }
        client.stop()
    }

    func testEditsCoalesceIntoOneDidChange() async throws {
        let log = NotifyLog()
        let (link, client) = try scriptedLink(
            text: "",
            onNotify: NotifyLog.record(log),
            onRequest: incrementalServer
        )
        log.methods.removeAll()
        log.changeCounts.removeAll()
        for _ in 0..<10 {
            link.didEdit([TextEdit(range: 0..<0, replacement: "a")])
        }
        link.didSave(text: String(repeating: "a", count: 10))
        for _ in 0..<8 {
            await Task.yield()
        }
        XCTAssertEqual(log.methods, ["textDocument/didChange", "textDocument/didSave"])
        XCTAssertEqual(log.changeCounts, [10])
        client.stop()
    }

    func testKeyboardCompletionAcceptsTheSecondMatch() async throws {
        let root = try makeDirectory()
        try Data("\n".utf8).write(to: root.appendingPathComponent("north.md"))
        try Data("\n".utf8).write(to: root.appendingPathComponent("note.md"))
        let empty = root.appendingPathComponent("empty.md")
        try Data().write(to: empty)

        let model = AppModel()
        let view = attach(model)
        await open(empty, contents: "", in: model)
        view.keyDown(with: key("i"))
        for character in ["[", "[", "n", "o"] {
            view.keyDown(with: key(character))
        }
        await waitUntil("wikilink matches did not arrive") { model.completions.count >= 2 }
        let chosen = model.completions[1]
        view.keyDown(with: key("n", control: true))
        view.keyDown(with: key("n", control: true))
        XCTAssertEqual(model.completionIndex, 1)
        view.keyDown(with: key("y", control: true))
        XCTAssertTrue(model.engine.text.contains(chosen))
        XCTAssertTrue(model.completions.isEmpty)
        XCTAssertEqual(view.string, model.engine.text)
    }

    func testEscapeDismissesCompletionAndLeavesInsert() async throws {
        let model = try await modelWithWikilink()
        let view = model.editor!
        view.keyDown(with: key("escape"))
        XCTAssertTrue(model.completions.isEmpty)
        XCTAssertNotEqual(model.engine.mode, .insert)
        XCTAssertEqual(view.string, model.engine.text)
    }

    func testCtrlEDismissesCompletionAndStaysInInsert() async throws {
        let model = try await modelWithWikilink()
        let view = model.editor!
        view.keyDown(with: key("e", control: true))
        XCTAssertTrue(model.completions.isEmpty)
        XCTAssertEqual(model.engine.mode, .insert)
        XCTAssertEqual(view.string, model.engine.text)
    }

    func testDirectoryMotionInvalidatesRows() {
        let model = AppModel()
        let view = attach(model, frame: NSRect(x: 0, y: 0, width: 420, height: 640))
        var displayed: [NSRect] = []
        view.onNeedsDisplay = { displayed.append($0) }
        let lines = (0..<40).map { "file-\($0).md" }.joined(separator: "\n") + "\n"
        model.engine.load(text: lines)
        view.isDirectoryBuffer = true
        view.directoryURL = URL(fileURLWithPath: "/tmp/notes")
        view.reload()
        mount(view)
        view.layoutAdapter.ensureFullLayout()
        view.layoutSubtreeIfNeeded()
        displayed.removeAll()

        let result = model.engine.handle(KeyEvent(.character("j")))
        view.applyResult(result)
        XCTAssertFalse(displayed.isEmpty)
        XCTAssertTrue(displayed.allSatisfy { rect in
            rect.width < view.bounds.width - 0.5 || rect.height < view.bounds.height - 0.5
        })
    }

    func testDirectoryDrawPaintsGhosts() {
        let model = AppModel()
        let view = attach(model, frame: NSRect(x: 0, y: 0, width: 420, height: 400))
        var drewDecorations = false
        view.onDirectoryDecorations = { drewDecorations = true }
        model.engine.load(text: "a.md\n")
        model.engine.setDirectoryAnchor(line: 0, id: 1, sourcePath: "/tmp/notes/a.md", isDirectory: false)
        view.isDirectoryBuffer = true
        view.directoryURL = URL(fileURLWithPath: "/tmp/notes")
        view.directoryEntries = [
            DirEntry(name: "a.md", isDirectory: false, entryID: 1),
            DirEntry(name: "gone.md", isDirectory: false, entryID: 2),
        ]
        view.invalidateDirectoryStyle()
        XCTAssertFalse(view.currentDirectoryStyle().deleted.isEmpty)
        mount(view)
        let image = NSImage(size: view.bounds.size)
        image.lockFocus()
        view.draw(view.bounds)
        image.unlockFocus()
        XCTAssertTrue(drewDecorations)
    }

    func testWindowChromeAppliesOnFocusNotOnMessage() {
        let model = AppModel()
        let view = attach(model)
        let before = WindowChrome.applyCount
        XCTAssertTrue(syncWindowChrome(
            view: view,
            theme: model.theme,
            themeIdentity: model.themeIdentity,
            focus: model.focusMode,
            directoryChanged: false
        ))
        let appeared = WindowChrome.applyCount
        XCTAssertGreaterThan(appeared, before)
        XCTAssertFalse(syncWindowChrome(
            view: view,
            theme: model.theme,
            themeIdentity: model.themeIdentity,
            focus: model.focusMode,
            directoryChanged: false
        ))
        XCTAssertEqual(WindowChrome.applyCount, appeared)
        XCTAssertTrue(syncWindowChrome(
            view: view,
            theme: model.theme,
            themeIdentity: model.themeIdentity,
            focus: !model.focusMode,
            directoryChanged: false
        ))
        XCTAssertGreaterThan(WindowChrome.applyCount, appeared)
    }

    private func modelWithWikilink() async throws -> AppModel {
        let root = try makeDirectory()
        try Data("\n".utf8).write(to: root.appendingPathComponent("north.md"))
        try Data("\n".utf8).write(to: root.appendingPathComponent("note.md"))
        let empty = root.appendingPathComponent("empty.md")
        try Data().write(to: empty)
        let model = AppModel()
        let view = attach(model)
        await open(empty, contents: "", in: model)
        view.keyDown(with: key("i"))
        for character in ["[", "[", "n", "o"] {
            view.keyDown(with: key(character))
        }
        await waitUntil("wikilink matches did not arrive") { model.completions.count >= 2 }
        return model
    }

    private func attach(
        _ model: AppModel,
        frame: NSRect = NSRect(x: 0, y: 0, width: 480, height: 320)
    ) -> VimTextView {
        let hosted = VimTextView.host(engine: model.engine, frame: frame)
        let view = hosted.view
        retained.append(hosted.scroll)
        model.editor = view
        let delegate = FunnelDelegate(model: model)
        retained.append(delegate)
        view.vimDelegate = delegate
        view.reload()
        return view
    }

    private func mount(_ view: VimTextView) {
        let scroll = NSScrollView(frame: view.frame)
        scroll.documentView = view
        let window = NSWindow(
            contentRect: view.frame,
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.contentView = scroll
        window.makeKeyAndOrderFront(nil)
        retained.append(window)
    }

    private func scriptedLink(
        text: String,
        onNotify: @escaping (String, JSONValue?) -> Void = { _, _ in },
        onRequest: @escaping (String, JSONValue?) -> JSONValue
    ) throws -> (LSPLink, LSPClient) {
        let transport = ScriptedTransport()
        transport.onRequest = onRequest
        transport.onNotify = onNotify
        let session = JSONRPCSession(transport: transport)
        let client = LSPClient(config: LSPServerConfig(name: "mock", command: "false"))
        try client.attach(session: session, rootURI: "file:///tmp")
        let link = LSPLink(uri: "file:///tmp/note.md", text: text, version: 1)
        link.attach([client])
        return (link, client)
    }

    private func key(_ characters: String, control: Bool = false) -> NSEvent {
        let flags: NSEvent.ModifierFlags = control ? .control : []
        let code: UInt16
        if characters == "escape" {
            code = 53
        } else {
            code = 0
        }
        let shown = characters == "escape" ? "\u{1b}" : characters
        return NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: flags,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: shown,
            charactersIgnoringModifiers: characters == "escape" ? shown : characters,
            isARepeat: false,
            keyCode: code
        )!
    }

    private func makeDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("quill-funnel-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
        }
        return root
    }

    private func makeFile(named name: String, contents: String) throws -> URL {
        let root = try makeDirectory()
        let url = root.appendingPathComponent(name)
        try Data(contents.utf8).write(to: url)
        return url
    }

    private func open(_ url: URL, contents: String, in model: AppModel) async {
        model.open(url: url)
        let path = url.standardizedFileURL.path
        await waitUntil("open did not install \(url.lastPathComponent)") {
            model.fileURL?.standardizedFileURL.path == path && model.engine.text == contents
        }
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

/// Notifications arrive on the thread that writes them. The log is only touched from this test.
// quill-concurrency: Scripted JSON-RPC callbacks are synchronous on the caller; the test does not share the log.
private final class NotifyLog: @unchecked Sendable {
    var methods: [String] = []
    var changeCounts: [Int] = []

    nonisolated static func record(_ log: NotifyLog) -> (String, JSONValue?) -> Void {
        { method, params in
            log.methods.append(method)
            if method == "textDocument/didChange" {
                log.changeCounts.append(params?["contentChanges"]?.array?.count ?? -1)
            }
        }
    }
}

private func hoverServer(_ method: String, _: JSONValue?) -> JSONValue {
    switch method {
    case "initialize":
        return .object([
            "capabilities": .object([
                "textDocumentSync": .number(2),
                "hoverProvider": .bool(true),
            ]),
        ])
    case "textDocument/hover":
        return .object([
            "contents": .object([
                "kind": .string("markdown"),
                "value": .string("Title line\nmore"),
            ]),
        ])
    default:
        return .null
    }
}

private func incrementalServer(_ method: String, _: JSONValue?) -> JSONValue {
    if method == "initialize" {
        return .object([
            "capabilities": .object(["textDocumentSync": .number(2)]),
        ])
    }
    return .null
}

private final class FunnelDelegate: NSObject, VimTextViewDelegate {
    let model: AppModel

    init(model: AppModel) {
        self.model = model
    }

    func vimTextView(_ view: VimTextView, didHandle result: EngineResult) {
        model.afterEdit(result)
    }

    func vimTextViewDidClick(_ view: VimTextView, characterOffset: Int, commandClick: Bool) {}

    func vimTextView(_ view: VimTextView, handleCompletionKey key: KeyEvent) -> Bool {
        model.handleCompletionKey(key)
    }
}
