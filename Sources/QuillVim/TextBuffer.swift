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

    /// `\r\n` and lone `\r` in `text` become `\n`: a buffer never holds `\r`, so
    /// `\n` is the only line break and every line count agrees with `LineIndex`.
    public init(text: String = "", cursor: Int = 0) {
        let text = LineIndex.normalizingNewlines(text)
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
    /// Lines as LSP counts them, including the empty one after a final newline.
    public var lineCount: Int { lines.lineCount }
    /// The last line as vim counts them. See `LineIndex.lastLine`.
    public var lastLine: Int { lines.lastLine }

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

    /// Start of the grapheme after the one containing `offset`, or `count`.
    /// Loops that walk text step with this and `graphemeStart(before:)`, never
    /// with `± 1`, so they cannot stop inside an emoji or a combining sequence.
    public func nextGrapheme(after offset: Int) -> Int {
        guard offset < count else { return count }
        return graphemeSpan(containing: max(0, offset)).upperBound
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
        assert(!new.utf16.contains(13), "normalize line breaks before they reach the buffer")
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

    /// Every line's text (as `lineCount` counts lines) with the first directory-entry
    /// anchor on it, the anchor sitting anywhere from the line start through its newline.
    /// One pass over the sorted anchors merged with line starts.
    public func directoryEntryLines() -> [(text: String, anchor: Anchor?)] {
        var anchorIndex = 0
        var rows: [(text: String, anchor: Anchor?)] = []
        rows.reserveCapacity(lineCount)
        for index in 0..<lineCount {
            let line = lines.line(index)
            let end = line.contentEnd + 1
            while anchorIndex < anchors.count, anchors[anchorIndex].offset < line.start {
                anchorIndex += 1
            }
            var found: Anchor?
            var look = anchorIndex
            while look < anchors.count, anchors[look].offset < end {
                if case .directoryEntry = anchors[look].kind {
                    found = anchors[look]
                    break
                }
                look += 1
            }
            while anchorIndex < anchors.count, anchors[anchorIndex].offset < end {
                anchorIndex += 1
            }
            rows.append((substring(line.content), found))
        }
        return rows
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

    /// What deleting whole lines removes. When the last of them has no newline,
    /// the newline before the first goes too, so `dd` on a final line without
    /// one leaves no empty line behind (`"a\nb"` becomes `"a"`).
    public func linewiseDeletion(_ range: Range<Int>) -> Range<Int> {
        guard range.upperBound >= count, range.lowerBound > 0 else { return range }
        let last = lines.bufferLine(containing: max(range.lowerBound, range.upperBound - 1))
        if last.hasNewline { return range }
        return (range.lowerBound - 1)..<range.upperBound
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

    /// Every caret lands on a grapheme boundary. A normal-mode caret also sits on a
    /// character of a line up to `lastLine`: never on the newline of a non-empty
    /// line, and never after a final newline. Insert mode may stand at the end of
    /// any line, including after a final newline.
    public func clampedCursor(_ raw: Int, normalMode: Bool) -> Int {
        if count == 0 { return 0 }
        let c = min(max(0, raw), count)
        if !normalMode {
            return c == count ? c : graphemeSpan(containing: c).lowerBound
        }
        let line = lines.line(min(lines.line(containing: c), lines.lastLine))
        if line.isEmpty { return line.start }
        if c >= line.contentEnd { return graphemeStart(before: line.contentEnd) }
        return graphemeSpan(containing: c).lowerBound
    }

    /// 0-based grapheme column of `offset` on its line, the column `file:line:col` uses.
    public func graphemeColumn(of offset: Int) -> Int {
        let line = bufferLine(containing: offset)
        return graphemes(in: line.start..<min(max(offset, line.start), line.contentEnd)).count
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
