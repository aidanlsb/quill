import Foundation

/// Turns the engine's ordered UTF-16 edits into LSP `contentChanges`.
/// Incremental ranges are expressed against the text before each edit.
public struct DocumentSync: Equatable, Sendable {
    public var version: Int
    public private(set) var text: String
    public private(set) var pending: [LSPContentChange]

    public init(text: String = "", version: Int = 0) {
        self.text = text
        self.version = version
        self.pending = []
    }

    public mutating func reset(text: String) {
        self.text = text
        pending.removeAll()
        version += 1
    }

    public mutating func apply(edits: [(range: Range<Int>, replacement: String)]) {
        for edit in edits {
            let start = LSPPosition.position(utf16Offset: edit.range.lowerBound, in: text)
            let end = LSPPosition.position(utf16Offset: edit.range.upperBound, in: text)
            pending.append(LSPContentChange(
                range: LSPRange(start: start, end: end),
                text: edit.replacement
            ))
            text = Self.replace(text, range: edit.range, with: edit.replacement)
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

    static func replace(_ text: String, range: Range<Int>, with replacement: String) -> String {
        let units = Array(text.utf16)
        let lower = min(max(0, range.lowerBound), units.count)
        let upper = min(max(lower, range.upperBound), units.count)
        let prefix = String(decoding: units[..<lower], as: UTF16.self)
        let suffix = String(decoding: units[upper...], as: UTF16.self)
        return prefix + replacement + suffix
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
    private var crashes: [ConnectionKey: Int] = [:]
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

    public func noteCrash(_ key: ConnectionKey) {
        crashes[key, default: 0] += 1
        clients[key]?.stop()
    }

    /// Backoff after a crash: 0.25s, 0.5s, 1s, … capped at 8s.
    public func restartDelay(_ key: ConnectionKey) -> TimeInterval {
        let n = crashes[key] ?? 0
        return min(8, pow(2, Double(max(0, n - 1))) * 0.25)
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

    public func stopAll() {
        for client in clients.values { client.stop() }
        clients.removeAll()
        openURIs.removeAll()
    }
}
