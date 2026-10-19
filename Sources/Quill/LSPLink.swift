import Foundation
import QuillLSP
import QuillVim
import QuillWorkspace

/// One open file's language server session. Edits in one turn share a single `didChange`.
/// `didOpen` sends the text the session started with. `close` sends `didClose`.
@MainActor
final class LSPLink {
    static var creationCount = 0

    let session: LSPDocumentSession
    private let servers: LanguageServerManager
    private var keys: [LanguageServerManager.ConnectionKey] = []
    private var flushScheduled = false

    var uri: String { session.uri }

    init(
        uri: String,
        text: String,
        version: Int,
        servers: LanguageServerManager = LanguageServerManager()
    ) {
        session = LSPDocumentSession(uri: uri, text: text, version: version)
        self.servers = servers
        Self.creationCount += 1
    }

    /// Tests attach a client that is already open. This does not send `didOpen`.
    func attach(_ clients: [LSPClient]) {
        session.store(clients)
        flush()
    }

    func bind(_ client: LSPClient, languageId: String, reopen: Bool) {
        session.bind(client, languageId: languageId, reopen: reopen)
    }

    func remember(_ key: LanguageServerManager.ConnectionKey) {
        if !keys.contains(key) { keys.append(key) }
    }

    func didEdit(_ edits: [TextEdit]) {
        guard !session.isClosed, !edits.isEmpty else { return }
        session.apply(edits: edits.map { ($0.range, $0.replacement) })
        guard !flushScheduled else { return }
        flushScheduled = true
        Task { @MainActor in
            self.flush()
        }
    }

    func flush() {
        flushScheduled = false
        session.flush()
    }

    func requestClients() -> [LSPClient] {
        flush()
        return session.clients
    }

    func hover(at position: LSPPosition) async -> Hover? {
        flush()
        guard let client = session.clients.first, client.isRunning else { return nil }
        return try? await client.hover(uri: uri, position: position)
    }

    func didSave(text: String) {
        session.didSave(text: text)
    }

    func close() async {
        session.close()
        let uri = session.uri
        for key in keys {
            await servers.trackClose(key: key, uri: uri)
        }
        await servers.removeHandlers(uri: uri)
    }
}

extension AppModel {
    var hasLanguageServer: Bool { lsp != nil }

    /// Tests install a scripted client without spawning a server process.
    func adoptLanguageLink(_ link: LSPLink) {
        let previous = lsp
        installLSP(link)
        guard let previous else { return }
        Task { await previous.close() }
    }

    func useLSPClient(_ factory: @escaping (LSPServerConfig, URL) async throws -> LSPClient) {
        session.lspClientFactory = factory
    }

    func scheduleLSP() {
        let previous = lsp
        let generation = document.generation
        let url = document.url
        let text = document.engine.text
        let configs = url.map { config.lsp.servers(for: $0) } ?? []
        let prior = session.lspChain
        if document.isDirectory || url == nil || configs.isEmpty {
            installLSP(nil)
            session.lspChain = Task { @MainActor in
                _ = await prior?.value
                await previous?.close()
            }
            return
        }
        let link = LSPLink(uri: url!.absoluteString, text: text, servers: session.servers)
        installLSP(link)
        session.lspChain = Task { @MainActor in
            _ = await prior?.value
            await previous?.close()
            guard self.document.generation == generation, self.lsp === link else {
                await link.close()
                if self.lsp === link { self.installLSP(nil) }
                return
            }
            await self.connect(link, url: url!, generation: generation)
            guard self.document.generation == generation, self.lsp === link else {
                await link.close()
                if self.lsp === link { self.installLSP(nil) }
            }
        }
    }

    func connect(_ link: LSPLink, url: URL, generation: Int) async {
        let language = session.fileTypes.languageId(for: url)
        for server in config.lsp.servers(for: url) {
            let root = WorkspaceRoot.find(
                from: url,
                markers: server.rootMarkers.isEmpty ? [".git"] : server.rootMarkers
            )
            let client: LSPClient
            do {
                if let factory = session.lspClientFactory {
                    client = try await factory(server, root)
                } else {
                    client = try await session.servers.connection(config: server, root: root)
                }
            } catch {
                continue
            }
            guard document.generation == generation, lsp === link else { return }
            await session.servers.installRouterIfNeeded(on: client)
            let hop = session.hop
            let uri = link.uri
            await session.servers.setHandlers(
                uri: uri,
                diagnostics: { diags in
                    Task { @MainActor in
                        hop.model?.receiveDiagnostics(diags, uri: uri, generation: generation)
                    }
                },
                applyEdit: { edit in
                    Task { @MainActor in
                        hop.model?.receiveApplyEdit(edit, generation: generation)
                    }
                }
            )
            let key = LanguageServerManager.ConnectionKey(name: server.name, root: root.path)
            let already = await session.servers.isOpen(key: key, uri: uri)
            guard document.generation == generation, lsp === link else { return }
            link.bind(client, languageId: language, reopen: already)
            if !already {
                await session.servers.trackOpen(key: key, uri: uri)
            }
            link.remember(key)
            link.flush()
            message = "LSP: \(server.name)"
        }
    }

