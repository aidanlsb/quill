public struct Keymap: Equatable, Sendable {
    public enum Lookup: Equatable, Sendable {
        case none
        case prefix
        case command(String)
    }

    private var exact: [String: String]

    public init() {
        exact = [:]
    }

    public mutating func bind(_ notation: String, command: String) {
        exact[notation] = command
    }

    public func lookup(_ notation: String) -> Lookup {
        if let command = exact[notation] { return .command(command) }
        if exact.keys.contains(where: { $0.hasPrefix(notation) && $0 != notation }) {
            return .prefix
        }
        return .none
    }
}
