import Foundation

/// A unique directory, deleted when this object is released.
final class TempDirectory {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("quill-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func write(_ name: String, _ text: String) throws {
        let file = url.appendingPathComponent(name)
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(text.utf8).write(to: file)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }
}
