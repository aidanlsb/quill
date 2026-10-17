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
