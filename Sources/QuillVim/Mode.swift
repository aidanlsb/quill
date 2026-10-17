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
    /// Extensible leader mapping that the host looks up by name.
    case command(String)
}

public struct EngineResult: Equatable, Sendable {
    public var didChangeText: Bool
    public var beep: Bool
    public var actions: [HostAction]

    public static let noop = EngineResult(didChangeText: false, beep: false, actions: [])
}

public struct TextEdit: Equatable, Sendable {
    public var range: Range<Int>
    public var replacement: String
}
