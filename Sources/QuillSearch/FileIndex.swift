import Foundation
import QuillText

public struct GrepHit: Equatable, Sendable {
    public var path: String
    public var line: Int
    public var snippet: String

    public init(path: String, line: Int, snippet: String) {
        self.path = path
        self.line = line
        self.snippet = snippet
    }

    public var display: String {
        "\(path):\(line): \(snippet)"
    }
}

struct CompiledIgnore: Sendable {
    var regex: NSRegularExpression
    var negation: Bool
    var directoryOnly: Bool
}

public struct IgnoreRules: Equatable, Sendable {
    public var patterns: [String]
    public var includeHidden: Bool
    private var compiled: [CompiledIgnore]

    public init(patterns: [String] = [], includeHidden: Bool = false) {
        self.patterns = patterns
        self.includeHidden = includeHidden
        self.compiled = Self.compile(patterns)
    }

    public static func == (lhs: IgnoreRules, rhs: IgnoreRules) -> Bool {
        lhs.patterns == rhs.patterns && lhs.includeHidden == rhs.includeHidden
    }

    public static func load(from root: URL, fileManager: FileManager = .default) -> IgnoreRules {
        var patterns: [String] = []
        func absorb(_ url: URL, prefix: String) {
            guard let data = try? String(contentsOf: url, encoding: .utf8) else { return }
            for line in LineIndex.contents(of: data) {
                var trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
                if !prefix.isEmpty, !trimmed.hasPrefix("!") {
                    trimmed = prefix + trimmed
                } else if !prefix.isEmpty, trimmed.hasPrefix("!") {
                    trimmed = "!" + prefix + trimmed.dropFirst()
                }
                patterns.append(String(trimmed))
            }
        }
        // `.gitignore` is hidden, so a skipsHiddenFiles walk never sees it and
        // still visits every file. Read each directory's gitignore by path, and
        // do not descend into directories the rules already ignore.
        var rules = IgnoreRules(patterns: patterns)
        var queue = [root]
        var seen = Set<String>()
        while let dir = queue.popLast() {
            let relDir = FileWalk.relative(dir, root: root)
            if !relDir.isEmpty, rules.ignores(relativePath: relDir, isDirectory: true) { continue }
            if dir.lastPathComponent == ".git" { continue }
            if !seen.insert(dir.path).inserted { continue }
            let prefix = relDir.isEmpty ? "" : relDir + "/"
            let gitignore = dir.appendingPathComponent(".gitignore")
            if fileManager.fileExists(atPath: gitignore.path) {
                let before = patterns.count
                absorb(gitignore, prefix: prefix)
                if patterns.count != before {
                    rules = IgnoreRules(patterns: patterns)
                }
            }
            guard let children = try? fileManager.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            for item in children {
                let isDir = (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                guard isDir, item.lastPathComponent != ".git" else { continue }
                let rel = FileWalk.relative(item, root: root)
                if rules.ignores(relativePath: rel, isDirectory: true) { continue }
                queue.append(item)
            }
        }
        return rules
    }

    public func ignores(relativePath: String, isDirectory: Bool) -> Bool {
        let parts = relativePath.split(separator: "/").map(String.init)
        if !includeHidden, let first = parts.first, first.hasPrefix("."), first != "." { return true }
        if parts.contains(where: { $0 == ".git" || $0 == ".svn" || $0 == ".hg" }) { return true }
        var ignored = false
        let path = isDirectory && !relativePath.hasSuffix("/") ? relativePath + "/" : relativePath
        for pattern in compiled {
            if pattern.directoryOnly && !isDirectory && !relativePath.hasSuffix("/") {
                // A directory-only rule still ignores children when the pattern matches a parent.
            }
            let range = NSRange(path.startIndex..<path.endIndex, in: path)
            if pattern.regex.firstMatch(in: path, range: range) != nil {
                ignored = !pattern.negation
            }
        }
        return ignored
    }

    private static func compile(_ patterns: [String]) -> [CompiledIgnore] {
        patterns.compactMap { raw in
            var pattern = raw
            var negation = false
            if pattern.hasPrefix("!") {
                negation = true
                pattern.removeFirst()
            }
            var directoryOnly = false
            if pattern.hasSuffix("/") {
                directoryOnly = true
                pattern.removeLast()
            }
            let anchored = pattern.hasPrefix("/")
            if anchored { pattern.removeFirst() }
            let body = globToRegex(pattern, anchored: anchored)
            guard let regex = try? NSRegularExpression(pattern: body) else { return nil }
            return CompiledIgnore(regex: regex, negation: negation, directoryOnly: directoryOnly)
        }
    }

    /// `*` stays inside one path segment. `**` crosses separators.
    static func globToRegex(_ pattern: String, anchored: Bool) -> String {
        var regex = ""
        let chars = Array(pattern)
        var index = 0
        while index < chars.count {
            let ch = chars[index]
            if ch == "*", index + 1 < chars.count, chars[index + 1] == "*" {
                regex += ".*"
                index += 2
                if index < chars.count, chars[index] == "/" { index += 1 }
                continue
            }
            if ch == "*" {
                regex += "[^/]*"
            } else if ch == "?" {
                regex += "[^/]"
            } else if ".+()|[]{}^$\\".contains(ch) {
                regex += "\\"
                regex.append(ch)
            } else {
                regex.append(ch)
            }
            index += 1
        }
        if anchored {
            return "^(?:\(regex))(?:/.*)?$"
        }
        return "^(?:.*/)?(?:\(regex))(?:/.*)?$"
    }
}

/// One compiled ignore set per root. Grep keystrokes and the file picker
/// share it so they do not walk the tree or recompile globs again.
public actor IgnoreCache {
    public static let shared = IgnoreCache()
    private var entries: [String: (mtime: Date?, rules: IgnoreRules)] = [:]

    public func rules(for root: URL) -> IgnoreRules {
        let key = root.path
        let mtime = Self.mtime(root.appendingPathComponent(".gitignore"))
        if let hit = entries[key], hit.mtime == mtime {
            return hit.rules
        }
        let loaded = IgnoreRules.load(from: root)
        entries[key] = (mtime, loaded)
        return loaded
    }

    private static func mtime(_ url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate]) as? Date
    }
}

