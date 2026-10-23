import XCTest
@testable import QuillWorkspace

final class AtomicFileTests: XCTestCase {
    func testNewFileIs0644AndExistingModeIsKept() throws {
        let directory = try makeDirectory()
        defer { remove(directory) }
        let created = directory.appendingPathComponent("note.md")
        try AtomicFile.write(Data("hello\n".utf8), to: created)
        XCTAssertEqual(try String(contentsOf: created, encoding: .utf8), "hello\n")
        XCTAssertEqual(try posixMode(created.path), 0o644)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: created.path)
        try AtomicFile.write(Data("next\n".utf8), to: created)
        XCTAssertEqual(try String(contentsOf: created, encoding: .utf8), "next\n")
        XCTAssertEqual(try posixMode(created.path), 0o600)
        try AtomicFile.write(Data(), to: created)
        XCTAssertEqual(try Data(contentsOf: created), Data())
        XCTAssertEqual(try posixMode(created.path), 0o600)
        XCTAssertFalse(try leftoverTemps(directory))
    }

    func testSymlinkIsRefusedAndTargetIsUnchanged() throws {
        let directory = try makeDirectory()
        defer { remove(directory) }
        let target = directory.appendingPathComponent("secret")
        try Data("secret".utf8).write(to: target)
        let link = directory.appendingPathComponent("link.md")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        XCTAssertThrowsError(try AtomicFile.write(Data("pwned".utf8), to: link)) { error in
            XCTAssertEqual(
                (error as? AtomicFile.Failure)?.message,
                "Refusing to write through a symlink"
            )
        }
        XCTAssertEqual(try Data(contentsOf: target), Data("secret".utf8))
        let values = try link.resourceValues(forKeys: [.isSymbolicLinkKey])
        XCTAssertEqual(values.isSymbolicLink, true)
        XCTAssertFalse(try leftoverTemps(directory))
    }

    func testDirectoryIsRefused() throws {
        let directory = try makeDirectory()
        defer { remove(directory) }
        let nested = directory.appendingPathComponent("folder")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        XCTAssertThrowsError(try AtomicFile.write(Data("x".utf8), to: nested)) { error in
            XCTAssertEqual((error as? AtomicFile.Failure)?.message, "Not a regular file")
        }
        XCTAssertFalse(try leftoverTemps(directory))
    }

    private func makeDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("quill-atomic-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func remove(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    private func posixMode(_ path: String) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }

    private func leftoverTemps(_ directory: URL) throws -> Bool {
        try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .contains { $0.hasPrefix(".quill-save-") }
    }
}
