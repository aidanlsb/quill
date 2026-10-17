import XCTest
@testable import QuillFS

final class FSExecutorTests: XCTestCase {
    func testSwap() throws {
        let fs = MemoryFileSystem(files: ["/notes/a.md": Data("a".utf8), "/notes/b.md": Data("b".utf8)])
        let ops: [FSOperation] = [
            .rename(from: URL(fileURLWithPath: "/notes/a.md"), to: URL(fileURLWithPath: "/notes/b.md")),
            .rename(from: URL(fileURLWithPath: "/notes/b.md"), to: URL(fileURLWithPath: "/notes/a.md")),
        ]
        try FSExecutor.apply(ops, fs: fs)
        XCTAssertEqual(fs.files["/notes/a.md"], Data("b".utf8))
        XCTAssertEqual(fs.files["/notes/b.md"], Data("a".utf8))
    }

    func testCaseOnlyRename() throws {
        let fs = MemoryFileSystem(files: ["/notes/a.md": Data("a".utf8)])
        try FSExecutor.apply([
            .rename(from: URL(fileURLWithPath: "/notes/a.md"), to: URL(fileURLWithPath: "/notes/A.md")),
        ], fs: fs)
        XCTAssertEqual(fs.files["/notes/A.md"], Data("a".utf8))
        XCTAssertNil(fs.files["/notes/a.md"])
    }

    func testNestedCreate() throws {
        let fs = MemoryFileSystem()
        try FSExecutor.apply([
            .create(parent: URL(fileURLWithPath: "/notes"), name: "sub/new.md", isDirectory: false),
        ], fs: fs)
        XCTAssertTrue(fs.directories.contains("/notes/sub"))
        XCTAssertEqual(fs.files["/notes/sub/new.md"], Data())
    }

    func testCopyAndMissingDelete() throws {
        let fs = MemoryFileSystem(files: ["/other/a.md": Data("hi".utf8)])
        try FSExecutor.apply([
            .copy(from: URL(fileURLWithPath: "/other/a.md"), to: URL(fileURLWithPath: "/notes/a.md")),
            .delete(URL(fileURLWithPath: "/notes/missing.md")),
        ], fs: fs)
        XCTAssertEqual(fs.files["/notes/a.md"], Data("hi".utf8))
        XCTAssertEqual(fs.files["/other/a.md"], Data("hi".utf8))
    }
}
