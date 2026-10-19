import AppKit
import QuillLSP
import QuillVim
import XCTest
@testable import Quill

/// Late opens, reloads, pickers, and language-server results must not land on a buffer the user has left.
@MainActor
final class DocumentModelTests: XCTestCase {
    func testOpenRaceKeepsTheNewerFile() async throws {
        let root = try makeRoot()
        let first = root.appendingPathComponent("a.md")
        let second = root.appendingPathComponent("b.md")
        try Data("alpha\n".utf8).write(to: first)
        try Data("beta\n".utf8).write(to: second)
        let model = AppModel(config: .default, home: root, isDark: { false })
        // quill-concurrency: the open task and the test share one flag; both run on the main actor.
        let gate = Gate()
        model.document.readFile = { url in
            if url.lastPathComponent == "a.md" {
                gate.started = true
                while !gate.go { await Task.yield() }
            }
            return try Data(contentsOf: url)
        }
        model.open(url: first)
        await waitUntil("a did not start reading") { gate.started }
        model.open(url: second)
        await waitUntil("b did not install") { model.engine.text == "beta\n" }
        let generation = model.document.generation
        gate.go = true
        for _ in 0..<30 { await Task.yield() }
        XCTAssertEqual(model.engine.text, "beta\n")
        XCTAssertEqual(model.document.generation, generation)
        XCTAssertEqual(model.fileURL?.lastPathComponent, "b.md")
    }

    func testReloadWithoutAPathAndASupersededReload() async throws {
        let root = try makeRoot()
        let note = root.appendingPathComponent("note.md")
        let other = root.appendingPathComponent("other.md")
        try Data("hello\n".utf8).write(to: note)
        try Data("other\n".utf8).write(to: other)
        let model = AppModel(config: .default, home: root, isDark: { false })
        model.edit(CommandArgs())
        XCTAssertEqual(model.message, "No file")

        model.open(url: note)
        await waitUntil("open") { model.engine.text == "hello\n" }
        try Data("changed\n".utf8).write(to: note)
        model.edit(CommandArgs())
        await waitUntil("reload") { model.engine.text == "changed\n" }
        XCTAssertEqual(model.message, "Reloaded")

        // quill-concurrency: the reload task and the test share one flag; both run on the main actor.
        let gate = Gate()
        model.document.readFile = { url in
            if url.lastPathComponent == "note.md" {
                gate.started = true
                while !gate.go { await Task.yield() }
            }
            return try Data(contentsOf: url)
        }
        model.message = ""
        model.edit(CommandArgs(bang: true))
        await waitUntil("reload started") { gate.started }
        model.open(url: other)
        await waitUntil("other installed") { model.engine.text == "other\n" }
        gate.go = true
        for _ in 0..<30 { await Task.yield() }
        XCTAssertEqual(model.engine.text, "other\n")
        XCTAssertNotEqual(model.message, "Reloaded")
    }

    func testEscapeBeforeTheIndexPreventsTheFilePicker() async throws {
        let root = try makeRoot()
        try Data("\n".utf8).write(to: root.appendingPathComponent("note.md"))
        let model = AppModel(config: .default, home: root, isDark: { false })
        // quill-concurrency: the index task and the test share one flag on the main actor.
        let gate = Gate()
        model.session.search.beforeIndex = {
            gate.started = true
            while !gate.go { await Task.yield() }
        }
        model.presentFilePicker()
        await waitUntil("index did not start") { gate.started }
        _ = model.handleCompletionKey(KeyEvent(.escape))
        gate.go = true
        for _ in 0..<40 { await Task.yield() }
        XCTAssertNil(model.picker)
    }

    func testDismissedPickerIgnoresALatePreview() async throws {
        let root = try makeRoot()
        try Data("body\n".utf8).write(to: root.appendingPathComponent("note.md"))
        let model = AppModel(config: .default, home: root, isDark: { false })
        // quill-concurrency: the preview task and the test share one flag on the main actor.
        let gate = Gate()
        model.session.search.readPreview = { _ in
            gate.started = true
            while !gate.go { await Task.yield() }
            return "OLD"
        }
        model.presentFilePicker()
        await waitUntil("preview did not start") { gate.started }
        XCTAssertNotNil(model.picker)
        model.handlePicker(.escape)
        XCTAssertNil(model.picker)
        gate.go = true
        for _ in 0..<30 { await Task.yield() }
        XCTAssertNil(model.picker)
    }

