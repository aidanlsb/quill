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

        client.stop()
    }

    func testMissingServerIsUnavailable() {
        let client = LSPClient(config: LSPServerConfig(name: "nope", command: "quill-lsp-not-installed-xyz"))
        XCTAssertThrowsError(try client.start(root: URL(fileURLWithPath: "/tmp"))) { error in
            guard let rpc = error as? JSONRPCError, case .serverUnavailable = rpc else {
                return XCTFail("expected unavailable, got \(error)")
            }
        }
    }

    func testPositionConversion() {
        let text = "ab\ncafé"
        let pos = LSPPosition.utf16(in: text, characterOffset: 5)
        XCTAssertEqual(pos.line, 1)
        let back = LSPPosition.characterOffset(in: text, position: pos)
        XCTAssertEqual(back, 5)
    }
}
