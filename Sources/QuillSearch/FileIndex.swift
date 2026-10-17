import Foundation

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

public struct IgnoreRules: Equatable, Sendable {
    public var patterns: [String]

    public init(patterns: [String] = []) {
        self.patterns = patterns
    }

    public static func load(from root: URL, fileManager: FileManager = .default) -> IgnoreRules {
        let gitignore = root.appendingPathComponent(".gitignore")
        guard let data = try? String(contentsOf: gitignore, encoding: .utf8) else {
            return IgnoreRules()
        }
        let patterns = data.split(separator: "\n").compactMap { line -> String? in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { return nil }
            return String(trimmed)
        }
        return IgnoreRules(patterns: patterns)
    }

    public func ignores(relativePath: String, isDirectory: Bool) -> Bool {
        let parts = relativePath.split(separator: "/").map(String.init)
        if let first = parts.first, first.hasPrefix("."), first != "." { return true }
        if parts.contains(where: { $0 == ".git" || $0 == ".svn" || $0 == ".hg" }) { return true }
        for pattern in patterns {
            if match(pattern: pattern, path: relativePath, isDirectory: isDirectory) {
                return true
            }
        }
        return false
    }

    private func match(pattern: String, path: String, isDirectory: Bool) -> Bool {
        var pat = pattern
        if pat.hasPrefix("/") { pat.removeFirst() }
        let dirOnly = pat.hasSuffix("/")
        if dirOnly {
            pat.removeLast()
            if !isDirectory && !path.hasSuffix("/") { /* files inside ignored dirs handled by walk */ }
        }
        if pat.contains("*") {
            return glob(pat, path) || glob(pat, (path as NSString).lastPathComponent)
        }
        if path == pat { return true }
        if path.hasPrefix(pat + "/") { return true }
        if (path as NSString).lastPathComponent == pat { return true }
        if dirOnly, isDirectory, (path as NSString).lastPathComponent == pat { return true }
        return false
    }

    private func glob(_ pattern: String, _ value: String) -> Bool {
        let escaped = NSRegularExpression.escapedPattern(for: pattern)
            .replacingOccurrences(of: "\\*", with: ".*")
            .replacingOccurrences(of: "\\?", with: ".")
        let regex = (try? NSRegularExpression(pattern: "^\(escaped)$")) ?? (try? NSRegularExpression(pattern: "^$"))
        guard let regex else { return false }
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        return regex.firstMatch(in: value, range: range) != nil
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
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        while let item = enumerator.nextObject() as? URL {
            let rel = item.path.replacingOccurrences(of: root.path.hasSuffix("/") ? root.path : root.path + "/", with: "")
            let isDir = (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if isDir {
                let name = item.lastPathComponent
                if name.hasPrefix(".") || name == ".git" || ignore.ignores(relativePath: rel, isDirectory: true) {
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
}

public enum ContentSearch {
    /// Built-in line scan. `relativePath` is stored on hits.
    public static func grep(
        query: String,
        files: [(path: String, contents: String)],
        limit: Int = 200
    ) -> [GrepHit] {
        if query.isEmpty { return [] }
        var hits: [GrepHit] = []
        for file in files {
            let lines = file.contents.split(separator: "\n", omittingEmptySubsequences: false)
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
    public static func search(
        root: URL,
        query: String,
        ignore: IgnoreRules = IgnoreRules(),
        fileManager: FileManager = .default
    ) -> [GrepHit] {
        if query.isEmpty { return [] }
        if ripgrepAvailable(), let rg = ripgrep(root: root, query: query) { return rg }
        let urls = FileWalk.files(in: root, ignore: ignore, fileManager: fileManager)
        let files: [(String, String)] = urls.compactMap { url in
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
            let rel = url.path.replacingOccurrences(of: root.path + "/", with: "")
            return (rel, text)
        }
        return grep(query: query, files: files)
    }

    private static func ripgrepAvailable() -> Bool {
        let path = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/usr/local/bin:/opt/homebrew/bin"
        return path.split(separator: ":").contains { dir in
            FileManager.default.isExecutableFile(atPath: String(dir) + "/rg")
        }
    }

    private static func ripgrep(root: URL, query: String) -> [GrepHit]? {
        let exe = "/usr/bin/env"
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: exe)
        proc.arguments = ["rg", "--vimgrep", "--hidden", "--glob", "!.git", "-S", "-n", query, root.path]
        let out = Pipe()
        let err = Pipe()
        proc.standardOutput = out
        proc.standardError = err
        do {
            try proc.run()
        } catch {
            return nil
        }
        proc.waitUntilExit()
        if proc.terminationStatus == 127 || proc.terminationStatus == 1 && out.fileHandleForReading.availableData.isEmpty {
            // 127 = not found via env; status 1 with no output may be no matches
        }
        if proc.terminationStatus > 1 { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        if text.isEmpty, proc.terminationStatus == 127 { return nil }
        var hits: [GrepHit] = []
        for raw in text.split(separator: "\n") {
            let parts = raw.split(separator: ":", maxSplits: 3, omittingEmptySubsequences: false)
            guard parts.count >= 3, let line = Int(parts[1]) else { continue }
            let snippet = parts.count >= 4 ? String(parts[3]) : String(parts.dropFirst(2).joined(separator: ":"))
            hits.append(GrepHit(path: String(parts[0]), line: line, snippet: snippet.trimmingCharacters(in: .whitespaces)))
        }
        return hits
    }
}