    func testReopenSendsDidCloseBeforeDidOpen() async throws {
        let root = try makeRoot()
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".git"), withIntermediateDirectories: true)
        let first = root.appendingPathComponent("a.md")
        let second = root.appendingPathComponent("b.md")
        try Data("alpha\n".utf8).write(to: first)
        try Data("beta\n".utf8).write(to: second)
        var config = QuillConfig.default
        config.lsp = LSPSettings(servers: [LSPServerConfig(name: "mock", command: "false", rootMarkers: [".git"])])
        let model = AppModel(config: config, home: root, notice: nil, isDark: { false })
        // quill-concurrency: JSON-RPC records notifications on its caller; the test reads them on the main actor.
        let log = NotifyLog()
        let transport = ScriptedTransport()
        transport.onNotify = { method, params in
            guard method.hasPrefix("textDocument/") else { return }
            log.add(method: method, version: params?["textDocument"]?["version"]?.int ?? -1)
        }
        transport.onRequest = { method, _ in
            if method == "initialize" {
                return .object(["capabilities": .object(["textDocumentSync": .number(2)])])
            }
            return .null
        }
        let client = LSPClient(config: LSPServerConfig(name: "mock", command: "false"))
        try client.attach(session: JSONRPCSession(transport: transport), rootURI: root.absoluteString)
        model.useLSPClient { _, _ in client }

        model.open(url: first)
        await waitUntil("didOpen a") { log.methods == ["textDocument/didOpen"] }
        model.open(url: second)
        await waitUntil("didOpen b") { log.methods == ["textDocument/didOpen", "textDocument/didClose", "textDocument/didOpen"] }
        model.open(url: first)
        await waitUntil("reopen a") {
            log.methods == [
                "textDocument/didOpen", "textDocument/didClose", "textDocument/didOpen",
                "textDocument/didClose", "textDocument/didOpen",
            ]
        }
        XCTAssertEqual(log.versions, [1, -1, 1, -1, 1])
        client.stop()
    }

    func testUnsavedCancelDiscardAndSave() async throws {
        let root = try makeRoot()
        let next = root.appendingPathComponent("next.md")
        let later = root.appendingPathComponent("later.md")
        try Data("next\n".utf8).write(to: next)
        try Data("later\n".utf8).write(to: later)
        let model = AppModel(config: .default, home: root, isDark: { false })
        model.engine.applyHostEdit(replacing: 0..<0, with: "dirty")

        model.open(url: next)
        XCTAssertTrue(model.showUnsaved)
        model.cancelNavigation()
        XCTAssertFalse(model.showUnsaved)
        XCTAssertEqual(model.engine.text, "dirty")
        XCTAssertTrue(model.engine.isModified)

        model.open(url: next)
        model.discardAndContinue()
        await waitUntil("discard did not open") { model.engine.text == "next\n" }
        XCTAssertFalse(model.showUnsaved)
        XCTAssertFalse(model.engine.isModified)

        model.engine.applyHostEdit(replacing: 0..<0, with: "x")
        model.open(url: later)
        XCTAssertTrue(model.showUnsaved)
        model.saveAndContinue()
        await waitUntil("save did not continue") { model.engine.text == "later\n" }
        XCTAssertFalse(model.showUnsaved)
        XCTAssertEqual(try String(contentsOf: next, encoding: .utf8), "xnext\n")
    }

    func testApplyCompletionReloadsAStaleView() {
        let model = AppModel(config: .default, home: URL(fileURLWithPath: "/tmp"), isDark: { false })
        let hosted = VimTextView.host(engine: model.engine)
        let view = hosted.view
        model.editor = view
        model.engine.load(text: "[[no")
        _ = model.engine.type("i")
        model.engine.moveCursor(to: model.engine.buffer.count)
        model.applyCompletion("north")
        XCTAssertEqual(model.engine.text, "[[north")
        XCTAssertEqual(view.string, model.engine.text)
        XCTAssertEqual(view.selectedRange().location, model.engine.cursor)
    }

    func testKeyDownMeasuresTheViewThatReceivedIt() {
        let model = AppModel(config: .default, home: URL(fileURLWithPath: "/tmp"), isDark: { false })
        model.engine.load(text: "one\ntwo\n")
        let first = VimTextView.host(engine: model.engine)
        let second = VimTextView.host(engine: model.engine)
        first.view.reload()
        second.view.reload()
        XCTAssertEqual(ObjectIdentifier(model.engine.layout as AnyObject), ObjectIdentifier(second.view.layoutAdapter))
        first.view.press("j")
        XCTAssertEqual(ObjectIdentifier(model.engine.layout as AnyObject), ObjectIdentifier(first.view.layoutAdapter))
        _ = first
        _ = second
    }

    func testBackgroundViewCatchesUpWhenTheBufferChanges() {
        let model = AppModel(config: .default, home: URL(fileURLWithPath: "/tmp"), isDark: { false })
        let editor = VimTextView.host(engine: model.engine).view
        let background = VimTextView.host(engine: model.engine).view
        model.editor = editor
        editor.reload()
        background.reload()
        editor.seenRefresh = model.document.refreshID
        background.seenRefresh = model.document.refreshID
        _ = model.engine.applyHostEdit(replacing: 0..<0, with: "hi")
        model.document.noteEdit()
        let refresh = model.document.refreshID
        editor.syncFromEngine(isEditor: true, refresh: refresh)
        background.syncFromEngine(isEditor: false, refresh: refresh)
        XCTAssertEqual(editor.string, "")
        XCTAssertEqual(background.string, model.engine.text)
    }

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("quill-doc-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func waitUntil(
        _ description: String,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ predicate: @MainActor () -> Bool
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

// quill-concurrency: the suspended read and the test resume it on the main actor.
private final class Gate: @unchecked Sendable {
    var started = false
    var go = false
}

// quill-concurrency: JSON-RPC appends on its caller; the test reads after the hop back to the main actor.
private final class NotifyLog: @unchecked Sendable {
    private var stored: [(String, Int)] = []

    func add(method: String, version: Int) {
        stored.append((method, version))
    }

    var methods: [String] { stored.map(\.0) }
    var versions: [Int] { stored.map(\.1) }
}
