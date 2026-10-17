public struct ParsedEx: Equatable, Sendable {
    public enum Address: Equatable, Sendable {
        case current
        case last
        case number(Int)
        case all
        case mark(Character)
    }

    public var rangeStart: Address?
    public var rangeEnd: Address?
    public var name: String
    public var bang: Bool
    public var args: String

    public init(rangeStart: Address? = nil, rangeEnd: Address? = nil, name: String, bang: Bool = false, args: String = "") {
        self.rangeStart = rangeStart
        self.rangeEnd = rangeEnd
        self.name = name
        self.bang = bang
        self.args = args
    }
}

public enum Ex {
    public static func parse(_ raw: String) -> ParsedEx {
        var text = raw.trimASCIISpaces()
        var start: ParsedEx.Address?
        var end: ParsedEx.Address?
        if text.hasPrefix("%") {
            start = .all
            end = .all
            text = String(text.dropFirst()).trimASCIISpaces()
        } else if text.hasPrefix("'<,'>") {
            start = .mark("<")
            end = .mark(">")
            text = String(text.dropFirst(5)).trimASCIISpaces()
        } else if let parsed = takeRange(&text) {
            start = parsed.start
            end = parsed.end
        }
        var name = ""
        var bang = false
        var index = text.startIndex
        while index < text.endIndex, text[index].isLetter {
            name.append(text[index])
            index = text.index(after: index)
        }
        if index < text.endIndex, text[index] == "!" {
            bang = true
            index = text.index(after: index)
        }
        let args = String(text[index...]).trimASCIISpaces()
        return ParsedEx(rangeStart: start, rangeEnd: end, name: name, bang: bang, args: args)
    }

    private static func takeRange(_ text: inout String) -> (start: ParsedEx.Address, end: ParsedEx.Address?)? {
        guard let first = takeAddress(&text) else { return nil }
        text = text.trimASCIISpaces()
        if text.hasPrefix(",") {
            text = String(text.dropFirst())
            let second = takeAddress(&text) ?? .current
            text = text.trimASCIISpaces()
            return (first, second)
        }
        return (first, nil)
    }

    private static func takeAddress(_ text: inout String) -> ParsedEx.Address? {
        text = text.trimASCIISpaces()
        guard let first = text.first else { return nil }
        if first == "." {
            text = String(text.dropFirst())
            return .current
        }
        if first == "$" {
            text = String(text.dropFirst())
            return .last
        }
        if first == "'" {
            let next = text.index(after: text.startIndex)
            guard next < text.endIndex else { return nil }
            let mark = text[next]
            text = String(text[text.index(after: next)...])
            return .mark(mark)
        }
        if first.isNumber {
            var number = ""
            while let ch = text.first, ch.isNumber {
                number.append(ch)
                text.removeFirst()
            }
            return .number(Int(number) ?? 1)
        }
        return nil
    }
}
