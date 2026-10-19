/// One catalog of editor commands. The palette, menus, and leader or ex
/// bindings all read this list; each command's handler lives here too.
public struct CommandBinding: Equatable, Sendable, Hashable {
    public enum Kind: Equatable, Sendable, Hashable {
        /// Menu chord. `key` is the character ignoring modifiers.
        case chord(key: Character, command: Bool, shift: Bool, option: Bool, control: Bool)
        /// Sequence typed after the leader, such as `sf`.
        case leader(String)
        /// Ex command without the leading colon, such as `w`.
        case ex(String)
        /// A vim sequence shown as typed, such as `gd` or `-`.
        case keys(String)
    }

    public var kind: Kind

    public init(_ kind: Kind) {
        self.kind = kind
    }

    /// Right-aligned palette label. Modifier order matches the macOS menus.
    public var label: String {
        switch kind {
        case .chord(let key, let command, let shift, let option, let control):
            var text = ""
            if control { text.append("\u{2303}") }
            if option { text.append("\u{2325}") }
            if shift { text.append("\u{21E7}") }
            if command { text.append("\u{2318}") }
            text.append(String(key).uppercased())
            return text
        case .leader(let sequence):
            return "<leader>\(sequence)"
        case .ex(let name):
            return ":\(name)"
        case .keys(let text):
            return text
        }
    }

    /// The chord a menu should show, else the leader, else an ex or key sequence.
    public static func shortcutLabel(for bindings: [CommandBinding]) -> String {
        if let chord = bindings.first(where: { if case .chord = $0.kind { return true }; return false }) {
            return chord.label
        }
        if let leader = bindings.first(where: { if case .leader = $0.kind { return true }; return false }) {
            return leader.label
        }
        return bindings.first?.label ?? ""
    }
}

public struct CommandEntry: Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var category: String
    public var bindings: [CommandBinding]
    public var showsInMenu: Bool
    /// Menu section. Defaults to `category` when the command should sit with its kind.
    public var menuCategory: String

    public init(
        id: String,
        name: String,
        category: String,
        bindings: [CommandBinding] = [],
        showsInMenu: Bool = false,
        menuCategory: String? = nil
    ) {
        self.id = id
        self.name = name
        self.category = category
        self.bindings = bindings
        self.showsInMenu = showsInMenu
        self.menuCategory = menuCategory ?? category
    }
}

/// Recently used matches come first. A typed query drops non-matches, then
/// breaks remaining ties by fuzzy score and registration order.
public enum CommandRanking {
    public static func ranked(entries: [CommandEntry], query: String, recent: [String]) -> [CommandEntry] {
        let recentIndex = Dictionary(uniqueKeysWithValues: recent.enumerated().map { ($1, $0) })
        var matched: [(index: Int, score: Int)] = []
        matched.reserveCapacity(entries.count)
        for (index, entry) in entries.enumerated() {
            guard let score = score(query: query, entry: entry) else { continue }
            matched.append((index, score))
        }
        matched.sort { lhs, rhs in
            let leftRecent = recentIndex[entries[lhs.index].id]
            let rightRecent = recentIndex[entries[rhs.index].id]
            switch (leftRecent, rightRecent) {
            case let (left?, right?) where left != right:
                return left < right
            case (.some, .none):
                return true
            case (.none, .some):
                return false
            default:
                break
            }
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            return lhs.index < rhs.index
        }
        return matched.map { entries[$0.index] }
    }

    static func score(query: String, entry: CommandEntry) -> Int? {
        if query.isEmpty { return 0 }
        var fields = [entry.name] + entry.bindings.map(\.label)
        if query.count >= 3 {
            fields.append(entry.category)
        }
        var best: Int?
        for field in fields {
            guard let value = Fuzzy.score(query: query, candidate: field) else { continue }
            if let best, value <= best { continue }
            best = value
        }
        return best
    }
}

/// Handlers and enabled checks run on the main actor with the app model.
@MainActor
public final class CommandRegistry {
    public private(set) var entries: [CommandEntry] = []
    private var enabled: [String: () -> Bool] = [:]
    private var handlers: [String: () -> Void] = [:]
    private var recent: [String] = []

    public init() {}

    public func register(
        id: String,
        name: String,
        category: String,
        bindings: [CommandBinding] = [],
        showsInMenu: Bool = false,
        menuCategory: String? = nil,
        enabled: @escaping () -> Bool = { true },
        perform: @escaping () -> Void
    ) {
        let entry = CommandEntry(
            id: id,
            name: name,
            category: category,
            bindings: bindings,
            showsInMenu: showsInMenu,
            menuCategory: menuCategory
        )
        if let index = entries.firstIndex(where: { $0.id == id }) {
            entries[index] = entry
        } else {
            entries.append(entry)
        }
        self.enabled[id] = enabled
        handlers[id] = perform
    }

    public func ranked(matching query: String) -> [CommandEntry] {
        CommandRanking.ranked(entries: entries, query: query, recent: recent)
    }

    public func menuEntries(category: String) -> [CommandEntry] {
        entries.filter { $0.showsInMenu && $0.menuCategory == category }
    }

    public func isEnabled(id: String) -> Bool {
        enabled[id]?() ?? false
    }

    /// Runs the handler when the command exists and its predicate allows it.
    /// A refused command is not recorded as recent.
    @discardableResult
    public func run(id: String) -> Bool {
        guard let handler = handlers[id] else { return false }
        guard enabled[id]?() ?? false else { return false }
        recordUse(id: id)
        handler()
        return true
    }

    public func recordUse(id: String) {
        guard entries.contains(where: { $0.id == id }) else { return }
        recent.removeAll { $0 == id }
        recent.insert(id, at: 0)
        if recent.count > 24 {
            recent.removeLast(recent.count - 24)
        }
    }
}
