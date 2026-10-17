/// Telescope-style picker state machine, independent of AppKit.
/// Opens in insert mode in the prompt. Esc enters picker normal mode.
public enum PickerMode: Equatable, Sendable {
    case insert
    case normal
}

public enum PickerCommand: Equatable, Sendable {
    case none
    case close
    case confirm
}

public struct PickerItem: Equatable, Sendable {
    public var title: String
    public var subtitle: String
    public var payload: String
    public var preview: String

    public init(title: String, subtitle: String = "", payload: String, preview: String = "") {
        self.title = title
        self.subtitle = subtitle
        self.payload = payload
        self.preview = preview
    }
}

public enum PickerKey: Equatable, Sendable {
    case character(Character)
    case escape
    case enter
    case backspace
    case up
    case down
    case left
    case right
    case ctrl(Character)
}

/// Prompt + result list with insert/normal modes, matching Telescope's feel.
public final class PickerEngine: @unchecked Sendable {
    public var mode: PickerMode = .insert
    public var query: String = ""
    public var queryCursor: Int = 0
    public private(set) var selectedIndex: Int = 0
    public private(set) var items: [PickerItem] = []
    public var source: [PickerItem] = [] {
        didSet { refilter() }
    }
    /// When set, the query is handed to a live search (grep) instead of fuzzy-filtering `source`.
    public var liveSearch: ((String) -> [PickerItem])?
    public var status: String {
        let n = items.count
        let sel = n == 0 ? 0 : selectedIndex + 1
        let modeTag = mode == .insert ? "INSERT" : "NORMAL"
        return "\(modeTag)  \(sel)/\(n)"
    }

    private var pendingG = false

    public init(source: [PickerItem] = [], liveSearch: ((String) -> [PickerItem])? = nil) {
        self.source = source
        self.liveSearch = liveSearch
        refilter()
    }

    public var selected: PickerItem? {
        guard items.indices.contains(selectedIndex) else { return nil }
        return items[selectedIndex]
    }

    /// Prompt text with a caret in insert mode, matching Telescope's prompt.
    public var promptDisplay: String {
        let c = min(max(0, queryCursor), query.count)
        let idx = query.index(query.startIndex, offsetBy: c)
        if mode == .insert {
            return String(query[..<idx]) + "▏" + String(query[idx...])
        }
        return query
    }

    @discardableResult
    public func handle(_ key: PickerKey) -> PickerCommand {
        switch mode {
        case .insert:
            return handleInsert(key)
        case .normal:
            return handleNormal(key)
        }
    }

    private func handleInsert(_ key: PickerKey) -> PickerCommand {
        pendingG = false
        switch key {
        case .escape:
            mode = .normal
            return .none
        case .enter:
            return items.isEmpty ? .none : .confirm
        case .backspace:
            if queryCursor > 0 {
                let i = query.index(query.startIndex, offsetBy: queryCursor - 1)
                query.remove(at: i)
                queryCursor -= 1
                refilter()
            }
            return .none
        case .down, .ctrl("n"):
            moveSelection(1)
            return .none
        case .up, .ctrl("p"):
            moveSelection(-1)
            return .none
        case .left:
            queryCursor = max(0, queryCursor - 1)
            return .none
        case .right:
            queryCursor = min(query.count, queryCursor + 1)
            return .none
        case .ctrl:
            return .none
        case .character(let ch):
            let i = query.index(query.startIndex, offsetBy: queryCursor)
            query.insert(ch, at: i)
            queryCursor += 1
            refilter()
            return .none
        }
    }

    private func handleNormal(_ key: PickerKey) -> PickerCommand {
        if pendingG {
            pendingG = false
            if case .character("g") = key {
                selectedIndex = 0
                return .none
            }
        }
        switch key {
        case .escape:
            return .close
        case .enter:
            return items.isEmpty ? .none : .confirm
        case .down, .ctrl("n"):
            moveSelection(1)
            return .none
        case .up, .ctrl("p"):
            moveSelection(-1)
            return .none
        case .character("q"):
            return .close
        case .character("j"):
            moveSelection(1)
            return .none
        case .character("k"):
            moveSelection(-1)
            return .none
        case .character("g"):
            pendingG = true
            return .none
        case .character("G"):
            if !items.isEmpty { selectedIndex = items.count - 1 }
            return .none
        case .character("i"):
            mode = .insert
            return .none
        case .character("a"):
            mode = .insert
            queryCursor = query.count
            return .none
        default:
            return .none
        }
    }

    private func moveSelection(_ delta: Int) {
        guard !items.isEmpty else {
            selectedIndex = 0
            return
        }
        selectedIndex = min(max(0, selectedIndex + delta), items.count - 1)
    }

    private func refilter() {
        if let liveSearch {
            items = liveSearch(query)
        } else if query.isEmpty {
            items = source
        } else {
            let ranked = Fuzzy.rank(query: query, candidates: source.map(\.title))
            let byTitle = Dictionary(grouping: source, by: \.title)
            items = ranked.compactMap { byTitle[$0.value]?.first }
        }
        if items.isEmpty {
            selectedIndex = 0
        } else {
            selectedIndex = min(selectedIndex, items.count - 1)
        }
    }
}
