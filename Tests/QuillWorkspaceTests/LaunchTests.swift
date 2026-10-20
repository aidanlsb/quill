import XCTest
@testable import QuillWorkspace

final class LaunchMaterializeTests: XCTestCase {
    func testCreatesMissingFileAndKeepsLocation() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let prepared = try LaunchRequest.prepare(["notes/hello.md:12:3"], cwd: root)
        let path = try XCTUnwrap(prepared.first?.path)
        XCTAssertEqual(prepared, [LaunchTarget(path: path, line: 12, column: 3)])
        XCTAssertTrue(path.hasSuffix("/notes/hello.md"))
        let again = try String(contentsOfFile: path, encoding: .utf8)
        XCTAssertEqual(again, "")
        try "kept\n".write(toFile: path, atomically: true, encoding: .utf8)
        _ = try LaunchRequest.materialize(LaunchTarget(path: "notes/hello.md", line: 4), cwd: root)
        let kept = try String(contentsOfFile: path, encoding: .utf8)
        XCTAssertEqual(kept, "kept\n")
    }

    func testDotStaysADirectory() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let prepared = try LaunchRequest.prepare(["."], cwd: root)
        let resolved = URL(fileURLWithPath: root).resolvingSymlinksInPath().standardizedFileURL.path
        XCTAssertEqual(prepared, [LaunchTarget(path: resolved)])
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: resolved, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
    }

    func testStandaloneFlagIsNotAPath() {
        XCTAssertEqual(
            LaunchRequest.parse(["--quill-socket", "/tmp/q.sock", "--quill-standalone", "note.md:4"]),
            [LaunchTarget(path: "note.md", line: 4)]
        )
    }

    private func temporaryDirectory() -> String {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("quill-launch-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.resolvingSymlinksInPath().standardizedFileURL.path
    }
}

final class InstanceHandoffTests: XCTestCase {
    func testDeliversToTheRunningInstance() throws {
        let (path, server, received) = try startServer()
        defer { server.stop() }
        let target = LaunchTarget(path: "/tmp/note.md", line: 8, column: 2)
        XCTAssertEqual(InstanceClient.send([target], socket: path), .delivered)
        XCTAssertEqual(InstanceClient.send([LaunchTarget(path: "/tmp/other.md")], socket: path), .delivered)
        XCTAssertEqual(received(), [[target], [LaunchTarget(path: "/tmp/other.md")]])
    }

    func testMissingServerIsNotRunning() {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("quill-absent-\(UUID().uuidString).sock").path
        XCTAssertEqual(InstanceClient.send([LaunchTarget(path: "/tmp/a.md")], socket: path), .notRunning)
    }

    func testRejectsABadMessageAndKeepsListening() throws {
        let (path, server, received) = try startServer()
        defer { server.stop() }
        XCTAssertEqual(InstanceClient.exchange("{\"v\":2,\"targets\":[]}\n", socket: path), "no-decode")
        let target = LaunchTarget(path: "/tmp/note.md")
        XCTAssertEqual(InstanceClient.send([target], socket: path), .delivered)
        XCTAssertEqual(received(), [[target]])
    }

    func testClaimHandsOffToThePrimary() throws {
        let path = socketPath()
        let box = Received()
        let primary = InstanceBridge.claim(socket: path, targets: [], onMessage: { box.add($0) })
        guard case .primary(let server) = primary else {
            XCTFail("expected to own the socket")
            return
        }
        defer { server.stop() }
        let target = LaunchTarget(path: "/tmp/handed.md", line: 3)
        let second = Received()
        let secondary = InstanceBridge.claim(socket: path, targets: [target], onMessage: { second.add($0) })
        if case .delivered = secondary {
        } else {
            XCTFail("expected the second claim to deliver")
        }
        XCTAssertEqual(second.snapshot(), [])
        XCTAssertEqual(box.snapshot(), [[target]])
    }

    func testStaleSocketIsReplaced() throws {
        let path = socketPath()
        let first = try XCTUnwrap(InstanceServer.start(path: path, onMessage: { _ in }))
        first.stop(unlinkSocket: false)
        XCTAssertEqual(InstanceClient.send([], socket: path), .notRunning)
        let box = Received()
        let claim = InstanceBridge.claim(socket: path, targets: [], onMessage: { box.add($0) })
        guard case .primary(let server) = claim else {
            XCTFail("stale socket was not replaced")
            return
        }
        defer { server.stop() }
        let target = LaunchTarget(path: "/tmp/fresh.md")
        XCTAssertEqual(InstanceClient.send([target], socket: path), .delivered)
        XCTAssertEqual(box.snapshot(), [[target]])
    }

    func testSocketOverride() {
        XCTAssertEqual(InstanceSocket.path(environment: ["QUILL_SOCKET": "/tmp/custom.sock"]), "/tmp/custom.sock")
    }

