import XCTest
import Foundation
@testable import QuillFS

final class DirectoryListingTests: XCTestCase {
    let parent = URL(fileURLWithPath: "/notes")

    func original(_ names: [(String, Bool)], ids: [UInt64]? = nil) -> DirectorySnapshot {
        DirectorySnapshot(
            directory: parent,
            entries: names.enumerated().map { index, item in
                DirEntry(
                    originalURL: parent.appendingPathComponent(item.0),
                    name: item.0,
                    isDirectory: item.1,
                    entryID: ids?[index]
                )
            }
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
        let snap = original([("old.md", false)], ids: [7])
        let ops = DirectoryListing.plan(original: snap, lines: [
            ListingLine(name: "new.md", isDirectory: false, entryID: 7, sourcePath: parent.appendingPathComponent("old.md").path),
        ])
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
        let snap = original([("a.md", false)], ids: [4])
        let ops = DirectoryListing.plan(original: snap, lines: [
            ListingLine(name: "b.md", isDirectory: false, entryID: 4),
            ListingLine(name: "c.md", isDirectory: false),
        ])
        XCTAssertEqual(ops.count, 2)
        XCTAssertTrue(ops.contains { if case .rename = $0 { return true } else { return false } })
        XCTAssertTrue(ops.contains { if case .create = $0 { return true } else { return false } })
    }

    func testProbeDoesNotRenameTheWrongFile() {
        let snap = original([("a.md", false), ("b.md", false), ("c.md", false)], ids: [1, 2, 3])
        let ops = DirectoryListing.plan(original: snap, lines: [
            ListingLine(name: "b.md", isDirectory: false, entryID: 2),
            ListingLine(name: "z.md", isDirectory: false, entryID: 3, sourcePath: parent.appendingPathComponent("c.md").path),
        ])
        XCTAssertEqual(ops, [
            .rename(from: parent.appendingPathComponent("c.md"), to: parent.appendingPathComponent("z.md")),
            .delete(parent.appendingPathComponent("a.md")),
        ])
    }

    func testProbeTypedLineIsCreateNotStaleYank() {
        let snap = original([("keep.md", false)], ids: [1])
        let ops = DirectoryListing.plan(original: snap, editedText: "keep.md\nbrand-new.md\n", incomingMoves: [
            DirEntry(originalURL: URL(fileURLWithPath: "/other/x.md"), name: "x.md", isDirectory: false, entryID: 9),
        ])
        XCTAssertEqual(ops, [
            .create(parent: parent, name: "brand-new.md", isDirectory: false),
        ])
    }

    func testProbeFileToDirectoryIsNotASelfRename() {
        let snap = original([("foo", false)], ids: [5])
        let ops = DirectoryListing.plan(original: snap, lines: [
            ListingLine(name: "foo", isDirectory: true, entryID: 5, sourcePath: parent.appendingPathComponent("foo").path),
        ])
        XCTAssertEqual(ops, [
            .delete(parent.appendingPathComponent("foo")),
            .create(parent: parent, name: "foo", isDirectory: true),
        ])
        XCTAssertFalse(ops.contains { if case .rename = $0 { return true } else { return false } })
    }

    func testYankPasteIsCopy() {
        let snap = original([("a.md", false)], ids: [1])
        let ops = DirectoryListing.plan(original: snap, lines: [
            ListingLine(name: "a.md", isDirectory: false, entryID: 1, sourcePath: parent.appendingPathComponent("a.md").path),
            ListingLine(
                name: "a-copy.md",
                isDirectory: false,
                entryID: 1,
                sourcePath: parent.appendingPathComponent("a.md").path,
                transfer: .copy
            ),
        ])
        XCTAssertEqual(ops, [
            .copy(from: parent.appendingPathComponent("a.md"), to: parent.appendingPathComponent("a-copy.md")),
        ])
    }

    func testSlashAndDotDotDoNotEscape() {
        let snap = original([("note.md", false)], ids: [1])
        let lines = [
            ListingLine(name: "../.ssh/authorized_keys", isDirectory: false, entryID: 1),
        ]
        XCTAssertEqual(DirectoryListing.invalidName(in: lines), "../.ssh/authorized_keys")
        let ops = DirectoryListing.plan(original: snap, lines: lines)
        XCTAssertTrue(ops.isEmpty)
        XCTAssertNil(DirectoryListing.confinementError(ops, directory: parent))
        let planted = DirectoryListing.plan(original: snap, editedText: "note.md\nsub/evil.md\n")
        XCTAssertTrue(planted.isEmpty)
        let escape: [FSOperation] = [
            .rename(from: parent.appendingPathComponent("note.md"), to: URL(fileURLWithPath: "/etc/cron.d/evil")),
        ]
        XCTAssertEqual(
            DirectoryListing.confinementError(escape, directory: parent),
            "Refusing to write evil"
        )
        let outsideDelete: [FSOperation] = [.delete(URL(fileURLWithPath: "/etc/passwd"))]
        XCTAssertEqual(
            DirectoryListing.confinementError(outsideDelete, directory: parent),
            "Refusing to delete passwd"
        )
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
