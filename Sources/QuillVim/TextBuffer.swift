/// Character-offset buffer with a line-start index.
/// Offsets count Swift `Character` (grapheme) units so h/l match what a writer sees.
public struct TextBuffer: Equatable, Sendable {
    public private(set) var text: String
    public var cursor: Int
    /// Preferred display column for j/k (and `$` which sets a huge value).
    public var preferredColumn: Int
    public private(set) var lineStarts: [Int]

    public init(text: String = "", cursor: Int = 0) {
        self.text = text
        self.cursor = max(0, cursor)
        self.preferredColumn = 0
        self.lineStarts = [0]
        rebuildLines()
        self.cursor = clampedCursor(self.cursor, normalMode: true)
    }

    public var count: Int { text.count }
    public var isEmpty: Bool { text.isEmpty }
    public var lineCount: Int { lineStarts.count }

    public subscript(offset: Int) -> Character {
        character(at: offset)
    }

    public func character(at offset: Int) -> Character {
        precondition(offset >= 0 && offset < count)
        let i = text.index(text.startIndex, offsetBy: offset)
        return text[i]
    }

    public func substring(_ range: Range<Int>) -> String {
        if range.isEmpty { return "" }
        let lower = min(max(0, range.lowerBound), count)
        let upper = min(max(lower, range.upperBound), count)
        let start = text.index(text.startIndex, offsetBy: lower)
        let end = text.index(text.startIndex, offsetBy: upper)
        return String(text[start..<end])
    }

    public mutating func replace(_ range: Range<Int>, with new: String) {
        let lower = min(max(0, range.lowerBound), count)
        let upper = min(max(lower, range.upperBound), count)
        let start = text.index(text.startIndex, offsetBy: lower)
        let end = text.index(text.startIndex, offsetBy: upper)
        text.replaceSubrange(start..<end, with: new)
        rebuildLines()
    }

    public mutating func insert(_ string: String, at offset: Int) {
        replace(offset..<offset, with: string)
    }

    public mutating func remove(_ range: Range<Int>) {
        replace(range, with: "")
    }

    // MARK: Lines

    public func lineIndex(containing offset: Int) -> Int {
        let clamped = min(max(0, offset), count)
        var low = 0
        var high = lineStarts.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if lineStarts[mid] <= clamped {
                low = mid
            } else {
                high = mid - 1
            }
        }
        return low
    }

    /// Content of the line, excluding the trailing newline.
    public func lineContentRange(at line: Int) -> Range<Int> {
        let start = lineStarts[line]
        return start..<lineEnd(at: line)
    }

    /// Offset of the newline ending this line, or `count` if the last line has no newline.
    public func lineEnd(at line: Int) -> Int {
        if line + 1 < lineStarts.count {
            return lineStarts[line + 1] - 1
        }
        return count
    }

    /// Range covering the line including its trailing newline when present.
    public func lineFullRange(at line: Int) -> Range<Int> {
        let start = lineStarts[line]
        if line + 1 < lineStarts.count {
            return start..<lineStarts[line + 1]
        }
        return start..<count
    }

    public func linesRange(from startLine: Int, through endLine: Int) -> Range<Int> {
        let a = min(startLine, endLine)
        let b = max(startLine, endLine)
        return lineFullRange(at: a).lowerBound..<lineFullRange(at: b).upperBound
    }

    public func column(of offset: Int) -> Int {
        let line = lineIndex(containing: offset)
        return max(0, min(offset, count) - lineStarts[line])
    }

    public func offset(line: Int, column: Int) -> Int {
        let content = lineContentRange(at: line)
        if content.isEmpty { return content.lowerBound }
        return min(content.lowerBound + column, content.upperBound - 1)
    }

    public func firstNonBlank(onLine line: Int) -> Int {
        let range = lineContentRange(at: line)
        var i = range.lowerBound
        while i < range.upperBound {
            let ch = character(at: i)
            if ch != " " && ch != "\t" {
                return i
            }
            i += 1
        }
        return range.lowerBound
    }

    public func isBlankLine(_ line: Int) -> Bool {
        lineContentRange(at: line).isEmpty
    }

    public func lastCharacterOffset(onLine line: Int) -> Int {
        let range = lineContentRange(at: line)
        if range.isEmpty { return range.lowerBound }
        return range.upperBound - 1
    }

    /// Normal-mode cursor sits on a character, never on a trailing newline of a non-empty line,
    /// and never past the last character.
    public func clampedCursor(_ raw: Int, normalMode: Bool) -> Int {
        if count == 0 { return 0 }
        var c = min(max(0, raw), count)
        if normalMode {
            if c >= count { c = count - 1 }
            if c < count, character(at: c) == "\n" {
                let line = lineIndex(containing: c)
                if lineStarts[line] < c {
                    c -= 1
                }
            }
        } else {
            c = min(c, count)
        }
        return c
    }

    public mutating func clampCursor(normalMode: Bool) {
        cursor = clampedCursor(cursor, normalMode: normalMode)
    }

    public func isKeyword(_ ch: Character) -> Bool {
        ch.isLetter || ch.isNumber || ch == "_"
    }

    public func charClass(at offset: Int) -> CharClass {
        guard offset >= 0, offset < count else { return .whitespace }
        return Self.classify(character(at: offset), isKeyword: isKeyword)
    }

    public static func classify(_ ch: Character, isKeyword: (Character) -> Bool) -> CharClass {
        if ch == "\n" { return .newline }
        if ch.isWhitespace { return .whitespace }
        if isKeyword(ch) { return .keyword }
        return .other
    }

    private mutating func rebuildLines() {
        var starts: [Int] = [0]
        var offset = 0
        for ch in text {
            if ch == "\n" {
                starts.append(offset + 1)
            }
            offset += 1
        }
        lineStarts = starts
    }
}

public enum CharClass: Equatable, Sendable {
    case whitespace
    case newline
    case keyword
    case other

    public var isWord: Bool {
        self == .keyword || self == .other
    }

    public var isWORD: Bool {
        self != .whitespace && self != .newline
    }
}
