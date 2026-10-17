import Foundation

/// One entry in a directory listing buffer. Directories are displayed with a trailing `/`.
public struct DirEntry: Equatable, Sendable {
    public var originalURL: URL?
    public var name: String
    public var isDirectory: Bool

    public init(originalURL: URL? = nil, name: String, isDirectory: Bool) {
        self.originalURL = originalURL
        self.name = name
        self.isDirectory = isDirectory
    }

    public var displayName: String {
        isDirectory ? name + "/" : name
    }
}

public struct DirectorySnapshot: Equatable, Sendable {
    public var directory: URL
    public var entries: [DirEntry]

    public init(directory: URL, entries: [DirEntry]) {
        self.directory = directory
        self.entries = entries
    }

    public var bufferText: String {
        entries.map(\.displayName).joined(separator: "\n")
    }
}

public enum FSOperation: Equatable, Sendable {
    case create(parent: URL, name: String, isDirectory: Bool)
    case delete(URL)
    case rename(from: URL, to: URL)

    public var summary: String {
        switch self {
        case .create(_, let name, let isDirectory):
            return isDirectory ? "Create directory \(name)/" : "Create \(name)"
        case .delete(let url):
            return "Delete \(url.lastPathComponent)"
        case .rename(let from, let to):
            if from.deletingLastPathComponent() == to.deletingLastPathComponent() {
                return "Rename \(from.lastPathComponent) → \(to.lastPathComponent)"
            }
            return "Move \(from.lastPathComponent) → \(to.path)"
        }
    }
}

public struct ParsedDirLine: Equatable, Sendable {
    public var name: String
    public var isDirectory: Bool

    public init(_ raw: String) {
        var line = raw
        while line.last == " " || line.last == "\t" { line.removeLast() }
        while line.first == " " || line.first == "\t" { line.removeFirst() }
        if line.hasSuffix("/") {
            line.removeLast()
            self.isDirectory = true
            self.name = line
        } else {
            self.isDirectory = false
            self.name = line
        }
    }
}

public enum DirectoryListing {
    /// Render a snapshot as an oil-style buffer (one name per line, dirs with `/`).
    public static func render(_ snapshot: DirectorySnapshot) -> String {
        snapshot.bufferText
    }

    public static func parse(_ text: String) -> [ParsedDirLine] {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { ParsedDirLine(String($0)) }
            .filter { !$0.name.isEmpty }
    }

    /// Diff an edited listing against the original snapshot.
    /// `incomingMoves` are entries yanked (dd) from another directory and pasted here.
    public static func plan(
        original: DirectorySnapshot,
        editedText: String,
        incomingMoves: [DirEntry] = []
    ) -> [FSOperation] {
        let lines = parse(editedText)
        var unusedOriginal = original.entries
        var leftoverLines: [ParsedDirLine] = []
        var ops: [FSOperation] = []
        var consumedMoves: [DirEntry] = []

        for line in lines {
            if let idx = unusedOriginal.firstIndex(where: { $0.name == line.name && $0.isDirectory == line.isDirectory }) {
                unusedOriginal.remove(at: idx)
                continue
            }
            leftoverLines.append(line)
        }

        var leftoverCreates = leftoverLines
        var leftoverDeletes = unusedOriginal

        // Pasted entries from another directory become moves/renames.
        for move in incomingMoves {
            if let idx = leftoverCreates.firstIndex(where: { $0.name == move.name || $0.name == move.displayName }) {
                let line = leftoverCreates.remove(at: idx)
                if let from = move.originalURL {
                    let dest = original.directory.appendingPathComponent(line.name)
                    ops.append(.rename(from: from, to: dest))
                }
                consumedMoves.append(move)
                continue
            }
            if let idx = leftoverCreates.firstIndex(where: { !$0.isDirectory && !move.isDirectory }) {
                let line = leftoverCreates.remove(at: idx)
                if let from = move.originalURL {
                    ops.append(.rename(from: from, to: original.directory.appendingPathComponent(line.name)))
                }
                consumedMoves.append(move)
            }
        }

        // Pair remaining deletes with remaining creates as in-place renames.
        while let del = leftoverDeletes.first, let add = leftoverCreates.first {
            leftoverDeletes.removeFirst()
            leftoverCreates.removeFirst()
            if let from = del.originalURL {
                ops.append(.rename(from: from, to: original.directory.appendingPathComponent(add.name)))
            }
        }

        for del in leftoverDeletes {
            if let url = del.originalURL {
                ops.append(.delete(url))
            }
        }
        for add in leftoverCreates {
            ops.append(.create(parent: original.directory, name: add.name, isDirectory: add.isDirectory))
        }
        return ops
    }

    /// Read a directory from the real filesystem (skips `.` and `..`).
    public static func snapshot(of url: URL, fileManager: FileManager = .default) throws -> DirectorySnapshot {
        let contents = try fileManager.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsSubdirectoryDescendants]
        )
        let entries: [DirEntry] = contents.compactMap { item in
            let name = item.lastPathComponent
            if name == "." || name == ".." { return nil }
            let isDir = (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            return DirEntry(originalURL: item, name: name, isDirectory: isDir)
        }
        .sorted { a, b in
            a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
        return DirectorySnapshot(directory: url, entries: entries)
    }
}
