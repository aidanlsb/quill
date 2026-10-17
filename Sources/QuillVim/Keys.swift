extension String {
    func trimASCIISpaces() -> String {
        var s = self
        while s.first == " " || s.first == "\t" { s.removeFirst() }
        while s.last == " " || s.last == "\t" { s.removeLast() }
        return s
    }
}

/// Keys the engine understands. No AppKit types — the host maps native events in.
public enum Key: Equatable, Sendable {
    case character(Character)
    case escape
    case enter
    case backspace
    case delete
    case tab
    case ctrl(Character)
    case up
    case down
    case left
    case right
}

public struct KeyEvent: Equatable, Sendable {
    public var key: Key

    public init(_ key: Key) {
        self.key = key
    }

    /// Parse a vim-style key notation used by tests and the CLI harness.
    /// Examples: `dw`, `ihello<Esc>`, `3x`, `<C-r>`, `/foo<CR>`.
    public static func parse(_ notation: String) -> [KeyEvent] {
        var events: [KeyEvent] = []
        var index = notation.startIndex
        while index < notation.endIndex {
            let ch = notation[index]
            if ch == "<" {
                if let close = notation[index...].firstIndex(of: ">"), close > index {
                    let tag = String(notation[notation.index(after: index)..<close])
                    if let key = parseTag(tag) {
                        events.append(KeyEvent(key))
                        index = notation.index(after: close)
                        continue
                    }
                }
            }
            events.append(KeyEvent(.character(ch)))
            index = notation.index(after: index)
        }
        return events
    }

    private static func parseTag(_ tag: String) -> Key? {
        switch tag.lowercased() {
        case "esc", "escape":
            return .escape
        case "cr", "enter", "return":
            return .enter
        case "bs", "backspace":
            return .backspace
        case "del", "delete":
            return .delete
        case "tab":
            return .tab
        case "space":
            return .character(" ")
        case "up":
            return .up
        case "down":
            return .down
        case "left":
            return .left
        case "right":
            return .right
        case "lt":
            return .character("<")
        case "bar":
            return .character("|")
        default:
            if tag.count == 3, tag.hasPrefix("C-") || tag.hasPrefix("c-") {
                return .ctrl(tag.lowercased().last!)
            }
            return nil
        }
    }
}
