import Foundation

/// Generic Language Server Protocol 3.17 client over JSON-RPC stdio.
/// Nothing here is server-specific: command, args, root markers, and
/// initialization options come from `LSPServerConfig`.
public final class LSPClient: @unchecked Sendable {
    public let config: LSPServerConfig
    public private(set) var isRunning = false
    public private(set) var capabilities = ServerCapabilities()
    public var onDiagnostics: ((String, [Diagnostic]) -> Void)?
    public var onLog: ((String) -> Void)?
    /// `workspace/applyEdit`. Invoked on the JSON-RPC reader thread; the host must hop off it.
    public var onApplyEdit: ((WorkspaceEdit) -> Void)?

    private var session: JSONRPCSession?
    private var process: Process?
    private var rootURI: String = ""
    private var workspaceFolders: [JSONValue] = []

    public init(config: LSPServerConfig) {
        self.config = config
    }

    /// Start using an already-connected transport (tests).
    public func attach(session: JSONRPCSession, rootURI: String) throws {
        self.session = session
        self.rootURI = rootURI
        self.workspaceFolders = [.object([
            "uri": .string(rootURI),
            "name": .string(URL(string: rootURI)?.lastPathComponent ?? "workspace"),
        ])]
        session.onNotification = { [weak self] method, params in
            self?.handleNotification(method, params)
        }
        session.onServerRequest = { [weak self] _, method, params in
            self?.handleServerRequest(method, params)
        }
        session.startReading()
        try initialize()
        isRunning = true
    }

