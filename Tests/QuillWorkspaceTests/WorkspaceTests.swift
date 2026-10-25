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

    func testDirtyGuardAndLanguageId() {
        XCTAssertEqual(NavigationGuard.decide(isModified: false, force: false), .allow)
        XCTAssertEqual(NavigationGuard.decide(isModified: true, force: true), .allow)
        XCTAssertEqual(
            NavigationGuard.decide(isModified: true, force: false),
            .prompt(NavigationGuard.unsavedMessage)
        )
        let types = FileTypeRegistry()
        XCTAssertEqual(types.languageId(for: URL(fileURLWithPath: "/tmp/notes/hello.md")), "markdown")
        XCTAssertEqual(types.languageId(for: URL(fileURLWithPath: "/tmp/A.swift")), "swift")
    }

    func testExternalChange() {
        let loaded = Date(timeIntervalSince1970: 10)
        XCTAssertTrue(ExternalChange.conflicts(loaded: loaded, current: Date(timeIntervalSince1970: 11)))
        XCTAssertFalse(ExternalChange.conflicts(loaded: loaded, current: loaded))
    }
}

final class LaunchRequestTests: XCTestCase {
    func testPathLineColumnAndPlus() {
        XCTAssertEqual(LaunchRequest.parse([]), [])
        XCTAssertEqual(LaunchRequest.parse(["--wait", "--"]), [])
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
            LaunchRequest.parse(["quill://open?path=/tmp/notes&line=4&column=2"]),
            [LaunchTarget(path: "/tmp/notes", line: 4, column: 2)]
        )
        XCTAssertEqual(
            LaunchRequest.parse(["note.md:12", "quill://open?path=/tmp/dir"]),
            [
                LaunchTarget(path: "note.md", line: 12, column: nil),
                LaunchTarget(path: "/tmp/dir", line: nil, column: nil),
            ]
        )
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
