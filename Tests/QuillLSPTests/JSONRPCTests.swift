import XCTest
@testable import QuillLSP

final class JSONRPCFramerTests: XCTestCase {
    func testRoundTrip() {
        let framer = JSONRPCFramer()
        let payload = Data(#"{"jsonrpc":"2.0","id":1,"method":"initialize"}"#.utf8)
        let framed = framer.encode(payload)
        let messages = framer.append(framed)
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages[0], payload)
    }

    func testSplitChunks() {
        let framer = JSONRPCFramer()
        let payload = Data(#"{"a":1}"#.utf8)
        let framed = JSONRPCFramer().encode(payload)
        let mid = framed.count / 2
        XCTAssertTrue(framer.append(framed.prefix(mid)).isEmpty)
        let rest = framer.append(framed.suffix(from: mid))
        XCTAssertEqual(rest.count, 1)
        XCTAssertEqual(rest[0], payload)
    }

    func testTwoMessages() {
        let framer = JSONRPCFramer()
        let a = Data(#"{"n":1}"#.utf8)
        let b = Data(#"{"n":2}"#.utf8)
        var data = JSONRPCFramer().encode(a)
        data.append(JSONRPCFramer().encode(b))
        XCTAssertEqual(framer.append(data).count, 2)
    }

    func testJSONValueRoundTrip() throws {
        let value = JSONValue.object([
            "ok": .bool(true),
            "n": .number(3),
            "s": .string("hi"),
            "a": .array([.null]),
        ])
        let data = try JSONValue.encode(value)
        let decoded = try JSONValue.decode(data)
        XCTAssertEqual(decoded["s"]?.string, "hi")
        XCTAssertEqual(decoded["ok"]?.bool, true)
        XCTAssertEqual(decoded["n"]?.int, 3)
    }

    func testJSONNumberIsNotBool() throws {
        let decoded = try JSONValue.decode(Data(#"{"id":1,"ok":true,"n":0}"#.utf8))
        XCTAssertEqual(decoded["id"]?.int, 1)
        XCTAssertNil(decoded["id"]?.bool)
        XCTAssertEqual(decoded["ok"]?.bool, true)
        XCTAssertNil(decoded["ok"]?.int)
        XCTAssertEqual(decoded["n"]?.int, 0)
        XCTAssertNil(decoded["n"]?.bool)
    }
}

final class MemoryTransportTests: XCTestCase {
    func testPairSameThread() throws {
        let (a, b) = MemoryTransport.makePair()
        try a.write(Data([1, 2, 3]))
        XCTAssertEqual(try b.readSome(), Data([1, 2, 3]))
    }
}

final class JSONRPCSessionTests: XCTestCase {
    func testRequestResponse() throws {
        let (clientEnd, serverEnd) = MemoryTransport.makePair()
        let client = JSONRPCSession(transport: clientEnd)
        let server = JSONRPCSession(transport: serverEnd)
        server.onServerRequest = { _, method, params in
            XCTAssertEqual(method, "ping")
            XCTAssertEqual(params?["x"]?.int, 3)
            return .object(["ok": .bool(true)])
        }
        server.startReading()
        client.startReading()
        let result = try client.request(method: "ping", params: .object(["x": .number(3)]))
        XCTAssertEqual(result["ok"]?.bool, true)
        client.close()
        server.close()
    }

    func testScriptedTransportPing() throws {
        let transport = ScriptedTransport()
        transport.onRequest = { method, params in
            XCTAssertEqual(method, "ping")
            XCTAssertEqual(params?["x"]?.int, 3)
            return .object(["ok": .bool(true)])
        }
        let client = JSONRPCSession(transport: transport)
        client.startReading()
        let result = try client.request(method: "ping", params: .object(["x": .number(3)]))
        XCTAssertEqual(result["ok"]?.bool, true)
        client.close()
    }
}

final class LSPClientTests: XCTestCase {
    func testInitializeDidOpenCompletionDefinitionHoverDiagnostics() throws {
        let transport = ScriptedTransport()
        var opened = false
        var changed = false
        var saved = false
        transport.onRequest = { method, _ in
            switch method {
            case "initialize":
                return .object([
                    "capabilities": .object([
                        "hoverProvider": .bool(true),
                        "completionProvider": .object([:]),
                        "definitionProvider": .bool(true),
                    ]),
                ])
            case "textDocument/completion":
                return .object([
                    "items": .array([
                        .object(["label": .string("wikilink"), "insertText": .string("note-name")]),
                    ]),
                ])
            case "textDocument/definition":
                return .object([
                    "uri": .string("file:///tmp/note.md"),
                    "range": .object([
                        "start": .object(["line": .number(0), "character": .number(0)]),
                        "end": .object(["line": .number(0), "character": .number(1)]),
                    ]),
                ])
            case "textDocument/hover":
                return .object([
                    "contents": .object(["kind": .string("markdown"), "value": .string("A note")]),
                ])
            default:
                return .null
            }
        }
        transport.onNotify = { method, _ in
            if method == "textDocument/didOpen" { opened = true }
            if method == "textDocument/didChange" { changed = true }
            if method == "textDocument/didSave" { saved = true }
            if method == "initialized" {
                try? transport.pushNotification(
                    method: "textDocument/publishDiagnostics",
                    params: .object([
                        "uri": .string("file:///tmp/doc.md"),
                        "diagnostics": .array([
                            .object([
                                "range": .object([
                                    "start": .object(["line": .number(1), "character": .number(0)]),
                                    "end": .object(["line": .number(1), "character": .number(2)]),
                                ]),
                                "severity": .number(2),
                                "message": .string("unknown field"),
                                "code": .string("unknown_field"),
                            ]),
                        ]),
                    ])
                )
            }
        }

        let session = JSONRPCSession(transport: transport)
        let client = LSPClient(config: LSPServerConfig(name: "mock", command: "false"))
        let diag = expectation(description: "diagnostics")
        var received: [Diagnostic] = []
        client.onDiagnostics = { _, list in
            received = list
            diag.fulfill()
        }
        try client.attach(session: session, rootURI: "file:///tmp")

        wait(for: [diag], timeout: 2)
        XCTAssertEqual(received.count, 1)
        XCTAssertEqual(received.first?.message, "unknown field")
        XCTAssertEqual(received.first?.code, "unknown_field")

        client.didOpen(uri: "file:///tmp/doc.md", languageId: "markdown", version: 1, text: "# Hi\n")
        XCTAssertTrue(opened)

        client.didChange(uri: "file:///tmp/doc.md", version: 2, text: "# Hello\n")
        client.didSave(uri: "file:///tmp/doc.md", text: "# Hello\n")
        XCTAssertTrue(changed)
        XCTAssertTrue(saved)

        let items = try client.completion(uri: "file:///tmp/doc.md", position: LSPPosition(line: 0, character: 2))
        XCTAssertEqual(items.map(\.label), ["wikilink"])
        XCTAssertEqual(items.first?.insertText, "note-name")

        let locs = try client.definition(uri: "file:///tmp/doc.md", position: LSPPosition(line: 0, character: 0))
        XCTAssertEqual(locs.first?.uri, "file:///tmp/note.md")

        let hover = try client.hover(uri: "file:///tmp/doc.md", position: LSPPosition(line: 0, character: 0))
        XCTAssertEqual(hover?.contents, "A note")

        XCTAssertTrue(client.capabilities.hoverProvider)
        XCTAssertTrue(client.capabilities.completionProvider)
        XCTAssertTrue(client.capabilities.definitionProvider)
        client.stop()
    }

    func testMethodNotFoundAndStringRequestID() throws {
        let (clientEnd, serverEnd) = MemoryTransport.makePair()
        let client = JSONRPCSession(transport: clientEnd)
        client.onServerRequest = { id, method, _ in
            XCTAssertEqual(id, .string("abc"))
            XCTAssertEqual(method, "custom/x")
            return .string("pong")
        }
        client.startReading()
        let payload = Data(#"{"jsonrpc":"2.0","id":"abc","method":"custom/x"}"#.utf8)
        try serverEnd.write(JSONRPCFramer().encode(payload))
        guard let framed = try serverEnd.readSome(),
              let body = JSONRPCFramer().append(framed).first,
              let value = try? JSONValue.decode(body) else {
            return XCTFail("missing reply")
        }
        XCTAssertEqual(value["id"]?.string, "abc")
        XCTAssertEqual(value["result"]?.string, "pong")

        client.onServerRequest = { _, _, _ in nil }
        let unknown = Data(#"{"jsonrpc":"2.0","id":7,"method":"nope"}"#.utf8)
        try serverEnd.write(JSONRPCFramer().encode(unknown))
        guard let framed2 = try serverEnd.readSome(),
              let body2 = JSONRPCFramer().append(framed2).first,
              let err = try? JSONValue.decode(body2) else {
            return XCTFail("missing error")
        }
        XCTAssertEqual(err["error"]?.object?["code"]?.int, -32601)
        client.close()
        serverEnd.close()
    }

    func testIncrementalSyncAndMissingEnv() throws {
        var sync = DocumentSync(text: "one two", version: 1)
        sync.apply(edits: [(0..<3, "ONE")])
        let flushed = sync.flush(incremental: true)
        XCTAssertEqual(flushed.version, 2)
        XCTAssertEqual(flushed.changes.count, 1)
        XCTAssertEqual(flushed.changes[0].text, "ONE")
        XCTAssertEqual(flushed.changes[0].range?.start.character, 0)
        XCTAssertEqual(flushed.changes[0].range?.end.character, 3)
        XCTAssertEqual(sync.text, "ONE two")

        var full = DocumentSync(text: "ab", version: 1)
        full.apply(edits: [(2..<2, "c")])
        let whole = full.flush(incremental: false)
        XCTAssertEqual(whole.changes.first?.text, "abc")
        XCTAssertNil(whole.changes.first?.range)

        let json = Data(#"{"servers":[{"name":"m","command":"marksman"}]}"#.utf8)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("quill-lsp-\(UUID().uuidString).json")
        try json.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let loaded = LSPSettings.loadReporting(from: url)
        XCTAssertNil(loaded.error)
        XCTAssertEqual(loaded.settings.servers.first?.env, [:])
        XCTAssertEqual(loaded.settings.servers.first?.languages, ["markdown"])

        let emoji = "a😀b"
        let pos = LSPPosition.position(utf16Offset: 3, in: emoji)
        XCTAssertEqual(pos.line, 0)
        XCTAssertEqual(pos.character, 3)
        XCTAssertEqual(LSPPosition.utf16Offset(in: emoji, position: pos), 3)
    }

    func testServerIsReusedUntilItCrashes() async throws {
        let manager = LanguageServerManager()
        let client = LSPClient(config: LSPServerConfig(name: "mock", command: "false"))
        let key = await manager.adopt(client, root: URL(fileURLWithPath: "/tmp/notes"))
        await manager.trackOpen(key: key, uri: "file:///tmp/notes/a.md")
        let open = await manager.isOpen(key: key, uri: "file:///tmp/notes/a.md")
        XCTAssertTrue(open)
        let again = await manager.client(key)
        XCTAssertTrue(again === client)
        await manager.noteCrash(key)
        let first = await manager.restartDelay(key)
        XCTAssertEqual(first, 0.25)
        await manager.noteCrash(key)
        let second = await manager.restartDelay(key)
        XCTAssertEqual(second, 0.5)
    }

    func testMissingServerIsUnavailable() {
        let client = LSPClient(config: LSPServerConfig(name: "nope", command: "quill-lsp-not-installed-xyz"))
        XCTAssertThrowsError(try client.start(root: URL(fileURLWithPath: "/tmp"))) { error in
            guard let rpc = error as? JSONRPCError, case .serverUnavailable = rpc else {
                return XCTFail("expected unavailable, got \(error)")
            }
        }
    }

    func testReferencesCodeActionAndApplyEdit() async throws {
        let transport = ScriptedTransport()
        transport.onRequest = { method, params in
            switch method {
            case "initialize":
                let textDocument = params?["capabilities"]?.object?["textDocument"]?.object
                XCTAssertNotNil(textDocument?["references"])
                XCTAssertNotNil(textDocument?["codeAction"])
                XCTAssertEqual(params?["capabilities"]?.object?["workspace"]?.object?["applyEdit"]?.bool, true)
                return .object(["capabilities": .object([:])])
            case "textDocument/references":
                XCTAssertEqual(params?["context"]?.object?["includeDeclaration"]?.bool, true)
                XCTAssertEqual(params?["position"]?.object?["line"]?.int, 1)
                XCTAssertEqual(params?["textDocument"]?.object?["uri"]?.string, "file:///tmp/note.md")
                return .array([
                    .object([
                        "uri": .string("file:///tmp/note.md"),
                        "range": .object([
                            "start": .object(["line": .number(4), "character": .number(2)]),
                            "end": .object(["line": .number(4), "character": .number(5)]),
                        ]),
                    ]),
                ])
            case "textDocument/codeAction":
                XCTAssertEqual(params?["range"]?.object?["start"]?.object?["line"]?.int, 0)
                XCTAssertEqual(params?["context"]?.object?["diagnostics"]?.array?.count, 1)
                return .array([
                    .object([
                        "title": .string("Fix"),
                        "kind": .string("quickfix"),
                        "isPreferred": .bool(true),
                        "edit": .object([
                            "changes": .object([
                                "file:///tmp/note.md": .array([
                                    .object([
                                        "range": .object([
                                            "start": .object(["line": .number(0), "character": .number(0)]),
                                            "end": .object(["line": .number(0), "character": .number(1)]),
                                        ]),
                                        "newText": .string("Z"),
                                    ]),
                                ]),
                            ]),
                        ]),
                        "command": .object([
                            "title": .string("Fix"),
                            "command": .string("mock.fix"),
                            "arguments": .array([.string("a")]),
                        ]),
                    ]),
                    .object([
                        "title": .string("Run"),
                        "command": .string("mock.run"),
                    ]),
                ])
            case "workspace/executeCommand":
                XCTAssertEqual(params?["command"]?.string, "mock.fix")
                XCTAssertEqual(params?["arguments"]?.array?.first?.string, "a")
                return .null
            default:
                return .null
            }
        }

        let session = JSONRPCSession(transport: transport)
        let client = LSPClient(config: LSPServerConfig(name: "mock", command: "false"))
        try client.attach(session: session, rootURI: "file:///tmp")

        let refs = try await client.references(uri: "file:///tmp/note.md", position: LSPPosition(line: 1, character: 0))
        XCTAssertEqual(refs.count, 1)
        XCTAssertEqual(refs[0].uri, "file:///tmp/note.md")
        XCTAssertEqual(refs[0].range.start.line, 4)
        XCTAssertEqual(refs[0].range.start.character, 2)

        let diag = Diagnostic(
            range: LSPRange(start: LSPPosition(line: 0, character: 0), end: LSPPosition(line: 0, character: 1)),
            severity: 1,
            message: "tidy"
        )
        let actions = try await client.codeAction(
            uri: "file:///tmp/note.md",
            range: LSPRange(start: LSPPosition(line: 0, character: 0), end: LSPPosition(line: 0, character: 0)),
            diagnostics: [diag]
        )
        XCTAssertEqual(actions.map(\.title), ["Fix", "Run"])
        XCTAssertEqual(actions[0].command?.command, "mock.fix")
        XCTAssertEqual(actions[1].command?.command, "mock.run")
        XCTAssertNil(actions[1].edit)
        let file = URL(fileURLWithPath: "/tmp/note.md")
        let edits = actions[0].edit?.bufferEdits(in: "abc\n", file: file) ?? []
        XCTAssertEqual(edits, [BufferEdit(range: 0..<1, replacement: "Z")])

        let executed = try await client.executeCommand(command: "mock.fix", arguments: .array([.string("a")]))
        XCTAssertEqual(executed, .null)

        let applied = expectation(description: "applyEdit")
        client.onApplyEdit = { edit in
            let got = edit.bufferEdits(in: "abc\n", file: file)
            XCTAssertEqual(got, [BufferEdit(range: 0..<1, replacement: "Q")])
            XCTAssertTrue(edit.containsEdits(outside: URL(fileURLWithPath: "/tmp/other.md")))
            applied.fulfill()
        }
        try transport.pushRequest(method: "workspace/applyEdit", params: .object([
            "edit": .object([
                "documentChanges": .array([
                    .object([
                        "textDocument": .object(["uri": .string("file:///tmp/note.md")]),
                        "edits": .array([
                            .object([
                                "range": .object([
                                    "start": .object(["line": .number(0), "character": .number(0)]),
                                    "end": .object(["line": .number(0), "character": .number(1)]),
                                ]),
                                "newText": .string("Q"),
                            ]),
                        ]),
                    ]),
                    .object(["kind": .string("rename"), "oldUri": .string("file:///tmp/a"), "newUri": .string("file:///tmp/b")]),
                ]),
            ]),
        ]))
        await fulfillment(of: [applied], timeout: 2)
        client.stop()
    }

    func testWorkspaceEditAppliesEndToStart() {
        let text = "aaa\nbbb\nccc"
        let edit = WorkspaceEdit.parse(.object([
            "changes": .object([
                "file:///tmp/note.md": .array([
                    .object([
                        "range": .object([
                            "start": .object(["line": .number(0), "character": .number(0)]),
                            "end": .object(["line": .number(0), "character": .number(3)]),
                        ]),
                        "newText": .string("AAA"),
                    ]),
                    .object([
                        "range": .object([
                            "start": .object(["line": .number(2), "character": .number(0)]),
                            "end": .object(["line": .number(2), "character": .number(3)]),
                        ]),
                        "newText": .string("CCC"),
                    ]),
                ]),
            ]),
        ]))
        let file = URL(fileURLWithPath: "/tmp/note.md")
        XCTAssertEqual(
            edit.bufferEdits(in: text, file: file),
            [
                BufferEdit(range: 8..<11, replacement: "CCC"),
                BufferEdit(range: 0..<3, replacement: "AAA"),
            ]
        )
        XCTAssertTrue(edit.bufferEdits(in: text, file: URL(fileURLWithPath: "/tmp/other.md")).isEmpty)
        XCTAssertTrue(edit.containsEdits(outside: URL(fileURLWithPath: "/tmp/other.md")))
        XCTAssertFalse(edit.containsEdits(outside: file))
    }

    func testPositionConversion() {
        let text = "ab\ncafé"
        let pos = LSPPosition.utf16(in: text, characterOffset: 5)
        XCTAssertEqual(pos.line, 1)
        let back = LSPPosition.characterOffset(in: text, position: pos)
        XCTAssertEqual(back, 5)
    }
}
