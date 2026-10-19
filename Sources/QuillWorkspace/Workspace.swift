import Foundation
import QuillText

public enum LineEnding: Equatable, Sendable {
    case lf
    case crlf
    case mixed
}

public enum BufferKind: Equatable, Sendable {
    case file
    case directory
    case scratch
}

public struct FileTypeSettings: Equatable, Sendable {
    public var languageId: String
    public var shiftWidth: Int
    public var wrap: Bool

    public init(languageId: String, shiftWidth: Int = 2, wrap: Bool = true) {
        self.languageId = languageId
        self.shiftWidth = shiftWidth
        self.wrap = wrap
    }
}

public struct FileTypeRegistry: Equatable, Sendable {
    public var byExtension: [String: FileTypeSettings]
    public var byFilename: [String: FileTypeSettings]

    public init(
        byExtension: [String: FileTypeSettings] = FileTypeRegistry.defaults,
        byFilename: [String: FileTypeSettings] = [:]
    ) {
        self.byExtension = byExtension
        self.byFilename = byFilename
    }

    public static let defaults: [String: FileTypeSettings] = [
        "md": FileTypeSettings(languageId: "markdown"),
        "markdown": FileTypeSettings(languageId: "markdown"),
        "txt": FileTypeSettings(languageId: "plaintext", wrap: true),
        "swift": FileTypeSettings(languageId: "swift", shiftWidth: 4, wrap: false),
        "json": FileTypeSettings(languageId: "json", shiftWidth: 2, wrap: false),
    ]

    public func settings(for url: URL) -> FileTypeSettings {
        let name = url.lastPathComponent
        if let named = byFilename[name] { return named }
        let ext = url.pathExtension.lowercased()
        return byExtension[ext] ?? FileTypeSettings(languageId: "plaintext")
    }

    public func languageId(for url: URL) -> String {
        settings(for: url).languageId
    }
}

public enum TextCodec {
    public struct Decoded: Equatable, Sendable {
        public var text: String
        public var ending: LineEnding
    }

    public enum Failure: Error, Equatable {
        case invalidUTF8
    }

    public static func decode(_ data: Data) throws -> Decoded {
        guard let text = String(data: data, encoding: .utf8) else {
            throw Failure.invalidUTF8
        }
        return Decoded(text: LineIndex.normalizingNewlines(text), ending: ending(of: text))
    }

    public static func encode(_ text: String, ending: LineEnding) -> Data {
        let stored: String
        switch ending {
        case .crlf:
            stored = text.replacingOccurrences(of: "\n", with: "\r\n")
        case .lf, .mixed:
            stored = text
        }
        return Data(stored.utf8)
    }

    public static func ending(of text: String) -> LineEnding {
        let crlf = text.contains("\r\n")
        let lf = text.replacingOccurrences(of: "\r\n", with: "").contains("\n")
        if crlf && lf { return .mixed }
        if crlf { return .crlf }
        return .lf
    }
}

public struct ExternalChange: Equatable, Sendable {
    public var modifiedAt: Date?

    public init(modifiedAt: Date?) {
        self.modifiedAt = modifiedAt
    }

    public static func conflicts(loaded: Date?, current: Date?) -> Bool {
        guard let loaded, let current else { return false }
        return current.timeIntervalSince(loaded) > 0.001
    }
}

public enum NavigationDecision: Equatable, Sendable {
    case allow
    case prompt(String)
}

public enum NavigationGuard {
    public static let unsavedMessage = "E37: No write since last change"

    public static func decide(isModified: Bool, force: Bool) -> NavigationDecision {
        if force || !isModified { return .allow }
        return .prompt(unsavedMessage)
    }
}

public struct DocumentState: Equatable, Sendable, Identifiable {
    public var id: UUID
    public var text: String
    public var version: Int
    public var url: URL?
    public var ending: LineEnding
    public var languageId: String
    public var kind: BufferKind
    public var isModified: Bool
    public var loadedAt: Date?

    public init(
        id: UUID = UUID(),
        text: String = "",
        version: Int = 0,
        url: URL? = nil,
        ending: LineEnding = .lf,
        languageId: String = "markdown",
        kind: BufferKind = .scratch,
        isModified: Bool = false,
        loadedAt: Date? = nil
    ) {
        self.id = id
        self.text = text
        self.version = version
        self.url = url
        self.ending = ending
        self.languageId = languageId
        self.kind = kind
        self.isModified = isModified
        self.loadedAt = loadedAt
    }
}

