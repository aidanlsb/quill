import Foundation

public struct LSPPosition: Equatable, Sendable {
    public var line: Int
    public var character: Int

    public init(line: Int, character: Int) {
        self.line = line
        self.character = character
    }

    public var json: JSONValue {
        .object(["line": .number(Double(line)), "character": .number(Double(character))])
    }

    public static func from(_ value: JSONValue) -> LSPPosition? {
        guard let o = value.object else { return nil }
        return LSPPosition(line: o["line"]?.int ?? 0, character: o["character"]?.int ?? 0)
    }

    /// Convert a Swift `Character` offset into an LSP UTF-16 position.
    public static func utf16(in text: String, characterOffset: Int) -> LSPPosition {
        let clamped = min(max(0, characterOffset), text.count)
        let idx = text.index(text.startIndex, offsetBy: clamped)
        let prefix = text[text.startIndex..<idx]
        let line = prefix.filter { $0 == "\n" }.count
        let lastNL = prefix.lastIndex(of: "\n")
        let lineStart = lastNL.map { prefix.index(after: $0) } ?? prefix.startIndex
        let linePrefix = prefix[lineStart..<idx]
        let utf16 = linePrefix.utf16.count
        return LSPPosition(line: line, character: utf16)
    }

    /// Engine and TextKit offsets are UTF-16. This does not walk grapheme clusters.
    public static func position(utf16Offset: Int, in text: String) -> LSPPosition {
        let units = Array(text.utf16)
        let clamped = min(max(0, utf16Offset), units.count)
        var line = 0
        var lineStart = 0
        var i = 0
        while i < clamped {
            if units[i] == 10 {
                line += 1
                lineStart = i + 1
            }
            i += 1
        }
        return LSPPosition(line: line, character: clamped - lineStart)
    }

    public static func utf16Offset(in text: String, position: LSPPosition) -> Int {
        let units = Array(text.utf16)
        var line = 0
        var i = 0
        while i < units.count, line < position.line {
            if units[i] == 10 { line += 1 }
            i += 1
        }
        return min(units.count, i + max(0, position.character))
    }

    public static func characterOffset(in text: String, position: LSPPosition) -> Int {
        var line = 0
        var i = text.startIndex
        while i < text.endIndex, line < position.line {
            if text[i] == "\n" { line += 1 }
            i = text.index(after: i)
        }
        var utf16Remaining = position.character
        while i < text.endIndex, utf16Remaining > 0, text[i] != "\n" {
            utf16Remaining -= text[i].utf16.count
            i = text.index(after: i)
        }
        return text.distance(from: text.startIndex, to: i)
    }
}

public struct LSPRange: Equatable, Sendable {
    public var start: LSPPosition
    public var end: LSPPosition

    public init(start: LSPPosition, end: LSPPosition) {
        self.start = start
        self.end = end
    }

    public static func from(_ value: JSONValue) -> LSPRange? {
        guard let o = value.object,
              let start = o["start"].flatMap(LSPPosition.from),
              let end = o["end"].flatMap(LSPPosition.from) else { return nil }
        return LSPRange(start: start, end: end)
    }
}

public struct CompletionItem: Equatable, Sendable {
    public var label: String
    public var detail: String?
    public var insertText: String
    public var kind: Int?

    public init(label: String, detail: String? = nil, insertText: String? = nil, kind: Int? = nil) {
        self.label = label
        self.detail = detail
        self.insertText = insertText ?? label
        self.kind = kind
    }

    public static func from(_ value: JSONValue) -> CompletionItem? {
        guard let o = value.object, let label = o["label"]?.string else { return nil }
        return CompletionItem(
            label: label,
            detail: o["detail"]?.string,
            insertText: o["insertText"]?.string ?? label,
            kind: o["kind"]?.int
        )
    }
}

public struct Location: Equatable, Sendable {
    public var uri: String
    public var range: LSPRange

    public init(uri: String, range: LSPRange) {
        self.uri = uri
        self.range = range
    }

    public static func from(_ value: JSONValue) -> Location? {
        guard let o = value.object, let uri = o["uri"]?.string else { return nil }
        let range = o["range"].flatMap(LSPRange.from) ?? LSPRange(
            start: LSPPosition(line: 0, character: 0),
            end: LSPPosition(line: 0, character: 0)
        )
        return Location(uri: uri, range: range)
    }

    public var fileURL: URL? {
        URL(string: uri)
    }
}

public struct Hover: Equatable, Sendable {
    public var contents: String

    public init(contents: String) {
        self.contents = contents
    }

    public static func from(_ value: JSONValue) -> Hover? {
        guard let o = value.object else { return nil }
        if let s = o["contents"]?.string {
            return Hover(contents: s)
        }
        if let contents = o["contents"] {
            if let s = contents.string { return Hover(contents: s) }
            if let obj = contents.object, let s = obj["value"]?.string {
                return Hover(contents: s)
            }
            if let arr = contents.array {
                let text = arr.compactMap { item -> String? in
                    if let s = item.string { return s }
                    return item.object?["value"]?.string
                }.joined(separator: "\n")
                if !text.isEmpty { return Hover(contents: text) }
            }
        }
        return nil
    }
}

public struct Diagnostic: Equatable, Sendable {
    public var range: LSPRange
    public var severity: Int
    public var message: String
    public var code: String?

    public init(range: LSPRange, severity: Int, message: String, code: String? = nil) {
        self.range = range
        self.severity = severity
        self.message = message
        self.code = code
    }

