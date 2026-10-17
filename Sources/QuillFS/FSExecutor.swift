import Foundation

/// Operations the directory planner asks for, executed in an order that
/// survives swaps, case-only renames, and nested creates.
public protocol FileSystem {
    func exists(_ path: String) -> Bool
    func createDirectory(_ path: String) throws
    func writeFile(_ path: String, data: Data) throws
    func remove(_ path: String) throws
    func move(from: String, to: String) throws
    func copy(from: String, to: String) throws
}

public struct FSExecutionError: Error, Equatable, Sendable {
    public var message: String
    public var completed: [String]
    public var failed: String

    public init(message: String, completed: [String], failed: String) {
        self.message = message
        self.completed = completed
        self.failed = failed
    }
}

public enum FSExecutor {
    /// Parents first, then copies and renames (cycles and case-only renames via a temp name), deletes last.
    public static func ordered(_ ops: [FSOperation]) -> [FSOperation] {
        var creates: [FSOperation] = []
        var renames: [FSOperation] = []
        var copies: [FSOperation] = []
        var deletes: [FSOperation] = []
        for op in ops {
            switch op {
            case .create: creates.append(op)
            case .rename: renames.append(op)
            case .copy: copies.append(op)
            case .delete: deletes.append(op)
            }
        }
        creates.sort { lhs, rhs in
            guard case .create(_, let a, let aDir) = lhs, case .create(_, let b, let bDir) = rhs else { return false }
            if aDir != bDir { return aDir && !bDir }
            return a.split(separator: "/").count < b.split(separator: "/").count
        }
        return creates + brokenCycles(renames) + copies + deletes
    }

    public static func apply(_ ops: [FSOperation], fs: any FileSystem) throws {
        var completed: [String] = []
        for op in ordered(ops) {
            do {
                try applyOne(op, fs: fs)
                completed.append(op.summary)
            } catch let error as FSExecutionError {
                throw error
            } catch {
                throw FSExecutionError(message: String(describing: error), completed: completed, failed: op.summary)
            }
        }
    }

    private static func applyOne(_ op: FSOperation, fs: any FileSystem) throws {
        switch op {
        case .create(let parent, let name, let isDirectory):
            let dest = parent.appendingPathComponent(name).path
            try ensureParent(of: dest, fs: fs)
            if isDirectory {
                try fs.createDirectory(dest)
            } else if !fs.exists(dest) {
                try fs.writeFile(dest, data: Data())
            }
        case .delete(let url):
            if fs.exists(url.path) {
                try fs.remove(url.path)
            }
        case .copy(let from, let to):
            try ensureParent(of: to.path, fs: fs)
            try fs.copy(from: from.path, to: to.path)
        case .rename(let from, let to):
            try ensureParent(of: to.path, fs: fs)
            if from.path == to.path { return }
            if sameFileDifferentCase(from.path, to.path) {
                let temp = temporaryPath(near: to.path)
                try fs.move(from: from.path, to: temp)
                try fs.move(from: temp, to: to.path)
                return
            }
            if fs.exists(to.path) {
                throw FSExecutionError(
                    message: "Already exists: \(to.lastPathComponent)",
                    completed: [],
                    failed: "Rename \(from.lastPathComponent) → \(to.lastPathComponent)"
                )
            }
            try fs.move(from: from.path, to: to.path)
        }
    }

    /// Rename chains and 2-cycles are broken by parking the first source at a temp path,
    /// expressed as extra renames the executor understands.
    static func brokenCycles(_ renames: [FSOperation]) -> [FSOperation] {
        var pairs: [(from: String, to: String, op: FSOperation)] = []
        for op in renames {
            if case .rename(let from, let to) = op {
                pairs.append((from.path, to.path, op))
            }
        }
        let sources = Set(pairs.map(\.from))
        let targets = Set(pairs.map(\.to))
        let contested = sources.intersection(targets)
        guard !contested.isEmpty else { return renames }
        var planned: [FSOperation] = []
        var parked: [String: String] = [:]
        for path in contested {
            let temp = temporaryPath(near: path)
            parked[path] = temp
            planned.append(.rename(from: URL(fileURLWithPath: path), to: URL(fileURLWithPath: temp)))
        }
        for pair in pairs {
            let source = parked[pair.from] ?? pair.from
            planned.append(.rename(from: URL(fileURLWithPath: source), to: URL(fileURLWithPath: pair.to)))
        }
        return planned
    }

    private static func ensureParent(of path: String, fs: any FileSystem) throws {
        let parent = (path as NSString).deletingLastPathComponent
        if parent.isEmpty || parent == path || fs.exists(parent) { return }
        try ensureParent(of: parent, fs: fs)
        try fs.createDirectory(parent)
    }

    private static func sameFileDifferentCase(_ a: String, _ b: String) -> Bool {
        a.compare(b, options: [.caseInsensitive]) == .orderedSame && a != b
    }

    private static func temporaryPath(near path: String) -> String {
        let ns = path as NSString
        return ns.deletingLastPathComponent + "/.quill-tmp-" + ns.lastPathComponent
    }
}

/// In-memory filesystem for executor tests. Paths are strings; missing deletes succeed.
public final class MemoryFileSystem: FileSystem {
    public var files: [String: Data]
    public var directories: Set<String>

    public init(files: [String: Data] = [:], directories: Set<String> = ["/"]) {
        self.files = files
        self.directories = directories
    }

    public func exists(_ path: String) -> Bool {
        files[path] != nil || directories.contains(path)
    }

    public func createDirectory(_ path: String) throws {
        directories.insert(path)
    }

    public func writeFile(_ path: String, data: Data) throws {
        files[path] = data
        directories.insert((path as NSString).deletingLastPathComponent)
    }

    public func remove(_ path: String) throws {
        files.removeValue(forKey: path)
        directories.remove(path)
    }

    public func move(from: String, to: String) throws {
        if let data = files.removeValue(forKey: from) {
            files[to] = data
            return
        }
        if directories.contains(from) {
            directories.remove(from)
            directories.insert(to)
            let prefix = from.hasSuffix("/") ? from : from + "/"
            let movedFiles = files.filter { $0.key.hasPrefix(prefix) }
            for (path, data) in movedFiles {
                files.removeValue(forKey: path)
                files[to + "/" + String(path.dropFirst(prefix.count))] = data
            }
            return
        }
        throw FSExecutionError(message: "missing \(from)", completed: [], failed: from)
    }

    public func copy(from: String, to: String) throws {
        guard let data = files[from] else {
            throw FSExecutionError(message: "missing \(from)", completed: [], failed: from)
        }
        files[to] = data
    }
}