public struct EditorWindowState: Equatable, Sendable, Identifiable {
    public var id: UUID
    public var documentID: UUID
    public var cursor: Int
    public var goalColumn: Int
    public var goalX: Double
    public var visualAnchor: Int?
    public var scrollAnchor: Int
    public var jumps: [Int]

    public init(
        id: UUID = UUID(),
        documentID: UUID,
        cursor: Int = 0,
        goalColumn: Int = 0,
        goalX: Double = 0,
        visualAnchor: Int? = nil,
        scrollAnchor: Int = 0,
        jumps: [Int] = []
    ) {
        self.id = id
        self.documentID = documentID
        self.cursor = cursor
        self.goalColumn = goalColumn
        self.goalX = goalX
        self.visualAnchor = visualAnchor
        self.scrollAnchor = scrollAnchor
        self.jumps = jumps
    }
}

public struct EditorSessionState: Equatable, Sendable {
    public var searchPattern: String
    public var lastEx: String
    public var commands: [String: String]

    public init(searchPattern: String = "", lastEx: String = "", commands: [String: String] = [:]) {
        self.searchPattern = searchPattern
        self.lastEx = lastEx
        self.commands = commands
    }
}

public struct WorkspaceState: Equatable, Sendable {
    public var root: URL?
    public var documents: [DocumentState]
    public var windows: [EditorWindowState]
    public var session: EditorSessionState
    public var activeWindow: UUID?
    public var message: String

    public init(root: URL? = nil) {
        self.root = root
        self.documents = []
        self.windows = []
        self.session = EditorSessionState()
        self.activeWindow = nil
        self.message = ""
    }

    public func document(_ id: UUID) -> DocumentState? {
        documents.first { $0.id == id }
    }

    public var activeDocument: DocumentState? {
        guard let window = windows.first(where: { $0.id == activeWindow }) else { return documents.first }
        return document(window.documentID)
    }
}

public struct CommandRegistry: Sendable {
    private var handlers: [String: @Sendable (String) -> String]

    public init() {
        handlers = [:]
    }

    public mutating func register(_ name: String, _ body: @escaping @Sendable (String) -> String) {
        handlers[name] = body
    }

    public func invoke(_ name: String, args: String = "") -> String? {
        handlers[name]?(args)
    }

    public var names: [String] { handlers.keys.sorted() }
}

/// In-process plugin surface. Out-of-process plugins speak the same method names over JSON-RPC.
public enum PluginHost {
    public static let methods = [
        "quill/command",
        "quill/buffer/getText",
        "quill/buffer/applyEdit",
    ]

    public static func handle(
        method: String,
        params: String,
        registry: CommandRegistry,
        bufferText: String
    ) -> String {
        switch method {
        case "quill/command":
            let parts = params.split(separator: " ", maxSplits: 1).map(String.init)
            let name = parts.first ?? ""
            let args = parts.count > 1 ? parts[1] : ""
            return registry.invoke(name, args: args) ?? "unknown command \(name)"
        case "quill/buffer/getText":
            return bufferText
        case "quill/buffer/applyEdit":
            return params
        default:
            return "method not found"
        }
    }
}

public enum WorkspaceEditor {
    public static func open(data: Data, url: URL, into workspace: inout WorkspaceState, registry: FileTypeRegistry = FileTypeRegistry(), force: Bool = false) throws -> NavigationDecision {
        if let active = workspace.activeDocument {
            let decision = NavigationGuard.decide(isModified: active.isModified, force: force)
            if case .prompt = decision {
                workspace.message = NavigationGuard.unsavedMessage
                return decision
            }
        }
        let decoded = try TextCodec.decode(data)
        let settings = registry.settings(for: url)
        let document = DocumentState(
            text: decoded.text,
            url: url,
            ending: decoded.ending,
            languageId: settings.languageId,
            kind: .file,
            loadedAt: Date()
        )
        let window = EditorWindowState(documentID: document.id)
        workspace.documents.append(document)
        workspace.windows.append(window)
        workspace.activeWindow = window.id
        workspace.root = url.deletingLastPathComponent()
        workspace.message = ""
        return .allow
    }

    public static func newScratch(into workspace: inout WorkspaceState, force: Bool = false) -> NavigationDecision {
        if let active = workspace.activeDocument {
            let decision = NavigationGuard.decide(isModified: active.isModified, force: force)
            if case .prompt = decision {
                workspace.message = NavigationGuard.unsavedMessage
                return decision
            }
        }
        let document = DocumentState(kind: .scratch)
        let window = EditorWindowState(documentID: document.id)
        workspace.documents.append(document)
        workspace.windows.append(window)
        workspace.activeWindow = window.id
        return .allow
    }
}