public enum FileWalk {
    public static func files(
        in root: URL,
        extensions: [String] = [".md", ".markdown", ".txt", ".swift", ".rs", ".go", ".py", ".json", ".yml", ".yaml"],
        ignore: IgnoreRules = IgnoreRules(),
        fileManager: FileManager = .default
    ) -> [URL] {
        var results: [URL] = []
        let options: FileManager.DirectoryEnumerationOptions = ignore.includeHidden ? [] : [.skipsHiddenFiles]
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: options
        ) else { return [] }
        while let item = enumerator.nextObject() as? URL {
            let rel = relative(item, root: root)
            let isDir = (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if isDir {
                let name = item.lastPathComponent
                if ignore.ignores(relativePath: rel, isDirectory: true) || name == ".git" {
                    enumerator.skipDescendants()
                }
                continue
            }
            if ignore.ignores(relativePath: rel, isDirectory: false) { continue }
            if !extensions.isEmpty {
                let ext = "." + item.pathExtension.lowercased()
                if !extensions.contains(ext) { continue }
            }
            results.append(item)
        }
        return results
    }

    static func relative(_ url: URL, root: URL) -> String {
        let rootPath = root.path.hasSuffix("/") ? String(root.path.dropLast()) : root.path
        if url.path == rootPath { return "" }
        let prefix = rootPath + "/"
        if url.path.hasPrefix(prefix) { return String(url.path.dropFirst(prefix.count)) }
        return url.lastPathComponent
    }
}

public enum ContentSearch {
    public static let defaultLimit = 200

