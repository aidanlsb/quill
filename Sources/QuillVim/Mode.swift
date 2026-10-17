public enum Mode: Equatable, Sendable {
    case normal
    case insert
    case visual
    case visualLine
    case operatorPending
    case replaceChar
    case findChar
    case commandLine
    case search

    public var displayName: String {
        switch self {
        case .normal, .operatorPending, .replaceChar, .findChar:
            return "NORMAL"
        case .insert:
            return "INSERT"
        case .visual:
            return "VISUAL"
        case .visualLine:
            return "V-LINE"
        case .commandLine:
            return "COMMAND"
        case .search:
            return "SEARCH"
        }
    }

    public var isVisual: Bool {
        self == .visual || self == .visualLine
    }
}

public enum HostAction: Equatable, Sendable {
    case write
    case quit
    case writeQuit
    /// Jump to the definition of the symbol or `[[wikilink]]` under the cursor.
    /// The host resolves this via LSP if a server is configured, otherwise
    /// by matching wikilink text to filenames in the open folder.
    case goToDefinition
    /// Open the parent directory as an editable listing buffer (`-` in oil.nvim).
    case openParentDirectory
    /// Open the entry on the current line (file or subdirectory).
    case openUnderCursor
    case findFiles
    case liveGrep
    /// `textDocument/references` for the symbol under the cursor (`gr`).
    case findReferences
    /// `textDocument/codeAction` for the cursor or selection (`<leader>ca`).
    case codeAction
    /// Run a configured shell command in the workspace root.
    case shell(String)
    /// Extensible leader mapping that the host looks up by name.
    case command(String)
}

public struct EngineResult: Equatable, Sendable {
    public var didChangeText: Bool
    public var beep: Bool
    public var actions: [HostAction]
    /// Edits produced by this keystroke, each in the coordinates left by the previous one.
    public var edits: [TextEdit] = []
    public var cursorBefore: Int = 0
    public var cursorAfter: Int = 0

    public static let noop = EngineResult(didChangeText: false, beep: false, actions: [])
}

/// One keystroke (or one committed insert session's worth of undo). `handle` returns this.
public typealias Transaction = EngineResult

public struct TextEdit: Equatable, Sendable {
    public var range: Range<Int>
    public var replacement: String

    public init(range: Range<Int>, replacement: String) {
        self.range = range
        self.replacement = replacement
    }
}
