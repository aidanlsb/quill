import Foundation
import QuillText

/// Turns the engine's ordered UTF-16 edits into LSP `contentChanges`.
/// Incremental ranges are expressed against the text before each edit. The line
/// index is updated with each edit, so a keystroke does not re-scan the document.
public struct DocumentSync: Equatable, Sendable {
    public var version: Int
    public private(set) var text: String
    public private(set) var lines: LineIndex
    public private(set) var pending: [LSPContentChange]

    public init(text: String = "", version: Int = 0) {
        self.text = text
        self.lines = LineIndex(text)
        self.version = version
        self.pending = []
    }

    public mutating func reset(text: String) {
        self.text = text
        lines = LineIndex(text)
        pending.removeAll()
        version += 1
    }

    public mutating func apply(edits: [(range: Range<Int>, replacement: String)]) {
        for edit in edits {
            let lower = min(max(0, edit.range.lowerBound), lines.utf16Count)
            let range = lower..<min(max(lower, edit.range.upperBound), lines.utf16Count)
            pending.append(LSPContentChange(
                range: LSPRange(start: LSPPosition(lines.position(of: range.lowerBound)), end: LSPPosition(lines.position(of: range.upperBound))),
                text: edit.replacement
            ))
            Self.replace(&text, range: range, with: edit.replacement)
            lines.replace(range, with: edit.replacement)
        }
        if !edits.isEmpty { version += 1 }
    }

    /// Full document when the server cannot do incremental sync.
    public mutating func flush(incremental: Bool) -> (version: Int, changes: [LSPContentChange]) {
        let changes: [LSPContentChange]
        if incremental {
            changes = pending
        } else if pending.isEmpty {
            changes = []
        } else {
            changes = [LSPContentChange(text: text)]
        }
        pending.removeAll()
        return (version, changes)
    }

    /// `range` is in UTF-16 units and must not split a surrogate pair.
    static func replace(_ text: inout String, range: Range<Int>, with replacement: String) {
        let units = text.utf16
        let lower = units.index(units.startIndex, offsetBy: range.lowerBound)
        let upper = units.index(lower, offsetBy: range.count)
        text.replaceSubrange(lower..<upper, with: replacement)
    }
}

/// One live connection per server and workspace root. Documents share it.
public actor LanguageServerManager {
    public struct ConnectionKey: Hashable, Sendable {
        public var name: String
        public var root: String

        public init(name: String, root: String) {
            self.name = name
            self.root = root
        }
    }

    private var clients: [ConnectionKey: LSPClient] = [:]
    private var openURIs: [ConnectionKey: Set<String>] = [:]

    public init() {}

    public func connection(config: LSPServerConfig, root: URL) throws -> LSPClient {
        let key = ConnectionKey(name: config.name, root: root.path)
        if let existing = clients[key], existing.isRunning {
            return existing
        }
        let client = LSPClient(config: config)
        try client.start(root: root)
        clients[key] = client
        return client
    }

    /// Reuse a client the host already attached (tests, or a server that is already up).
    public func adopt(_ client: LSPClient, root: URL) -> ConnectionKey {
        let key = ConnectionKey(name: client.config.name, root: root.path)
        clients[key] = client
        return key
    }

    public func client(_ key: ConnectionKey) -> LSPClient? {
        clients[key]
    }

    public func trackOpen(key: ConnectionKey, uri: String) {
        openURIs[key, default: []].insert(uri)
    }

    public func trackClose(key: ConnectionKey, uri: String) {
        openURIs[key]?.remove(uri)
    }

    public func isOpen(key: ConnectionKey, uri: String) -> Bool {
        openURIs[key]?.contains(uri) ?? false
    }
}