    public static func from(_ value: JSONValue) -> Diagnostic? {
        guard let o = value.object,
              let range = o["range"].flatMap(LSPRange.from),
              let message = o["message"]?.string else { return nil }
        var code: String?
        if let s = o["code"]?.string { code = s }
        else if let n = o["code"]?.int { code = String(n) }
        return Diagnostic(range: range, severity: o["severity"]?.int ?? 1, message: message, code: code)
    }
}

public struct LSPContentChange: Equatable, Sendable {
    public var range: LSPRange?
    public var text: String

    public init(range: LSPRange? = nil, text: String) {
        self.range = range
        self.text = text
    }
}

public struct ServerCapabilities: Equatable, Sendable {
    public var incrementalSync: Bool
    public var hoverProvider: Bool
    public var completionProvider: Bool
    public var definitionProvider: Bool
    public var positionEncoding: String

    public init(
        incrementalSync: Bool = false,
        hoverProvider: Bool = false,
        completionProvider: Bool = false,
        definitionProvider: Bool = false,
        positionEncoding: String = "utf-16"
    ) {
        self.incrementalSync = incrementalSync
        self.hoverProvider = hoverProvider
        self.completionProvider = completionProvider
        self.definitionProvider = definitionProvider
        self.positionEncoding = positionEncoding
    }

    public static func parse(_ value: JSONValue?) -> ServerCapabilities {
        let caps = value?.object?["capabilities"]?.object ?? [:]
        let sync = caps["textDocumentSync"]
        let incremental: Bool
        if sync?.int == 2 {
            incremental = true
        } else if sync?.object?["change"]?.int == 2 {
            incremental = true
        } else {
            incremental = false
        }
        let hover = caps["hoverProvider"]
        let hoverOn = hover?.bool == true || hover?.object != nil
        let completion = caps["completionProvider"] != nil && caps["completionProvider"] != .null
        let definition = caps["definitionProvider"]
        let definitionOn = definition?.bool == true || definition?.object != nil
        let encoding = caps["positionEncoding"]?.string ?? "utf-16"
        return ServerCapabilities(
            incrementalSync: incremental,
            hoverProvider: hoverOn,
            completionProvider: completion,
            definitionProvider: definitionOn,
            positionEncoding: encoding
        )
    }
}

public struct LSPServerConfig: Equatable, Sendable, Codable {
    public var name: String
    public var command: String
    public var arguments: [String]
    public var extensions: [String]
    public var languages: [String]
    public var rootMarkers: [String]
    public var env: [String: String]

    public init(
        name: String,
        command: String,
        arguments: [String] = [],
        extensions: [String] = [".md", ".markdown"],
        languages: [String] = ["markdown"],
        rootMarkers: [String] = [".git"],
        env: [String: String] = [:]
    ) {
        self.name = name
        self.command = command
        self.arguments = arguments
        self.extensions = extensions
        self.languages = languages
        self.rootMarkers = rootMarkers
        self.env = env
    }

    public func matches(file: URL) -> Bool {
        let ext = "." + file.pathExtension.lowercased()
        return extensions.contains(where: { $0.lowercased() == ext })
    }

    enum CodingKeys: String, CodingKey {
        case name, command, arguments, extensions, languages, rootMarkers, env
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        command = try c.decode(String.self, forKey: .command)
        arguments = try c.decodeIfPresent([String].self, forKey: .arguments) ?? []
        extensions = try c.decodeIfPresent([String].self, forKey: .extensions) ?? [".md", ".markdown"]
        languages = try c.decodeIfPresent([String].self, forKey: .languages) ?? ["markdown"]
        rootMarkers = try c.decodeIfPresent([String].self, forKey: .rootMarkers) ?? [".git"]
        env = try c.decodeIfPresent([String: String].self, forKey: .env) ?? [:]
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(name, forKey: .name)
        try c.encode(command, forKey: .command)
        try c.encode(arguments, forKey: .arguments)
        try c.encode(extensions, forKey: .extensions)
        try c.encode(languages, forKey: .languages)
        try c.encode(rootMarkers, forKey: .rootMarkers)
        try c.encode(env, forKey: .env)
    }
}

public struct LSPSettings: Equatable, Sendable, Codable {
    public var servers: [LSPServerConfig]

    public init(servers: [LSPServerConfig] = []) {
        self.servers = servers
    }

    public static func load(from url: URL) -> LSPSettings {
        loadReporting(from: url).settings
    }

    public static func loadReporting(from url: URL) -> (settings: LSPSettings, error: String?) {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return (LSPSettings(), nil)
        }
        do {
            let data = try Data(contentsOf: url)
            let decoded = try JSONDecoder().decode(LSPSettings.self, from: data)
            return (decoded, nil)
        } catch {
            return (LSPSettings(), "config: \(error.localizedDescription)")
        }
    }

    public func server(for file: URL) -> LSPServerConfig? {
        servers.first { $0.matches(file: file) }
    }

    public func servers(for file: URL) -> [LSPServerConfig] {
        servers.filter { $0.matches(file: file) }
    }
}

public enum WorkspaceRoot {
    public static func find(from fileOrFolder: URL, markers: [String]) -> URL {
        var dir = fileOrFolder.hasDirectoryPath ? fileOrFolder : fileOrFolder.deletingLastPathComponent()
        let fm = FileManager.default
        while true {
            for marker in markers {
                if fm.fileExists(atPath: dir.appendingPathComponent(marker).path) {
                    return dir
                }
            }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { return fileOrFolder.hasDirectoryPath ? fileOrFolder : fileOrFolder.deletingLastPathComponent() }
            dir = parent
        }
    }
}
