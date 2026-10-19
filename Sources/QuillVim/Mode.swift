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

/// An ex command the engine does not implement. `lines` is the resolved
/// address range (0-based, inclusive). Nil means the user typed no range.
public struct ExCall: Equatable, Sendable {
    public var name: String
    public var args: String
    public var lines: ClosedRange<Int>?
    public var bang: Bool

    public init(name: String, args: String = "", lines: ClosedRange<Int>? = nil, bang: Bool = false) {
        self.name = name
        self.args = args
        self.lines = lines
        self.bang = bang
    }
}

public enum HostAction: Equatable, Sendable {
    /// Registry id, from a keymap hit.
    case command(String)
    /// Any ex command the engine does not own (`:s` and `:set` stay in the engine).
    case ex(ExCall)
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

public struct TextEdit: Equatable, Sendable {
    public var range: Range<Int>
    public var replacement: String

    public init(range: Range<Int>, replacement: String) {
        self.range = range
        self.replacement = replacement
    }
}
