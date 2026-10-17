/// UTF-16 buffer backed by a rope. Offsets count UTF-16 code units so they
/// match NSString, TextKit, and LSP. `h` / `l` / `x` still step by grapheme.
public struct TextBuffer: Equatable {
    private var rope: Rope
    public var cursor: Int
    /// Preferred display column for j/k (and `$`, which sets a huge value).
    public var preferredColumn: Int
    public private(set) var lineStarts: [Int]
    public private(set) var anchors: [Anchor]

    public init(text: String = "", cursor: Int = 0) {
        self.rope = Rope(text)
        self.cursor = max(0, cursor)
        self.preferredColumn = 0
        self.lineStarts = [0]
        self.anchors = []
        rebuildLines()
        self.cursor = clampedCursor(self.cursor, normalMode: true)
    }

    public var text: String { rope.content }
    /// UTF-16 length. O(1).
    public var count: Int { rope.utf16Count }
    public var isEmpty: Bool { rope.isEmpty }
    public var lineCount: Int { lineStarts.count }

    public subscript(offset: Int) -> Character {
        character(at: offset)
    }

    public func character(at offset: Int) -> Character {
        precondition(offset >= 0 && offset < count)
        return rope.character(at: offset)
    }

    /// UTF-16 width of `string` in this buffer's coordinate space.
    public func measure(_ string: String) -> Int {
        string.utf16.count
    }

    /// Span of the grapheme cluster containing `offset`.
    public func graphemeSpan(containing offset: Int) -> Range<Int> {
        rope.graphemeSpan(containing: offset)
    }

    /// Start of the grapheme immediately before `offset`.
    public func graphemeStart(before offset: Int) -> Int {
        if offset <= 0 { return 0 }
        return graphemeSpan(containing: offset - 1).lowerBound
    }

    /// Advance `count` graphemes from `offset`, never past `limit`.
    public func endOfGraphemes(from offset: Int, count graphemes: Int, limit: Int) -> Int {
        var pos = offset
        var left = graphemes
        while left > 0, pos < limit, pos < count {
            let next = graphemeSpan(containing: pos).upperBound
            if next > limit || next == pos { break }
            pos = next
            left -= 1
        }
        return pos
    }

    public func substring(_ range: Range<Int>) -> String {
        if range.isEmpty { return "" }
        let lower = min(max(0, range.lowerBound), count)
        let upper = min(max(lower, range.upperBound), count)
        return rope.substring(lower..<upper)
    }

    @discardableResult
    public mutating func replace(_ range: Range<Int>, with new: String) -> [Anchor] {
        let lower = min(max(0, range.lowerBound), count)
        let upper = min(max(lower, range.upperBound), count)
        let span = lower..<upper
        rope.replace(span, with: new)
        updateLineStarts(replacing: span, with: new)
        adjustAnchors(replacing: span, withUTF16: new.utf16.count)
        return []
    }

    public mutating func insert(_ string: String, at offset: Int) {
        replace(offset..<offset, with: string)
    }

    public mutating func remove(_ range: Range<Int>) {
        replace(range, with: "")
    }

    public mutating func addAnchor(_ anchor: Anchor) {
        anchors.append(anchor)
        anchors.sort { $0.offset < $1.offset }
    }

    /// Remove anchors whose offset lies in `range` and return them unchanged.
    @discardableResult
    public mutating func removeAnchors(in range: Range<Int>) -> [Anchor] {
        var kept: [Anchor] = []
        var removed: [Anchor] = []
        for anchor in anchors {
            if range.contains(anchor.offset) {
                removed.append(anchor)
            } else {
                kept.append(anchor)
            }
        }
        anchors = kept
        return removed
    }

    public func anchors(in range: Range<Int>) -> [Anchor] {
        anchors.filter { range.contains($0.offset) }
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
            let span = graphemeSpan(containing: i)
            let ch = character(at: span.lowerBound)
            if ch != " " && ch != "\t" {
                return span.lowerBound
            }
            i = span.upperBound
        }
        return range.lowerBound
    }

    public func isBlankLine(_ line: Int) -> Bool {
        lineContentRange(at: line).isEmpty
    }

    public func lastCharacterOffset(onLine line: Int) -> Int {
        let range = lineContentRange(at: line)
        if range.isEmpty { return range.lowerBound }
        return graphemeStart(before: range.upperBound)
    }

    /// Normal-mode cursor sits on a character, never on a trailing newline of a non-empty line,
    /// and never past the last character.
    public func clampedCursor(_ raw: Int, normalMode: Bool) -> Int {
        if count == 0 { return 0 }
        var c = min(max(0, raw), count)
        if normalMode {
            if c >= count { c = graphemeStart(before: count) }
            if c < count, character(at: c) == "\n" {
                let line = lineIndex(containing: c)
                if lineStarts[line] < c {
                    c = graphemeStart(before: c)
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
        lineStarts = [0]
        let text = rope.content
        var units = 0
        for unit in text.utf16 {
            units += 1
            if unit == 10 {
                lineStarts.append(units)
            }
        }
    }

    private mutating func updateLineStarts(replacing range: Range<Int>, with new: String) {
        let startLine = lineIndex(containing: min(range.lowerBound, max(0, count)))
        // `count` is already the post-edit length. The line index of the edit
        // start is still valid because line starts at or before the edit didn't move.
        var next: [Int] = []
        next.reserveCapacity(lineStarts.count + 4)
        if lineStarts.indices.contains(startLine) {
            for index in 0...startLine {
                next.append(lineStarts[index])
            }
        } else {
            next = [0]
        }
        var relative = 0
        for unit in new.utf16 {
            if unit == 10 {
                next.append(range.lowerBound + relative + 1)
            }
            relative += 1
        }
        let delta = new.utf16.count - range.count
        for start in lineStarts where start > range.upperBound {
            next.append(start + delta)
        }
        if next.isEmpty || next[0] != 0 {
            next.insert(0, at: 0)
        }
        lineStarts = next
    }

    private mutating func adjustAnchors(replacing range: Range<Int>, withUTF16 newLen: Int) {
        let delta = newLen - range.count
        for index in anchors.indices {
            let position = anchors[index].offset
            if position < range.lowerBound {
                continue
            }
            if range.lowerBound == range.upperBound, position == range.lowerBound {
                if anchors[index].gravity == .right {
                    anchors[index].offset += newLen
                }
                continue
            }
            if position >= range.upperBound {
                anchors[index].offset += delta
                continue
            }
            if position == range.lowerBound, anchors[index].gravity == .left {
                continue
            }
            if anchors[index].gravity == .right {
                anchors[index].offset = range.lowerBound + newLen
            } else {
                anchors[index].offset = range.lowerBound
            }
        }
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
