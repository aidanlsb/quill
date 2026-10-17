public enum RangeStyle: Equatable, Sendable {
    case characterwise
    case linewise
}

public struct Register: Equatable, Sendable {
    public var text: String
    public var style: RangeStyle
    /// Anchors relative to `text`, carried by `yy` (copy) and `dd` (move).
    public var anchors: [Anchor]

    public static let empty = Register(text: "", style: .characterwise)

    public init(text: String, style: RangeStyle, anchors: [Anchor] = []) {
        self.text = text
        self.style = style
        self.anchors = anchors
    }
}

public enum RegisterName: Equatable, Sendable {
    case unnamed
    case clipboard
    case named(Character)
    case numbered(Int)
    case smallDelete
    case blackHole
    case lastInsert
    case lastSearch
    case lastCommand
}

public protocol Clipboard: AnyObject {
    var text: String { get set }
}

public final class MemoryClipboard: Clipboard {
    public var text: String

    public init(_ text: String = "") {
        self.text = text
    }
}

/// Session-owned registers: `a`–`z` (uppercase appends), `0`–`9`, `-`, `_`, and the read-only `.` `:` `/`.
public struct RegisterStore: Equatable, Sendable {
    public var unnamed = Register.empty
    public var named: [Character: Register] = [:]
    public var numbered: [Register] = Array(repeating: .empty, count: 10)
    public var smallDelete = Register.empty
    public var lastInsert = Register.empty
    public var lastSearch = Register.empty
    public var lastCommand = Register.empty

    public init() {}

    public mutating func write(_ register: Register, to name: RegisterName) {
        switch name {
        case .unnamed:
            unnamed = register
        case .clipboard, .blackHole:
            break
        case .named(let ch):
            let lower = Character(ch.lowercased())
            if ch.isUppercase, var existing = named[lower] {
                existing.text += register.text
                existing.anchors += register.anchors.map { anchor in
                    var shifted = anchor
                    shifted.offset += existing.text.utf16.count - register.text.utf16.count
                    return shifted
                }
                named[lower] = existing
            } else {
                named[lower] = register
            }
            unnamed = register
        case .numbered(let n) where (0...9).contains(n):
            numbered[n] = register
            unnamed = register
        case .numbered:
            break
        case .smallDelete:
            smallDelete = register
        case .lastInsert:
            lastInsert = register
        case .lastSearch:
            lastSearch = register
        case .lastCommand:
            lastCommand = register
        }
    }

    public func read(_ name: RegisterName) -> Register {
        switch name {
        case .unnamed, .clipboard:
            return unnamed
        case .named(let ch):
            return named[Character(ch.lowercased())] ?? .empty
        case .numbered(let n) where (0...9).contains(n):
            return numbered[n]
        case .numbered:
            return .empty
        case .smallDelete:
            return smallDelete
        case .blackHole:
            return .empty
        case .lastInsert:
            return lastInsert
        case .lastSearch:
            return lastSearch
        case .lastCommand:
            return lastCommand
        }
    }

    /// Vim's numbered shift: the text just deleted becomes `"1`, and the rest move down.
    public mutating func shiftNumbered(_ register: Register) {
        if numbered.count < 10 {
            numbered = Array(repeating: .empty, count: 10)
        }
        for index in stride(from: 9, to: 1, by: -1) {
            numbered[index] = numbered[index - 1]
        }
        numbered[1] = register
        numbered[0] = register
        unnamed = register
    }
}
