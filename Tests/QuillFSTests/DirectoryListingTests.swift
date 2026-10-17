import XCTest
import Foundation
@testable import QuillFS

final class DirectoryListingTests: XCTestCase {
    let parent = URL(fileURLWithPath: "/notes")

    func original(_ names: [(String, Bool)]) -> DirectorySnapshot {
        DirectorySnapshot(
            directory: parent,
            entries: names.map { DirEntry(originalURL: parent.appendingPathComponent($0.0), name: $0.0, isDirectory: $0.1) }
        )
    }

    func testRenderTrailingSlash() {
        let snap = original([("dir", true), ("a.md", false)])
        XCTAssertEqual(DirectoryListing.render(snap), "dir/\na.md")
    }

    func testParseSkipsBlank() {
        let lines = DirectoryListing.parse("a.md\n\nsubdir/\n")
        XCTAssertEqual(lines.map(\.name), ["a.md", "subdir"])
        XCTAssertEqual(lines.map(\.isDirectory), [false, true])
    }

    func testNoChanges() {
        let snap = original([("a.md", false), ("b", true)])
        let ops = DirectoryListing.plan(original: snap, editedText: "a.md\nb/\n")
        XCTAssertTrue(ops.isEmpty)
    }

    func testRename() {
        let snap = original([("old.md", false)])
        let ops = DirectoryListing.plan(original: snap, editedText: "new.md\n")
        XCTAssertEqual(ops, [
            .rename(from: parent.appendingPathComponent("old.md"), to: parent.appendingPathComponent("new.md")),
        ])
    }

    func testCreateFileAndDirectory() {
        let snap = original([("a.md", false)])
        let ops = DirectoryListing.plan(original: snap, editedText: "a.md\ncreated.md\nfolder/\n")
        XCTAssertEqual(Set(ops.map(\.summary)).count, 2)
        XCTAssertTrue(ops.contains(.create(parent: parent, name: "created.md", isDirectory: false)))
        XCTAssertTrue(ops.contains(.create(parent: parent, name: "folder", isDirectory: true)))
    }

    func testDelete() {
        let snap = original([("gone.md", false), ("keep.md", false)])
        let ops = DirectoryListing.plan(original: snap, editedText: "keep.md\n")
        XCTAssertEqual(ops, [.delete(parent.appendingPathComponent("gone.md"))])
    }

    func testMoveFromIncomingPaste() {
        let snap = original([("stay.md", false)])
        let incoming = DirEntry(
            originalURL: URL(fileURLWithPath: "/other/moved.md"),
            name: "moved.md",
            isDirectory: false
        )
        let ops = DirectoryListing.plan(
            original: snap,
            editedText: "stay.md\nmoved.md\n",
            incomingMoves: [incoming]
        )
        XCTAssertEqual(ops, [
            .rename(from: URL(fileURLWithPath: "/other/moved.md"), to: parent.appendingPathComponent("moved.md")),
        ])
    }

    func testRenameAndCreateTogether() {
        let snap = original([("a.md", false)])
        let ops = DirectoryListing.plan(original: snap, editedText: "b.md\nc.md\n")
        XCTAssertEqual(ops.count, 2)
        XCTAssertTrue(ops.contains { if case .rename = $0 { return true } else { return false } })
        XCTAssertTrue(ops.contains { if case .create = $0 { return true } else { return false } })
    }

    func testSnapshotReadsFilesystem() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("quill-fs-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try "hi".write(to: dir.appendingPathComponent("note.md"), atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("sub"), withIntermediateDirectories: true)
        let snap = try DirectoryListing.snapshot(of: dir)
        XCTAssertEqual(Set(snap.entries.map(\.name)), ["note.md", "sub"])
        XCTAssertEqual(snap.entries.first { $0.name == "sub" }?.isDirectory, true)
        XCTAssertTrue(DirectoryListing.render(snap).contains("sub/"))
    }
}