    /// Spawn `config.command` and talk JSON-RPC over stdin/stdout.
    /// Throws `JSONRPCError.serverUnavailable` if the executable is missing so
    /// the host can keep editing without language features.
    public func start(root: URL) throws {
        let exe = resolveExecutable(config.command)
        guard let exe else {
            throw JSONRPCError.serverUnavailable(config.command)
        }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: exe)
        proc.arguments = config.arguments
        proc.currentDirectoryURL = root
        if !config.env.isEmpty {
            var env = ProcessInfo.processInfo.environment
            for (k, v) in config.env { env[k] = v }
            proc.environment = env
        }
        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        proc.standardInput = stdin
        proc.standardOutput = stdout
        proc.standardError = stderr
        do {
            try proc.run()
        } catch {
            throw JSONRPCError.serverUnavailable(config.command)
        }
        self.process = proc
        drainStderr(stderr.fileHandleForReading)
        let transport = ProcessTransport(input: stdin.fileHandleForWriting, output: stdout.fileHandleForReading)
        let session = JSONRPCSession(transport: transport)
        try attach(session: session, rootURI: root.absoluteString)
        watchExit(proc)
    }

    /// `shutdown`, then `exit`. A missing server still closes the transport.
    public func stop() {
        if isRunning, session != nil {
            _ = try? session?.request(method: "shutdown", params: .null, timeout: 1)
            try? session?.notify(method: "exit")
        }
        session?.close()
        process?.terminate()
        isRunning = false
    }

    public func didOpen(uri: String, languageId: String, version: Int, text: String) {
        try? session?.notify(method: "textDocument/didOpen", params: .object([
            "textDocument": .object([
                "uri": .string(uri),
                "languageId": .string(languageId),
                "version": .number(Double(version)),
                "text": .string(text),
            ]),
        ]))
    }

    public func didChange(uri: String, version: Int, text: String) {
        didChange(uri: uri, version: version, changes: [LSPContentChange(text: text)])
    }

    public func didChange(uri: String, version: Int, changes: [LSPContentChange]) {
        let encoded: [JSONValue] = changes.map { change in
            var obj: [String: JSONValue] = ["text": .string(change.text)]
            if let range = change.range {
                obj["range"] = .object([
                    "start": range.start.json,
                    "end": range.end.json,
                ])
            }
            return .object(obj)
        }
        try? session?.notify(method: "textDocument/didChange", params: .object([
            "textDocument": .object([
                "uri": .string(uri),
                "version": .number(Double(version)),
            ]),
            "contentChanges": .array(encoded),
        ]))
    }

    public func didSave(uri: String, text: String? = nil) {
        let doc: [String: JSONValue] = ["uri": .string(uri)]
        var params: [String: JSONValue] = ["textDocument": .object(doc)]
        if let text { params["text"] = .string(text) }
        try? session?.notify(method: "textDocument/didSave", params: .object(params))
    }

    public func didClose(uri: String) {
        try? session?.notify(method: "textDocument/didClose", params: .object([
            "textDocument": .object(["uri": .string(uri)]),
        ]))
    }

    public func completion(uri: String, position: LSPPosition) throws -> [CompletionItem] {
        let result = try session?.request(method: "textDocument/completion", params: textDocumentPosition(uri, position))
        return parseCompletion(result ?? .null)
    }

    public func definition(uri: String, position: LSPPosition) throws -> [Location] {
        let result = try session?.request(method: "textDocument/definition", params: textDocumentPosition(uri, position))
        return parseLocations(result ?? .null)
    }

    public func hover(uri: String, position: LSPPosition) throws -> Hover? {
        let result = try session?.request(method: "textDocument/hover", params: textDocumentPosition(uri, position))
        return Hover.from(result ?? .null)
    }

    public func completion(uri: String, position: LSPPosition) async throws -> [CompletionItem] {
        let result = try await session?.request(method: "textDocument/completion", params: textDocumentPosition(uri, position))
        return parseCompletion(result ?? .null)
    }

    public func definition(uri: String, position: LSPPosition) async throws -> [Location] {
        let result = try await session?.request(method: "textDocument/definition", params: textDocumentPosition(uri, position))
        return parseLocations(result ?? .null)
    }

    public func hover(uri: String, position: LSPPosition) async throws -> Hover? {
        let result = try await session?.request(method: "textDocument/hover", params: textDocumentPosition(uri, position))
        return Hover.from(result ?? .null)
    }

    public func references(uri: String, position: LSPPosition) async throws -> [Location] {
        let params = JSONValue.object([
            "textDocument": .object(["uri": .string(uri)]),
            "position": position.json,
            "context": .object(["includeDeclaration": .bool(true)]),
        ])
        guard let session else { throw JSONRPCError.closed }
        let result = try await session.request(method: "textDocument/references", params: params)
        return parseLocations(result)
    }

    public func codeAction(uri: String, range: LSPRange, diagnostics: [Diagnostic]) async throws -> [CodeAction] {
        let params = JSONValue.object([
            "textDocument": .object(["uri": .string(uri)]),
            "range": range.json,
            "context": .object(["diagnostics": .array(diagnostics.map(\.json))]),
        ])
        guard let session else { throw JSONRPCError.closed }
        let result = try await session.request(method: "textDocument/codeAction", params: params)
        return CodeAction.list(from: result)
    }

    public func executeCommand(command: String, arguments: JSONValue?) async throws -> JSONValue {
        var fields: [String: JSONValue] = ["command": .string(command)]
        if let arguments { fields["arguments"] = arguments }
        guard let session else { throw JSONRPCError.closed }
        return try await session.request(method: "workspace/executeCommand", params: .object(fields))
    }

    private func initialize() throws {
        let caps = JSONValue.object([
            "textDocument": .object([
                "synchronization": .object([
                    "didSave": .bool(true),
                    "dynamicRegistration": .bool(false),
                ]),
                "completion": .object(["dynamicRegistration": .bool(false)]),
                "hover": .object(["contentFormat": .array([.string("plaintext"), .string("markdown")])]),
                "definition": .object(["dynamicRegistration": .bool(false)]),
                "references": .object(["dynamicRegistration": .bool(false)]),
                "codeAction": .object([
                    "dynamicRegistration": .bool(false),
                    "codeActionLiteralSupport": .object([
                        "codeActionKind": .object([
                            "valueSet": .array([
                                .string("quickfix"),
                                .string("refactor"),
                                .string("source"),
                            ]),
                        ]),
                    ]),
                ]),
                "publishDiagnostics": .object(["relatedInformation": .bool(false)]),
            ]),
            "workspace": .object([
                "workspaceFolders": .bool(true),
                "configuration": .bool(true),
                "applyEdit": .bool(true),
                "executeCommand": .object(["dynamicRegistration": .bool(false)]),
            ]),
        ])
        let params = JSONValue.object([
            "processId": .number(Double(ProcessInfo.processInfo.processIdentifier)),
            "rootUri": .string(rootURI),
            "capabilities": caps,
            "workspaceFolders": .array(workspaceFolders),
            "clientInfo": .object(["name": .string("Quill"), "version": .string("0.1")]),
        ])
        let result = try session?.request(method: "initialize", params: params)
        capabilities = ServerCapabilities.parse(result)
        try session?.notify(method: "initialized", params: .object([:]))
    }

    private func handleNotification(_ method: String, _ params: JSONValue?) {
        if method == "textDocument/publishDiagnostics", let params = params?.object {
            let uri = params["uri"]?.string ?? ""
            let diags = params["diagnostics"]?.array?.compactMap(Diagnostic.from) ?? []
            onDiagnostics?(uri, diags)
        }
        if method == "window/logMessage", let msg = params?.object?["message"]?.string {
            onLog?(msg)
        }
    }

    private func handleServerRequest(_ method: String, _ params: JSONValue?) -> JSONValue? {
        switch method {
        case "workspace/workspaceFolders":
            return .array(workspaceFolders)
        case "workspace/configuration":
            let items = params?.object?["items"]?.array ?? []
            return .array(Array(repeating: .object([:]), count: max(1, items.count)))
        case "client/registerCapability", "client/unregisterCapability", "window/workDoneProgress/create":
            return .null
        case "workspace/applyEdit":
            guard let raw = params?.object?["edit"], let handler = onApplyEdit else {
                return .object(["applied": .bool(false)])
            }
            handler(WorkspaceEdit.parse(raw))
            return .object(["applied": .bool(true)])
        default:
            return nil
        }
    }

    private func drainStderr(_ handle: FileHandle) {
        let thread = Thread {
            while true {
                let data = try? handle.read(upToCount: 64 * 1024)
                if data == nil || data?.isEmpty == true { return }
                if let text = String(data: data ?? Data(), encoding: .utf8), !text.isEmpty {
                    self.onLog?(text)
                }
            }
        }
        thread.name = "quill.lsp.stderr"
        thread.start()
    }

    private func watchExit(_ proc: Process) {
        proc.terminationHandler = { [weak self] process in
            guard let self else { return }
            if self.isRunning {
                self.onLog?("language server exited (\(process.terminationStatus))")
                self.isRunning = false
            }
        }
    }

    private func textDocumentPosition(_ uri: String, _ pos: LSPPosition) -> JSONValue {
        .object([
            "textDocument": .object(["uri": .string(uri)]),
            "position": pos.json,
        ])
    }

    private func parseCompletion(_ value: JSONValue) -> [CompletionItem] {
        if let arr = value.array {
            return arr.compactMap(CompletionItem.from)
        }
        if let items = value.object?["items"]?.array {
            return items.compactMap(CompletionItem.from)
        }
        return []
    }

    private func parseLocations(_ value: JSONValue) -> [Location] {
        if let loc = Location.from(value) { return [loc] }
        if let arr = value.array { return arr.compactMap(Location.from) }
        return []
    }

    private func resolveExecutable(_ command: String) -> String? {
        if command.hasPrefix("/") {
            return FileManager.default.isExecutableFile(atPath: command) ? command : nil
        }
        let path = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/usr/local/bin"
        for dir in path.split(separator: ":") {
            let candidate = String(dir) + "/" + command
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }
}

final class ProcessTransport: ByteTransport, @unchecked Sendable {
    let input: FileHandle
    let output: FileHandle
    private let writeLock = NSLock()
    private var closed = false

    init(input: FileHandle, output: FileHandle) {
        self.input = input
        self.output = output
    }

    func write(_ data: Data) throws {
        writeLock.lock()
        defer { writeLock.unlock() }
        if closed { throw JSONRPCError.closed }
        try input.write(contentsOf: data)
    }

    func readSome() throws -> Data? {
        if closed { return nil }
        let data = try output.read(upToCount: 64 * 1024)
        if data == nil || data?.isEmpty == true { return nil }
        return data
    }

    func close() {
        closed = true
        try? input.close()
        try? output.close()
    }
}
