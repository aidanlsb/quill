import XCTest
@testable import QuillLSP

final class DocumentLifecycleTests: XCTestCase {
    func testReopenSendsDidCloseThenDidOpenAtVersionOne() throws {
        let transport = ScriptedTransport()
        // quill-concurrency: notifications are recorded on the calling thread; the array is only read after they return.
        let log = NotifyLog()
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
        try client.attach(session: JSONRPCSession(transport: transport), rootURI: "file:///tmp")

        let session = LSPDocumentSession(uri: "file:///tmp/a.md", text: "hello", version: 1)
        session.bind(client, languageId: "markdown", reopen: false)
        session.apply(edits: [(0..<0, "!")])
        session.flush()
        session.close()

        let again = LSPDocumentSession(uri: "file:///tmp/a.md", text: "hello!", version: 1)
        again.bind(client, languageId: "markdown", reopen: false)

        XCTAssertEqual(log.methods, [
            "textDocument/didOpen",
            "textDocument/didChange",
            "textDocument/didClose",
            "textDocument/didOpen",
        ])
        XCTAssertEqual(log.versions, [1, 2, -1, 1])
        client.stop()
    }

    func testDiagnosticsFanOutByURI() async {
        let manager = LanguageServerManager()
        // quill-concurrency: handlers run on the manager; the counters are plain ints with no shared mutation besides these calls.
        let tally = Tally()
        await manager.setHandlers(uri: "file:///a.md", diagnostics: { _ in tally.mark("a") }, applyEdit: { _ in })
        await manager.setHandlers(uri: "file:///b.md", diagnostics: { _ in tally.mark("b") }, applyEdit: { _ in })
        await manager.deliverDiagnostics(uri: "file:///a.md", diagnostics: [])
        await manager.deliverDiagnostics(uri: "file:///a.md", diagnostics: [])
        await manager.deliverDiagnostics(uri: "file:///b.md", diagnostics: [])
        XCTAssertEqual(tally.count("a"), 2)
        XCTAssertEqual(tally.count("b"), 1)

        await manager.removeHandlers(uri: "file:///a.md")
        await manager.deliverDiagnostics(uri: "file:///a.md", diagnostics: [])
        XCTAssertEqual(tally.count("a"), 2)
    }
}

// quill-concurrency: test double filled on the JSON-RPC caller and read after that call returns.
private final class NotifyLog: @unchecked Sendable {
    private var stored: [(String, Int)] = []

    func add(method: String, version: Int) {
        stored.append((method, version))
    }

    var methods: [String] { stored.map(\.0) }
    var versions: [Int] { stored.map(\.1) }
}

// quill-concurrency: the actor calls these handlers one at a time; the dictionary is not shared with another thread.
private final class Tally: @unchecked Sendable {
    private var values: [String: Int] = [:]

    func mark(_ key: String) { values[key, default: 0] += 1 }
    func count(_ key: String) -> Int { values[key] ?? 0 }
}
