import QuillText

/// UTF-16 buffer backed by a rope. Offsets count UTF-16 code units so they
/// match NSString, TextKit, and LSP. `h` / `l` / `x` still step by grapheme.
public struct TextBuffer: Equatable {
    private var rope: Rope
    public var cursor: Int
    /// Display column that `j` / `k` aim for (vim's `curswant`).
    public var curswant: Curswant
    /// Buffer lines. The only offset-to-line map in the editor.
    public private(set) var lines: LineIndex
    public private(set) var anchors: [Anchor]

    public init(text: String = "", cursor: Int = 0) {
        self.rope = Rope(text)
        self.cursor = max(0, cursor)
        self.curswant = .fresh
        self.lines = LineIndex(text)
        self.anchors = []
        self.cursor = clampedCursor(self.cursor, normalMode: true)
    }

    public var text: String { rope.content }
    /// UTF-16 length. O(1).
    public var count: Int { rope.utf16Count }
    public var isEmpty: Bool { rope.isEmpty }
    public var lineCount: Int { lines.lineCount }

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
        lines.replace(span, with: new)
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

    public mutating func removeAnchors(where matches: (Anchor) -> Bool) {
        anchors.removeAll(where: matches)
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
        lines.line(containing: offset)
    }

    public func line(_ index: Int) -> BufferLine {
        lines.line(index)
    }

    public func bufferLine(containing offset: Int) -> BufferLine {
        lines.bufferLine(containing: offset)
    }

    /// Content of the line, excluding the trailing newline.
    public func lineContentRange(at line: Int) -> Range<Int> {
        lines.line(line).content
    }

    /// Offset of the newline ending this line, or `count` if the last line has no newline.
    public func lineEnd(at line: Int) -> Int {
        lines.line(line).contentEnd
    }

    /// Range covering the line including its trailing newline when present.
    public func lineFullRange(at line: Int) -> Range<Int> {
        lines.line(line).full
    }

    public func linesRange(from startLine: Int, through endLine: Int) -> Range<Int> {
        let a = min(startLine, endLine)
        let b = max(startLine, endLine)
        return lineFullRange(at: a).lowerBound..<lineFullRange(at: b).upperBound
    }

    /// Line and UTF-16 column, the coordinates LSP uses.
    public func position(of offset: Int) -> TextPosition {
        lines.position(of: offset)
    }

    public func offset(of position: TextPosition) -> Int {
        lines.offset(of: position)
    }

    /// Graphemes of `range` with their UTF-16 spans, in order.
    /// `range` should start on a grapheme boundary.
    public func graphemes(in range: Range<Int>) -> [(span: Range<Int>, character: Character)] {
        if range.isEmpty { return [] }
        var out: [(span: Range<Int>, character: Character)] = []
        var at = range.lowerBound
        for character in substring(range) {
            let width = character.utf16.count
            out.append((at..<(at + width), character))
            at += width
        }
        return out
    }

    /// Start of the `column`-th grapheme (0-based) on `line`, clamped to its last grapheme.
    public func offset(line index: Int, graphemeColumn column: Int) -> Int {
        let target = line(index)
        let graphemes = graphemes(in: target.content)
        guard !graphemes.isEmpty else { return target.start }
        return graphemes[min(max(0, column), graphemes.count - 1)].span.lowerBound
    }

    /// Last caret offset in `range`. A trailing newline is not a place to sit.
    public func lastCursor(in range: Range<Int>) -> Int {
        if range.isEmpty { return range.lowerBound }
        let start = max(0, range.lowerBound)
        var end = min(range.upperBound, count)
        if end > start {
            let ch = character(at: end - 1)
            if ch == "\n" || ch == "\r" {
                end -= 1
            }
        }
        if end <= start { return start }
        return graphemeStart(before: end)
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
                if lines.bufferLine(containing: c).start < c {
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