    private func startServer() throws -> (String, InstanceServer, () -> [[LaunchTarget]]) {
        let path = socketPath()
        let box = Received()
        let server = try XCTUnwrap(InstanceServer.start(path: path, onMessage: { box.add($0) }))
        return (path, server, { box.snapshot() })
    }

    private func socketPath() -> String {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("quill-\(UUID().uuidString).sock").path
    }
}

/// Test double. The handoff thread and the test thread both touch the list.
// quill-concurrency: NSLock guards targets delivered from the accept thread.
private final class Received: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [[LaunchTarget]] = []

    func add(_ targets: [LaunchTarget]) {
        lock.lock()
        values.append(targets)
        lock.unlock()
    }

    func snapshot() -> [[LaunchTarget]] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }
}

final class QuillCommandTests: XCTestCase {
    func testHandoffDoesNotOpen() throws {
        let root = try bundle()
        defer { try? FileManager.default.removeItem(atPath: root) }
        var opened = 0
        let code = QuillCommand.run(
            arguments: ["note.md"],
            environment: ["QUILL_APP": app(root), "HOME": root],
            cwd: root,
            send: { targets in
                XCTAssertEqual(targets.map(\.path), [root + "/note.md"])
                return .delivered
            },
            openApp: { _, _, _ in
                opened += 1
                return 0
            }
        )
        XCTAssertEqual(code, 0)
        XCTAssertEqual(opened, 0)
    }

    func testColdLaunchUsesOpenAndPassesTheSocket() throws {
        let root = try bundle()
        defer { try? FileManager.default.removeItem(atPath: root) }
        var openedApp = ""
        var urls: [String] = []
        var waited = true
        let code = QuillCommand.run(
            arguments: ["note.md:2"],
            environment: [
                "QUILL_APP": app(root),
                "QUILL_SOCKET": "/tmp/q.sock",
            ],
            cwd: root,
            send: { _ in .notRunning },
            openApp: { app, arguments, wait in
                openedApp = app
                urls = arguments
                waited = wait
                return 0
            }
        )
        XCTAssertEqual(code, 0)
        XCTAssertFalse(waited)
        XCTAssertEqual(openedApp, app(root))
        XCTAssertEqual(Array(urls.prefix(2)), ["--quill-socket", "/tmp/q.sock"])
        XCTAssertTrue(urls.last?.contains("line=2") == true)
    }

    func testMissingBundleUsesOpen() {
        var opened = ""
        let code = QuillCommand.run(
            arguments: [],
            environment: ["QUILL_APP": "/no/such/Quill.app"],
            cwd: "/tmp",
            send: { _ in .notRunning },
            openApp: { app, urls, wait in
                opened = app
                XCTAssertTrue(urls.isEmpty)
                XCTAssertFalse(wait)
                return 7
            }
        )
        XCTAssertEqual(code, 7)
        XCTAssertEqual(opened, "/no/such/Quill.app")
    }

    func testRejectedHandoffDoesNotOpen() throws {
        let root = try bundle()
        defer { try? FileManager.default.removeItem(atPath: root) }
        var opened = false
        let code = QuillCommand.run(
            arguments: ["note.md"],
            environment: ["QUILL_APP": app(root)],
            cwd: root,
            send: { _ in .failed },
            openApp: { _, _, _ in
                opened = true
                return 0
            }
        )
        XCTAssertEqual(code, 1)
        XCTAssertFalse(opened)
    }

    func testWaitOpensANewInstanceAndDoesNotHandOff() throws {
        let root = try bundle()
        defer { try? FileManager.default.removeItem(atPath: root) }
        var sent = false
        var waited = false
        let code = QuillCommand.run(
            arguments: ["--wait", "note.md"],
            environment: ["QUILL_APP": app(root), "QUILL_SOCKET": "/tmp/q.sock"],
            cwd: root,
            send: { _ in
                sent = true
                return .delivered
            },
            openApp: { _, urls, wait in
                waited = wait
                XCTAssertFalse(urls.contains("--quill-socket"))
                return 0
            }
        )
        XCTAssertEqual(code, 0)
        XCTAssertFalse(sent)
        XCTAssertTrue(waited)
    }

    private func bundle() throws -> String {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("quill-cmd-\(UUID().uuidString)").path
        let binary = app(root) + "/Contents/MacOS/Quill"
        try FileManager.default.createDirectory(atPath: (binary as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        XCTAssertTrue(FileManager.default.createFile(atPath: binary, contents: Data()))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary)
        return URL(fileURLWithPath: root).resolvingSymlinksInPath().standardizedFileURL.path
    }

    private func app(_ root: String) -> String {
        root + "/Quill.app"
    }
}
