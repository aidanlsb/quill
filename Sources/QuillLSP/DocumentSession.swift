import Foundation

/// One open file's sync state on a language server. `didOpen` always sends the
/// text this session started with, at its starting version. Later edits are
/// `didChange`. `close` sends `didClose` so a later session can `didOpen` at
/// version 1 against a server that has forgotten the document.
public final class LSPDocumentSession {
    public let uri: String
    public private(set) var clients: [LSPClient] = []
    private var sync: DocumentSync
    private let initialText: String
    private let openVersion: Int
    private var closed = false

    public init(uri: String, text: String, version: Int = 1) {
        self.uri = uri
        self.initialText = text
        self.openVersion = version
        self.sync = DocumentSync(text: text, version: version)
    }

    public var isClosed: Bool { closed }

    /// Remember clients that were already opened by the caller (tests).
    public func store(_ clients: [LSPClient]) {
        guard !closed else { return }
        self.clients = clients
    }

    /// `reopen` sends `didClose` first when the server still has this URI.
    public func bind(_ client: LSPClient, languageId: String, reopen: Bool) {
        guard !closed else { return }
        if !clients.contains(where: { $0 === client }) {
            clients.append(client)
        }
        if reopen {
            client.didClose(uri: uri)
        }
        client.didOpen(uri: uri, languageId: languageId, version: openVersion, text: initialText)
    }

    public func apply(edits: [(range: Range<Int>, replacement: String)]) {
        guard !closed, !edits.isEmpty else { return }
        sync.apply(edits: edits)
    }

    public func flush() {
        guard !closed, !clients.isEmpty else { return }
        let flushed = sync.flush(incremental: true)
        guard !flushed.changes.isEmpty else { return }
        let full = LSPContentChange(text: sync.text)
        for client in clients {
            let changes = client.capabilities.incrementalSync ? flushed.changes : [full]
            client.didChange(uri: uri, version: flushed.version, changes: changes)
        }
    }

    public func didSave(text: String) {
        flush()
        guard !closed else { return }
        for client in clients {
            client.didSave(uri: uri, text: text)
        }
    }

    public func close() {
        guard !closed else { return }
        flush()
        closed = true
        let openClients = clients
        clients = []
        for client in openClients {
            client.didClose(uri: uri)
        }
    }
}
