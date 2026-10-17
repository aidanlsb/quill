public enum RangeStyle: Equatable, Sendable {
    case characterwise
    case linewise
}

public struct Register: Equatable, Sendable {
    public var text: String
    public var style: RangeStyle

    public static let empty = Register(text: "", style: .characterwise)

    public init(text: String, style: RangeStyle) {
        self.text = text
        self.style = style
    }
}

public enum RegisterName: Equatable, Sendable {
    case unnamed
    case clipboard
}

public protocol Clipboard: AnyObject {
    var text: String { get set }
}

public final class MemoryClipboard: Clipboard, @unchecked Sendable {
    public var text: String

    public init(_ text: String = "") {
        self.text = text
    }
}