    /// Built-in line scan. `relativePath` is stored on hits.
    public static func grep(
        query: String,
        files: [(path: String, contents: String)],
        limit: Int = defaultLimit
    ) -> [GrepHit] {
        if query.isEmpty { return [] }
        var hits: [GrepHit] = []
        for file in files {
            let lines = LineIndex.contents(of: file.contents)
            for (idx, line) in lines.enumerated() {
                if line.localizedCaseInsensitiveContains(query) {
                    let snippet = String(line).trimmingCharacters(in: .whitespaces)
                    hits.append(GrepHit(path: file.path, line: idx + 1, snippet: snippet))
                    if hits.count >= limit { return hits }
                }
            }
        }
        return hits
    }

    /// Prefer ripgrep when `rg` is on PATH; fall back to a native walk + scan.
    /// The pipe is drained on background queues before `waitUntilExit`, so a large
    /// hit list cannot fill the 64 KB pipe and deadlock.
    public static func search(
        root: URL,
        query: String,
        ignore: IgnoreRules = IgnoreRules(),
        limit: Int = defaultLimit,
        fileManager: FileManager = .default,
        process: CancellableProcess? = nil
    ) -> [GrepHit] {
        if query.isEmpty { return [] }
        if ripgrepAvailable(), let rg = ripgrep(
            root: root,
            query: query,
            limit: limit,
            includeHidden: ignore.includeHidden,
            process: process
        ) {
            return rg
        }
        let urls = FileWalk.files(in: root, ignore: ignore, fileManager: fileManager)
        let files: [(String, String)] = urls.compactMap { url in
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
            return (FileWalk.relative(url, root: root), text)
        }
        return grep(query: query, files: files, limit: limit)
    }

    public static func arguments(query: String, root: String, limit: Int, includeHidden: Bool) -> [String] {
        var args = ["rg", "--vimgrep", "--path-separator", "/", "--glob", "!.git", "-S", "--max-count", String(max(1, limit))]
        if includeHidden { args.append("--hidden") }
        args.append(contentsOf: ["-e", query, "--", root])
        return args
    }

    /// `rg --vimgrep` lines are `path:line:column:text`. Paths are made relative to `root`.
    public static func parseVimgrep(_ text: String, root: String, limit: Int) -> [GrepHit] {
        var hits: [GrepHit] = []
        for raw in LineIndex.contents(of: text) where !raw.isEmpty {
            guard let hit = parseVimgrepLine(String(raw), root: root) else { continue }
            hits.append(hit)
            if hits.count >= limit { break }
        }
        return hits
    }

    public static func normalize(path: String, root: String) -> String {
        let rootPath = root.hasSuffix("/") ? String(root.dropLast()) : root
        if path == rootPath { return "" }
        let prefix = rootPath + "/"
        if path.hasPrefix(prefix) { return String(path.dropFirst(prefix.count)) }
        return path
    }

    /// Read both pipes to completion on dedicated threads, then wait.
    /// Waiting before the reads deadlock once output exceeds the ~64 KB pipe buffer.
    public static func drain(stdout: FileHandle, stderr: FileHandle, process: Process) -> (Data, Data) {
        let outBox = LockedData()
        let errBox = LockedData()
        let gate = DrainGate(remaining: 2)
        let outThread = Thread {
            outBox.set(stdout.readDataToEndOfFile())
            gate.leave()
        }
        let errThread = Thread {
            errBox.set(stderr.readDataToEndOfFile())
            gate.leave()
        }
        outThread.name = "quill.search.stdout"
        errThread.name = "quill.search.stderr"
        outThread.start()
        errThread.start()
        gate.waitUntilEmpty()
        process.waitUntilExit()
        return (outBox.get(), errBox.get())
    }

