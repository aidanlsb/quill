public struct Keymap: Equatable, Sendable {
    public enum Lookup: Equatable, Sendable {
        case none
        case prefix
        case command(String)
    }

    private var exact: [String: String]
    private var prefixes: Set<String>

    public init() {
        exact = [:]
        prefixes = []
    }

    /// Binds `notation` to `command`. A later bind of the same notation replaces the command.
    /// Proper prefixes are rebuilt from the whole table so lookup stays a dictionary check.
    public mutating func bind(_ notation: String, command: String) {
        exact[notation] = command
        prefixes = Self.properPrefixes(of: exact.keys)
    }

    public func lookup(_ notation: String) -> Lookup {
        if let command = exact[notation] { return .command(command) }
        if prefixes.contains(notation) { return .prefix }
        return .none
    }

    /// Proper prefixes of each binding. `<CR>` and other `<tag>` keys are one
    /// atom, so a directory's Enter binding does not swallow a typed `<`.
    private static func properPrefixes(of keys: Dictionary<String, String>.Keys) -> Set<String> {
        var set: Set<String> = []
        for key in keys {
            var partial = ""
            for atom in atoms(of: key) {
                if !partial.isEmpty { set.insert(partial) }
                partial.append(atom)
            }
        }
        return set
    }

    private static func atoms(of notation: String) -> [String] {
        var atoms: [String] = []
        var index = notation.startIndex
        while index < notation.endIndex {
            if notation[index] == "<",
               let close = notation[index...].firstIndex(of: ">"),
               notation.distance(from: index, to: close) > 1 {
                atoms.append(String(notation[index...close]))
                index = notation.index(after: close)
                continue
            }
            atoms.append(String(notation[index]))
            index = notation.index(after: index)
        }
        return atoms
    }
}
