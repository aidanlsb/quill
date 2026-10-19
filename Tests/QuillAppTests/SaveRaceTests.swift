import XCTest
import QuillVim
@testable import Quill

/// Save snapshots a stamp and the bytes, then marks that stamp saved. Edits
/// typed while the write is suspended stay modified, and `:wq` closes only
/// after a save that left the buffer clean.
@MainActor
final class SaveRaceTests: XCTestCase {
    func testTypingDuringSaveStaysModified() async throws {
        let url = try makeFile(named: "note.md", contents: "hello\n")
        let model = AppModel()
        await open(url, contents: "hello\n", in: model)
        insert("!", in: model)
        XCTAssertEqual(model.engine.text, "hello!\n")

        let gate = pauseWrites(of: model)
        model.save()
        insert(" more", in: model)
        XCTAssertEqual(model.engine.text, "hello! more\n")

        await gate.release()
        await waitUntil("save did not finish") { self.text(at: url) == "hello!\n" }
        await Task.yield()
        XCTAssertEqual(model.engine.text, "hello! more\n")
        XCTAssertTrue(model.engine.isModified)
        XCTAssertTrue(model.modified)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "hello!\n")
    }

    func testWriteQuitClosesAfterTheSave() async throws {
        let url = try makeFile(named: "note.md", contents: "hello\n")
        let model = AppModel()
        await open(url, contents: "hello\n", in: model)
        insert("!", in: model)
        let gate = pauseWrites(of: model)

        let result = model.engine.type(":wq<CR>")
        XCTAssertEqual(result.actions, [.writeQuit])
        model.handleEngineResult(result)
        XCTAssertEqual(model.closeRequests, 0, "close ran before the write finished")

        await gate.release()
        await waitUntil("close did not run after the save") { model.closeRequests == 1 }
        XCTAssertFalse(model.engine.isModified)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "hello!\n")
    }

    func testSaveQuitCommandClosesAfterTheSave() async throws {
        let url = try makeFile(named: "note.md", contents: "hello\n")
        let model = AppModel()
        await open(url, contents: "hello\n", in: model)
        insert("!", in: model)
        let gate = pauseWrites(of: model)

        XCTAssertTrue(model.runCommand("file.saveQuit"))
        XCTAssertEqual(model.closeRequests, 0, "close ran before the write finished")

        await gate.release()
        await waitUntil("file.saveQuit did not close after the save") { model.closeRequests == 1 }
        XCTAssertFalse(model.engine.isModified)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "hello!\n")
    }

    func testWriteQuitDoesNotCloseWhenTypingDuringTheSave() async throws {
        let url = try makeFile(named: "note.md", contents: "hello\n")
        let model = AppModel()
        await open(url, contents: "hello\n", in: model)
        insert("!", in: model)
        let gate = pauseWrites(of: model)

        model.handleEngineResult(model.engine.type(":wq<CR>"))
        insert(" more", in: model)
        await gate.release()
        await waitUntil("save did not finish") { self.text(at: url) == "hello!\n" }
        await Task.yield()

        XCTAssertEqual(model.closeRequests, 0)
        XCTAssertTrue(model.engine.isModified)
        XCTAssertEqual(model.engine.text, "hello! more\n")
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "hello!\n")
    }

    func testFailedWriteDoesNotCloseOrMarkSaved() async throws {
        let url = try makeFile(named: "note.md", contents: "hello\n")
        let model = AppModel()
        await open(url, contents: "hello\n", in: model)
        insert("!", in: model)
        let attempted = Flag()
        model.diskWrite = { _, _ in
            await attempted.mark()
            throw CocoaError(.fileWriteUnknown)
        }

        model.handleEngineResult(model.engine.type(":wq<CR>"))
        await attempted.wait()
        await Task.yield()

        XCTAssertEqual(model.closeRequests, 0)
        XCTAssertTrue(model.engine.isModified)
        XCTAssertNotEqual(model.message, "Saved")
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "hello\n")
    }

    func testInFlightSaveDoesNotTouchAReplacementBuffer() async throws {
        let first = try makeFile(named: "a.md", contents: "hello\n")
        let second = try makeFile(named: "b.md", contents: "other\n")
        let model = AppModel()
        await open(first, contents: "hello\n", in: model)
        insert("!", in: model)
        model.engine.markSaved()
        XCTAssertFalse(model.engine.isModified)
        XCTAssertGreaterThan(model.engine.changeStamp, 0)

        let gate = pauseWrites(of: model)
        model.message = ""
        model.save()
        await open(second, contents: "other\n", in: model)
        await gate.release()
        await waitUntil("the in-flight save did not reach disk") {
            self.text(at: first) == "hello!\n"
        }
        await Task.yield()

        XCTAssertEqual(model.engine.text, "other\n")
        XCTAssertFalse(model.engine.isModified)
        XCTAssertFalse(model.modified)
        XCTAssertNotEqual(model.message, "Saved")
        XCTAssertEqual(try String(contentsOf: second, encoding: .utf8), "other\n")
    }

    private func makeFile(named name: String, contents: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("quill-save-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent(name)
        try Data(contents.utf8).write(to: url)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
        }
        return url
    }

    private func open(_ url: URL, contents: String, in model: AppModel) async {
        model.open(url: url)
        let path = url.standardizedFileURL.path
        await waitUntil("open did not install \(url.lastPathComponent)") {
            model.fileURL?.standardizedFileURL.path == path && model.engine.text == contents
        }
    }

    private func insert(_ text: String, in model: AppModel) {
        let end = model.engine.text.hasSuffix("\n") ? model.engine.buffer.count - 1 : model.engine.buffer.count
        model.engine.applyHostEdit(replacing: end..<end, with: text)
    }

    private func pauseWrites(of model: AppModel) -> WriteGate {
        let gate = WriteGate()
        model.diskWrite = { bytes, url in
            await gate.wait()
            try bytes.write(to: url, options: .atomic)
        }
        return gate
    }

    private func text(at url: URL) -> String {
        (try? String(contentsOf: url, encoding: .utf8)) ?? ""
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

private actor WriteGate {
    private var released = false
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        if released { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            if self.released {
                continuation.resume()
                return
            }
            self.continuation = continuation
        }
    }

    func release() {
        released = true
        let continuation = self.continuation
        self.continuation = nil
        continuation?.resume()
    }
}

private actor Flag {
    private var value = false
    private var continuation: CheckedContinuation<Void, Never>?

    func mark() {
        value = true
        let continuation = self.continuation
        self.continuation = nil
        continuation?.resume()
    }

    func wait() async {
        if value { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            if self.value {
                continuation.resume()
                return
            }
            self.continuation = continuation
        }
    }
}
