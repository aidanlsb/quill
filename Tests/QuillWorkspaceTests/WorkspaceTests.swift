import XCTest
@testable import QuillWorkspace

final class WorkspaceTests: XCTestCase {
    func testRefuseInvalidUTF8AndKeepCRLF() throws {
        XCTAssertThrowsError(try TextCodec.decode(Data([0xFF, 0xFE, 0x61]))) { error in
            XCTAssertEqual(error as? TextCodec.Failure, .invalidUTF8)
        }
        let decoded = try TextCodec.decode(Data("a\r\nb\r\n".utf8))
        XCTAssertEqual(decoded.text, "a\nb\n")
        XCTAssertEqual(decoded.ending, .crlf)
        XCTAssertEqual(String(data: TextCodec.encode(decoded.text, ending: .crlf), encoding: .utf8), "a\r\nb\r\n")
        let mixed = try TextCodec.decode(Data("a\r\nb\nc".utf8))
        XCTAssertEqual(mixed.ending, .mixed)
        XCTAssertEqual(String(data: TextCodec.encode("a\nb", ending: .mixed), encoding: .utf8), "a\nb")
    }

    func testDirtyGuardAndLanguageId() throws {
        var workspace = WorkspaceState()
        let decision = try WorkspaceEditor.open(
            data: Data("# Hi\n".utf8),
            url: URL(fileURLWithPath: "/tmp/notes/hello.md"),
            into: &workspace
        )
        XCTAssertEqual(decision, .allow)
        XCTAssertEqual(workspace.activeDocument?.languageId, "markdown")
        workspace.documents[0].isModified = true
        let blocked = WorkspaceEditor.newScratch(into: &workspace)
        XCTAssertEqual(blocked, .prompt(NavigationGuard.unsavedMessage))
        XCTAssertEqual(workspace.documents.count, 1)
        let forced = WorkspaceEditor.newScratch(into: &workspace, force: true)
        XCTAssertEqual(forced, .allow)
        XCTAssertEqual(workspace.documents.count, 2)
    }

    func testExternalChangeAndCommands() {
        let loaded = Date(timeIntervalSince1970: 10)
        XCTAssertTrue(ExternalChange.conflicts(loaded: loaded, current: Date(timeIntervalSince1970: 11)))
        XCTAssertFalse(ExternalChange.conflicts(loaded: loaded, current: loaded))
        var registry = CommandRegistry()
        registry.register("echo") { "echo \($0)" }
        XCTAssertEqual(PluginHost.handle(method: "quill/command", params: "echo hi", registry: registry, bufferText: "x"), "echo hi")
        XCTAssertEqual(PluginHost.handle(method: "quill/buffer/getText", params: "", registry: registry, bufferText: "body"), "body")
        XCTAssertEqual(PluginHost.handle(method: "nope", params: "", registry: registry, bufferText: ""), "method not found")
        let types = FileTypeRegistry()
        XCTAssertEqual(types.languageId(for: URL(fileURLWithPath: "/tmp/A.swift")), "swift")
    }

    func testWindowDoesNotShareADocumentIdentity() {
        var workspace = WorkspaceState(root: URL(fileURLWithPath: "/tmp"))
        _ = WorkspaceEditor.newScratch(into: &workspace)
        let first = workspace.windows[0].documentID
        workspace.documents[0].isModified = false
        _ = WorkspaceEditor.newScratch(into: &workspace)
        XCTAssertNotEqual(workspace.windows[0].documentID, workspace.windows[1].documentID)
        XCTAssertEqual(workspace.windows[0].documentID, first)
        XCTAssertEqual(workspace.activeWindow, workspace.windows[1].id)
    }
}

final class LaunchRequestTests: XCTestCase {
    func testPathLineColumnAndPlus() {
        XCTAssertEqual(
            LaunchRequest.parse(["note.md:12"]),
            [LaunchTarget(path: "note.md", line: 12, column: nil)]
        )
        XCTAssertEqual(
            LaunchRequest.parse(["note.md:12:3"]),
            [LaunchTarget(path: "note.md", line: 12, column: 3)]
        )
        XCTAssertEqual(
            LaunchRequest.parse(["+8", "note.md"]),
            [LaunchTarget(path: "note.md", line: 8, column: nil)]
        )
        XCTAssertEqual(
            LaunchRequest.parse(["+8", "note.md:2"]),
            [LaunchTarget(path: "note.md", line: 2, column: nil)]
        )
        XCTAssertEqual(
            LaunchRequest.parse(["+10", "+3", "note.md"]),
            [LaunchTarget(path: "note.md", line: 3, column: nil)]
        )
        XCTAssertEqual(LaunchRequest.parse(["+12"]), [])
        XCTAssertEqual(LaunchRequest.parse(["--wait", "+4", "a.md"]), [LaunchTarget(path: "a.md", line: 4)])
        XCTAssertEqual(
            LaunchRequest.parse(["foo:bar"]),
            [LaunchTarget(path: "foo:bar", line: nil, column: nil)]
        )
        XCTAssertEqual(
            LaunchRequest.parse(["foo:bar:4:1"]),
            [LaunchTarget(path: "foo:bar", line: 4, column: 1)]
        )
    }

    func testSameFileAndURLRoundTrip() {
        XCTAssertTrue(LaunchRequest.sameFile(open: "/tmp/foo/../note.md", isDirectory: false, target: "/tmp/note.md"))
        XCTAssertFalse(LaunchRequest.sameFile(open: "/tmp/note.md", isDirectory: false, target: "/tmp/other.md"))
        XCTAssertTrue(LaunchRequest.sameFile(open: "/tmp/dir", isDirectory: true, target: "/tmp/dir/"))
        XCTAssertFalse(LaunchRequest.sameFile(open: nil, isDirectory: false, target: "/tmp/note.md"))
        let target = LaunchTarget(path: "/tmp/my note.md", line: 12, column: 3)
        let url = LaunchRequest.url(for: target)
        XCTAssertEqual(url.scheme, "quill")
        XCTAssertEqual(LaunchRequest.target(from: url), target)
        XCTAssertNil(LaunchRequest.target(from: URL(fileURLWithPath: "/tmp/a.md")))
    }
}

final class ShellHookTests: XCTestCase {
    func testOpensLastPathAndReportsErrors() {
        XCTAssertEqual(
            ShellHook.interpret(stdout: "noise\nnotes/a.md:4\n", stderr: "", status: 0),
            .open(path: "notes/a.md", line: 4, column: nil)
        )
        XCTAssertEqual(
            ShellHook.interpret(stdout: "/tmp/a.md:9:2\n", stderr: "", status: 0),
            .open(path: "/tmp/a.md", line: 9, column: 2)
        )
        XCTAssertEqual(
            ShellHook.interpret(stdout: "  /tmp/plain.md  \n", stderr: "", status: 0),
            .open(path: "/tmp/plain.md", line: nil, column: nil)
        )
        XCTAssertEqual(ShellHook.interpret(stdout: "\n", stderr: "  \n", status: 0), .status(""))
        XCTAssertEqual(ShellHook.interpret(stdout: "a.md:1", stderr: "err\n", status: 1), .status("err"))
        XCTAssertEqual(ShellHook.interpret(stdout: "nope\n", stderr: "", status: 2), .status("nope"))
        XCTAssertEqual(ShellHook.interpret(stdout: "", stderr: "", status: 3), .status("command failed (3)"))
    }
}
