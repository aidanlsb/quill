import Foundation

/// One entry in a directory listing buffer. Directories are displayed with a trailing `/`.
public struct DirEntry: Equatable, Sendable {
    public var originalURL: URL?
    public var name: String
    public var isDirectory: Bool
    /// Stable identity assigned when the listing is captured. Edits keep this id.
    public var entryID: UInt64?

    public init(originalURL: URL? = nil, name: String, isDirectory: Bool, entryID: UInt64? = nil) {
        self.originalURL = originalURL
        self.name = name
        self.isDirectory = isDirectory
        self.entryID = entryID
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
    case copy(from: URL, to: URL)

    public var summary: String {
        switch self {
        case .create(_, let name, let isDirectory):
            return isDirectory ? "Create directory \(name)/" : "Create \(name)"
        case .delete(let url):
            return "Delete \(url.lastPathComponent)"
        case .rename(let from, let to):
            if from.deletingLastPathComponent().path == to.deletingLastPathComponent().path {
                return "Rename \(from.lastPathComponent) → \(to.lastPathComponent)"
            }
            return "Move \(from.lastPathComponent) → \(to.path)"
        case .copy(let from, let to):
            return "Copy \(from.lastPathComponent) → \(to.lastPathComponent)"
        }
    }
}

public enum LineTransfer: Equatable, Sendable {
    case identity
    case move
    case copy
}

/// One edited listing line plus the anchor identity that traveled with it.
public struct ListingLine: Equatable, Sendable {
    public var name: String
    public var isDirectory: Bool
    public var entryID: UInt64?
    public var sourcePath: String?
    public var transfer: LineTransfer

    public init(
        name: String,
        isDirectory: Bool,
        entryID: UInt64? = nil,
        sourcePath: String? = nil,
        transfer: LineTransfer = .identity
    ) {
        self.name = name
        self.isDirectory = isDirectory
        self.entryID = entryID
        self.sourcePath = sourcePath
        self.transfer = transfer
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

    public static func stableID(for path: String) -> UInt64 {
        var hash: UInt64 = 14695981039346656037
        for byte in path.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1099511628211
        }
        return hash == 0 ? 1 : hash
    }

    /// True when a save both creates and deletes, which is worth a louder confirmation.
    public static func mixesDeletesAndCreates(_ ops: [FSOperation]) -> Bool {
        let deletes = ops.contains { if case .delete = $0 { return true } else { return false } }
        let creates = ops.contains { if case .create = $0 { return true } else { return false } }
        return deletes && creates
    }

    /// Diff edited lines against the snapshot using anchor identity.
    /// A line keeps its id across a rename. `dd`+`p` arrives as `.move`. `yy`+`p` arrives as `.copy`.
    /// A line with no id is a create. Unmentioned originals are deletes. Nothing is paired by position.
    public static func plan(original: DirectorySnapshot, lines: [ListingLine]) -> [FSOperation] {
        var used = Set<Int>()
        var ops: [FSOperation] = []

        func take(_ matches: (DirEntry) -> Bool) -> (Int, DirEntry)? {
            for (index, entry) in original.entries.enumerated() where !used.contains(index) && matches(entry) {
                used.insert(index)
                return (index, entry)
            }
            return nil
        }

        for line in lines {
            if line.name.isEmpty { continue }
            if line.transfer == .copy, let source = line.sourcePath {
                let from = URL(fileURLWithPath: source)
                ops.append(.copy(from: from, to: original.directory.appendingPathComponent(line.name)))
                continue
            }
            if line.transfer == .move, let source = line.sourcePath {
                let from = URL(fileURLWithPath: source)
                let dest = original.directory.appendingPathComponent(line.name)
                if let id = line.entryID {
                    _ = take { $0.entryID == id }
                }
                if from.standardizedFileURL.path != dest.standardizedFileURL.path {
                    ops.append(.rename(from: from, to: dest))
                }
                continue
            }
            if let id = line.entryID, let (_, entry) = take({ $0.entryID == id }) {
                appendIdentityChange(entry, line: line, directory: original.directory, ops: &ops)
                continue
            }
            if line.entryID == nil,
               let (_, entry) = take({ $0.name == line.name && $0.isDirectory == line.isDirectory }) {
                continue
            }
            ops.append(.create(parent: original.directory, name: line.name, isDirectory: line.isDirectory))
        }

        for (index, entry) in original.entries.enumerated() where !used.contains(index) {
            if let url = entry.originalURL {
                ops.append(.delete(url))
            }
        }
        return ops
    }

    /// Text-only diff. Exact-name incoming moves are honored; leftover creates are not paired with leftover deletes.
    public static func plan(
        original: DirectorySnapshot,
        editedText: String,
        incomingMoves: [DirEntry] = []
    ) -> [FSOperation] {
        var lines = parse(editedText).map {
            ListingLine(name: $0.name, isDirectory: $0.isDirectory)
        }
        var moves = incomingMoves
        for index in lines.indices {
            guard let found = moves.firstIndex(where: {
                $0.name == lines[index].name && $0.isDirectory == lines[index].isDirectory
            }) else { continue }
            let move = moves.remove(at: found)
            lines[index].transfer = .move
            lines[index].sourcePath = move.originalURL?.path
            lines[index].entryID = move.entryID
        }
        return plan(original: original, lines: lines)
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
            return DirEntry(
                originalURL: item,
                name: name,
                isDirectory: isDir,
                entryID: stableID(for: item.path)
            )
        }
        .sorted { a, b in
            a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
        return DirectorySnapshot(directory: url, entries: entries)
    }

    private static func appendIdentityChange(
        _ entry: DirEntry,
        line: ListingLine,
        directory: URL,
        ops: inout [FSOperation]
    ) {
        if entry.isDirectory != line.isDirectory {
            if let url = entry.originalURL {
                ops.append(.delete(url))
            }
            ops.append(.create(parent: directory, name: line.name, isDirectory: line.isDirectory))
            return
        }
        if entry.name != line.name, let from = entry.originalURL {
            ops.append(.rename(from: from, to: directory.appendingPathComponent(line.name)))
        }
    }
}
