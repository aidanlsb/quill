import Foundation
import QuillLSP
import QuillVim

/// One open file's language server session. Created only when a server matches
/// the file. Edits in one turn share a single `didChange`.
@MainActor
final class LSPDocumentLink {
    /// How many links have been created in this process. Stays put when no server matches.
    static var creationCount = 0

    let uri: String
    private(set) var clients: [LSPClient] = []
    private var sync: DocumentSync
    private var flushScheduled = false
    private var closed = false

    init(uri: String, text: String, version: Int) {
        self.uri = uri
        self.sync = DocumentSync(text: text, version: version)
        Self.creationCount += 1
    }

    func attach(_ clients: [LSPClient]) {
        guard !closed else { return }
        self.clients = clients
        flush()
    }

    func didEdit(_ edits: [TextEdit]) {
        guard !closed, !edits.isEmpty else { return }
        sync.apply(edits: edits.map { ($0.range, $0.replacement) })
        guard !flushScheduled else { return }
        flushScheduled = true
        Task { @MainActor in
            self.flush()
        }
    }

    /// Sends any pending edits. Requests and saves call this before they talk to the server.
    func flush() {
        flushScheduled = false
        guard !closed, !clients.isEmpty else { return }
        let flushed = sync.flush(incremental: true)
        guard !flushed.changes.isEmpty else { return }
        let full = LSPContentChange(text: sync.text)
        for client in clients {
            let changes = client.capabilities.incrementalSync ? flushed.changes : [full]
            client.didChange(uri: uri, version: flushed.version, changes: changes)
        }
    }

    func requestClients() -> [LSPClient] {
        flush()
        return clients
    }

    func hover(at position: LSPPosition) async -> Hover? {
        flush()
        guard let client = clients.first, client.isRunning else { return nil }
        return try? await client.hover(uri: uri, position: position)
    }

    func didSave(text: String) {
        flush()
        guard !closed else { return }
        for client in clients {
            client.didSave(uri: uri, text: text)
        }
    }

    func close() {
        closed = true
        flushScheduled = false
        clients = []
    }
}
