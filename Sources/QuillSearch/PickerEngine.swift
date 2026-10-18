import Observation

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
/// Observable so the prompt can read `query` directly. A tick on the result
/// list does not refresh the line that shows what was typed.
@Observable
public final class PickerEngine {
    public var mode: PickerMode = .insert
    /// Typed prompt text. The caret is drawn by the panel; it is not a character in this string.
    public var query: String = ""
    public var queryCursor: Int = 0
    public private(set) var selectedIndex: Int = 0
    public private(set) var items: [PickerItem] = []
    public var source: [PickerItem] = [] {
        didSet {
            prepare()
            refilter()
        }
    }
    /// When set, the query is handed to a live search (grep) instead of fuzzy-filtering `source`.
    public var liveSearch: ((String) -> [PickerItem])?
    /// Preferred over `liveSearch`: the host debounces and pushes results with `replaceItems`.
    public var onQueryChange: ((String) -> Void)?
    private var prepared: [(index: Int, bytes: [UInt8])] = []
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
        prepare()
        refilter()
    }

    public var selected: PickerItem? {
        guard items.indices.contains(selectedIndex) else { return nil }
        return items[selectedIndex]
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

    /// Selected-item preview loaded off the main thread.
    public func updatePreview(payload: String, text: String) {
        if let index = items.firstIndex(where: { $0.payload == payload }) {
            items[index].preview = text
        }
    }

    /// Async results land here. Filtering stays on the caller so a keystroke never blocks.
    public func replaceItems(_ newItems: [PickerItem]) {
        items = newItems
        if items.isEmpty {
            selectedIndex = 0
        } else {
            selectedIndex = min(selectedIndex, items.count - 1)
        }
    }

    private func prepare() {
        prepared = source.enumerated().map { index, item in
            (index, Array(item.title.lowercased().utf8))
        }
    }

    private func refilter() {
        if let onQueryChange {
            onQueryChange(query)
            return
        }
        if let liveSearch {
            items = liveSearch(query)
        } else if query.isEmpty {
            items = source
        } else {
            let queryBytes = Array(query.lowercased().utf8)
            let ranked = prepared.compactMap { item -> (Int, Int)? in
                guard let score = Fuzzy.scoreUTF8(query: queryBytes, candidate: item.bytes) else { return nil }
                return (item.index, score)
            }
            .sorted { lhs, rhs in
                if lhs.1 != rhs.1 { return lhs.1 > rhs.1 }
                return source[lhs.0].title < source[rhs.0].title
            }
            items = ranked.map { source[$0.0] }
        }
        if items.isEmpty {
            selectedIndex = 0
        } else {
            selectedIndex = min(selectedIndex, items.count - 1)
        }
    }
}

/// A picker source that can be cancelled and debounced by the host.
public protocol PickerSource: Sendable {
    func items(matching query: String) async -> [PickerItem]
}
