import Foundation

/// A file the launcher asked Quill to open, with an optional 1-based cursor.
public struct LaunchTarget: Equatable, Sendable, Codable {
    /// What `column` counts. People and `file:line:col` tools count characters;
    /// language servers count UTF-16 units.
    public enum ColumnUnit: Equatable, Sendable, Codable {
        case character
        case utf16
    }

    public var path: String
    public var line: Int?
    public var column: Int?
    public var columnUnit: ColumnUnit

    public init(path: String, line: Int? = nil, column: Int? = nil, columnUnit: ColumnUnit = .character) {
        self.path = path
        self.line = line
        self.column = column
        self.columnUnit = columnUnit
    }
}

/// Parses `quill` arguments and the `quill://open` URL the launcher hands the app.
/// `path:line`, `path:line:col`, and vim-style `+N` before a path. Line and column are 1-based.
public enum LaunchRequest {
    public static func parse(_ arguments: [String]) -> [LaunchTarget] {
        var targets: [LaunchTarget] = []
        var pendingLine: Int?
        var skipNext = false
        for arg in arguments {
            if skipNext {
                skipNext = false
                continue
            }
            if arg == "--wait" || arg == "--" || arg == "--quill-standalone" { continue }
            if arg == "--quill-socket" {
                skipNext = true
                continue
            }
            if let url = URL(string: arg), url.scheme == "quill", let target = target(from: url) {
                pendingLine = nil
                targets.append(target)
                continue
            }
            if let line = plusLine(arg) {
                pendingLine = line
                continue
            }
            var (path, line, column) = splitLocation(arg)
            if line == nil, let pendingLine {
                line = pendingLine
            }
            pendingLine = nil
            targets.append(LaunchTarget(path: path, line: line, column: column))
        }
        return targets
    }

    /// `note.md:12` → line 12. `note.md:12:3` → line 12, column 3.
    /// A non-numeric suffix stays part of the path (`foo:bar`).
    public static func splitLocation(_ raw: String) -> (path: String, line: Int?, column: Int?) {
        if let (head, column) = trailingNumber(raw), let (path, line) = trailingNumber(head) {
            return (path, line, column)
        }
        if let (path, line) = trailingNumber(raw) {
            return (path, line, nil)
        }
        return (raw, nil, nil)
    }

    public static func standardized(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }

    /// True when `target` is the buffer already on screen, including a directory listing.
    public static func sameFile(open path: String?, isDirectory: Bool, target: String) -> Bool {
        guard let path, !path.isEmpty, !target.isEmpty else { return false }
        let left = standardized(path)
        let right = standardized(target)
        if left == right { return true }
        if isDirectory {
            return trimmingSlash(left) == trimmingSlash(right)
        }
        return false
    }

    public static func url(for target: LaunchTarget) -> URL {
        var components = URLComponents()
        components.scheme = "quill"
        components.host = "open"
        var items = [URLQueryItem(name: "path", value: target.path)]
        if let line = target.line {
            items.append(URLQueryItem(name: "line", value: String(line)))
        }
        if let column = target.column {
            items.append(URLQueryItem(name: "column", value: String(column)))
        }
        components.queryItems = items
        return components.url ?? URL(string: "quill://open")!
    }

    public static func urls(for targets: [LaunchTarget]) -> [String] {
        targets.map { url(for: $0).absoluteString }
    }

    /// Absolute path, creating a missing file the way `quill note.md` always has.
    /// `cwd` joins a relative path. `.` stays a directory. An existing file is not truncated.
    public static func prepare(_ arguments: [String], cwd: String) throws -> [LaunchTarget] {
        try parse(arguments).map { try materialize($0, cwd: cwd) }
    }

    public static func materialize(_ target: LaunchTarget, cwd: String) throws -> LaunchTarget {
        let joined = target.path.hasPrefix("/") ? target.path : join(cwd, target.path)
        let url = URL(fileURLWithPath: joined).standardizedFileURL
        let base = url.lastPathComponent
        let directory = url.deletingLastPathComponent()
        let fm = FileManager.default
        if base != ".", base != "..", !fm.fileExists(atPath: url.path) {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            guard fm.createFile(atPath: url.path, contents: Data()) else {
                throw LaunchMaterializeError.createFailed(url.path)
            }
        }
        let resolvedDirectory: String
        if fm.fileExists(atPath: directory.path) {
            resolvedDirectory = directory.resolvingSymlinksInPath().standardizedFileURL.path
        } else {
            resolvedDirectory = directory.standardizedFileURL.path
        }
        var copy = target
        if base == "." {
            copy.path = resolvedDirectory
        } else if resolvedDirectory == "/" {
            copy.path = "/" + base
        } else {
            copy.path = resolvedDirectory + "/" + base
        }
        return copy
    }

    private static func join(_ cwd: String, _ relative: String) -> String {
        if cwd == "/" { return "/" + relative }
        if cwd.hasSuffix("/") { return cwd + relative }
        return cwd + "/" + relative
    }

    public static func target(from url: URL) -> LaunchTarget? {
        guard url.scheme == "quill" else { return nil }
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let items = components.queryItems ?? []
        func value(_ name: String) -> String? {
            items.first { $0.name == name }?.value
        }
        guard let path = value("path"), !path.isEmpty else { return nil }
        let line = value("line").flatMap(Int.init).flatMap { $0 >= 1 ? $0 : nil }
        let column = value("column").flatMap(Int.init).flatMap { $0 >= 1 ? $0 : nil }
        return LaunchTarget(path: path, line: line, column: column)
    }

    private static func plusLine(_ arg: String) -> Int? {
        guard arg.count > 1, arg.first == "+" else { return nil }
        let digits = arg.dropFirst()
        guard digits.allSatisfy(\.isNumber), let n = Int(digits), n >= 1 else { return nil }
        return n
    }

    /// The trailing `:digits` segment, when the head is non-empty and the number is ≥ 1.
    private static func trailingNumber(_ raw: String) -> (head: String, value: Int)? {
        guard let colon = raw.lastIndex(of: ":"), colon > raw.startIndex else { return nil }
        let digits = raw[raw.index(after: colon)...]
        guard !digits.isEmpty, digits.allSatisfy(\.isNumber), let n = Int(digits), n >= 1 else { return nil }
        let head = String(raw[..<colon])
        guard !head.isEmpty else { return nil }
        return (head, n)
    }

    private static func trimmingSlash(_ path: String) -> String {
        path.hasSuffix("/") && path.count > 1 ? String(path.dropLast()) : path
    }
}

public enum LaunchMaterializeError: Error, Equatable {
    case createFailed(String)
}