    static func parseVimgrepLine(_ raw: String, root: String) -> GrepHit? {
        // Split from the right so a path may contain colons: path, line, column, text.
        let parts = raw.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 3 else { return nil }
        // Find the line number by scanning from the left only when the path has no extra colons
        // is ambiguous. rg --vimgrep emits path:line:column:text. Column and line are integers,
        // so take the last three numeric-or-text fields when possible.
        guard let lineIndex = parts.firstIndex(where: { Int($0) != nil }),
              lineIndex > 0,
              lineIndex + 1 < parts.count,
              let line = Int(parts[lineIndex]) else { return nil }
        let path = normalize(path: parts[..<lineIndex].joined(separator: ":"), root: root)
        let snippetStart = lineIndex + 2
        let snippet = snippetStart < parts.count
            ? parts[snippetStart...].joined(separator: ":").trimmingCharacters(in: .whitespaces)
            : ""
        return GrepHit(path: path, line: line, snippet: snippet)
    }

    private static func ripgrepAvailable() -> Bool {
        let path = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/usr/local/bin:/opt/homebrew/bin"
        return path.split(separator: ":").contains { dir in
            FileManager.default.isExecutableFile(atPath: String(dir) + "/rg")
        }
    }

    private static func ripgrep(
        root: URL,
        query: String,
        limit: Int,
        includeHidden: Bool,
        process: CancellableProcess? = nil
    ) -> [GrepHit]? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        proc.arguments = arguments(query: query, root: root.path, limit: limit, includeHidden: includeHidden)
        let out = Pipe()
        let err = Pipe()
        proc.standardOutput = out
        proc.standardError = err
        process?.attach(proc)
        do {
            try proc.run()
        } catch {
            return nil
        }
        let (data, _) = drain(stdout: out.fileHandleForReading, stderr: err.fileHandleForReading, process: proc)
        if proc.terminationStatus == 127 { return nil }
        if proc.terminationStatus > 1 { return nil }
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        return parseVimgrep(text, root: root.path, limit: limit)
    }
}

/// Holds the live `rg` process so a newer query can terminate it.
// quill-concurrency: NSLock guards the live Process handle.
public final class CancellableProcess: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?

    public init() {}

    func attach(_ process: Process) {
        lock.lock()
        self.process = process
        lock.unlock()
    }

    public func terminate() {
        lock.lock()
        process?.terminate()
        lock.unlock()
    }
}

/// One in-flight search. A newer query terminates the previous `rg` and task.
public actor SearchSession {
    private var current: Task<[GrepHit], Never>?
    private var process: CancellableProcess?

    public init() {}

    public func search(
        root: URL,
        query: String,
        ignore: IgnoreRules = IgnoreRules(),
        limit: Int = ContentSearch.defaultLimit
    ) async -> [GrepHit] {
        process?.terminate()
        current?.cancel()
        let handle = CancellableProcess()
        process = handle
        let task = Task<[GrepHit], Never> {
            if Task.isCancelled || query.isEmpty { return [] }
            return ContentSearch.search(root: root, query: query, ignore: ignore, limit: limit, process: handle)
        }
        current = task
        let hits = await task.value
        return hits
    }
}

// quill-concurrency: NSCondition counts in-flight drain callbacks.
private final class DrainGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var remaining: Int
    init(remaining: Int) { self.remaining = remaining }
    func leave() {
        condition.lock()
        remaining -= 1
        condition.broadcast()
        condition.unlock()
    }
    func waitUntilEmpty() {
        condition.lock()
        while remaining > 0 { condition.wait() }
        condition.unlock()
    }
}

// quill-concurrency: NSLock guards the accumulated bytes.
private final class LockedData: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    func set(_ data: Data) {
        lock.lock()
        self.data = data
        lock.unlock()
    }
    func get() -> Data {
        lock.lock()
        defer { lock.unlock() }
        return data
    }
}

/// Background file list shared by the picker, wikilink completion, and `gd`.
public actor FileIndex {
    public private(set) var files: [URL] = []
    public private(set) var root: URL?

    public init() {}

    public func rebuild(root: URL, ignore: IgnoreRules = IgnoreRules()) {
        self.root = root
        files = FileWalk.files(in: root, ignore: ignore)
    }

    public func relativePaths() -> [String] {
        guard let root else { return [] }
        return files.map { FileWalk.relative($0, root: root) }
    }
}