    func receiveDiagnostics(_ diagnostics: [Diagnostic], uri: String, generation: Int) {
        guard document.generation == generation, document.url?.absoluteString == uri else { return }
        self.diagnostics = diagnostics
    }

    func receiveApplyEdit(_ edit: WorkspaceEdit, generation: Int) {
        guard document.generation == generation else { return }
        applyWorkspaceEdit(edit)
    }

    func lspDidSave(_ text: String, generation: Int) {
        guard document.generation == generation else { return }
        lsp?.didSave(text: text)
    }

    func goToDefinition() {
        guard let url = document.url, let link = lsp else {
            followWikilink()
            return
        }
        let generation = document.generation
        let cursor = document.engine.cursor
        let position = LSPPosition(document.engine.buffer.position(of: cursor))
        let uri = url.absoluteString
        Task {
            let clients = link.requestClients()
            for client in clients where client.capabilities.definitionProvider || client.isRunning {
                if let locs = try? await client.definition(uri: uri, position: position),
                   let first = locs.first, let dest = first.fileURL {
                    guard self.document.generation == generation, self.document.engine.cursor == cursor else { return }
                    self.openTarget(LaunchTarget(
                        path: dest.path,
                        line: first.range.start.line + 1,
                        column: first.range.start.character + 1,
                        columnUnit: .utf16
                    ))
                    return
                }
            }
            guard self.document.generation == generation, self.document.engine.cursor == cursor else { return }
            self.followWikilink()
        }
    }

    func showHover() {
        if let text = diagnosticMessage(at: document.engine.cursor) {
            setIfChanged(\.message, text)
            return
        }
        guard let link = lsp else {
            setIfChanged(\.message, "No info")
            return
        }
        session.hoverGeneration += 1
        let token = session.hoverGeneration
        let generation = document.generation
        let position = LSPPosition(document.engine.buffer.position(of: document.engine.cursor))
        Task {
            let hover = await link.hover(at: position)
            guard token == self.session.hoverGeneration, self.document.generation == generation else { return }
            let line = hover?.contents.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
            self.setIfChanged(\.message, line.isEmpty ? "No info" : line)
        }
    }

    func applyWorkspaceEdit(_ edit: WorkspaceEdit) {
        guard let url = document.url else {
            message = "Edit applies to another file"
            return
        }
        let edits = edit.bufferEdits(in: document.engine.text, file: url).map {
            TextEdit(range: $0.range, replacement: $0.replacement)
        }
        let foreign = edit.containsEdits(outside: url)
        if edits.isEmpty {
            if foreign { message = "Edit applies to another file" }
            return
        }
        apply(document.engine.applyHostEdits(edits))
        if foreign { message = "Edit applies to another file" }
    }

    func rebuildDiagnosticRanges() {
        diagnosticRanges = diagnostics.map { diag in
            let start = document.engine.buffer.offset(of: diag.range.start.textPosition)
            let end = document.engine.buffer.offset(of: diag.range.end.textPosition)
            return (NSRange(location: start, length: max(0, end - start)), diag.severity)
        }
        guard let editor else { return }
        let current = editor.diagnosticRanges
        let changed = current.count != diagnosticRanges.count
            || current.map(\.0) != diagnosticRanges.map(\.0)
        guard changed else { return }
        editor.diagnosticRanges = diagnosticRanges
        editor.queueRestyle()
    }

    func diagnosticMessage(at cursor: Int) -> String? {
        for (index, range) in diagnosticRanges.enumerated() where diagnostics.indices.contains(index) {
            let ns = range.0
            if ns.length == 0 {
                if cursor == ns.location { return diagnostics[index].message }
            } else if cursor >= ns.location, cursor < ns.location + ns.length {
                return diagnostics[index].message
            }
        }
        return nil
    }
}
