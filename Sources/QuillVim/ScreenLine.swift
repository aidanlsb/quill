import QuillText

/// The display column `j` / `k` aim for (vim's `curswant`).
public enum Curswant: Equatable, Sendable {
    /// Take the caret's display column at the next vertical motion.
    /// Horizontal motions and edits leave this behind.
    case fresh
    /// Cells from the start of the screen line.
    case column(Int)
    /// `$`: the last character of every screen line.
    case end
}

/// One visual row: a slice of one buffer line's content.
public struct ScreenLine: Equatable, Sendable {
    public var bufferLine: Int
    /// Row number within the buffer line, from 0.
    public var row: Int
    /// UTF-16 range of the row's characters. Empty only on an empty buffer line.
    public var range: Range<Int>
    public var isLastRow: Bool

    public init(bufferLine: Int, row: Int, range: Range<Int>, isLastRow: Bool) {
        self.bufferLine = bufferLine
        self.row = row
        self.range = range
        self.isLastRow = isLastRow
    }
}

/// Reports where a buffer line breaks into screen rows. That is all a layout
/// does: no columns, no carets, no points. `ScreenModel` owns everything else.
public protocol ScreenLayout: AnyObject {
    /// UTF-16 ranges of the rows of `line`, in order, or `nil` when the layout
    /// cannot answer (no view, a view that holds different text). `ScreenModel`
    /// treats a missing or malformed answer as one row.
    func rowRanges(of line: BufferLine, in buffer: TextBuffer) -> [Range<Int>]?
}

/// No wrapping: one screen line per buffer line. Tests and the fallback.
/// Immutable, so the shared instance is safe to use from any isolation domain.
public final class LogicalLineLayout: ScreenLayout, Sendable {
    public static let shared = LogicalLineLayout()
    public init() {}

    public func rowRanges(of line: BufferLine, in buffer: TextBuffer) -> [Range<Int>]? {
        [line.content]
    }
}

/// Wraps every `width` display cells. A grapheme that does not fit starts the next row.
public final class WrapLayout: ScreenLayout {
    public var width: Int
    public var tabWidth: Int

    public init(width: Int, tabWidth: Int = DisplayWidth.defaultTabWidth) {
        self.width = max(1, width)
        self.tabWidth = tabWidth
    }

    public func rowRanges(of line: BufferLine, in buffer: TextBuffer) -> [Range<Int>]? {
        if line.isEmpty { return [line.content] }
        var rows: [Range<Int>] = []
        var rowStart = line.start
        var used = 0
        var column = 0
        for grapheme in buffer.graphemes(in: line.content) {
            let next = DisplayWidth.advance(column, over: grapheme.character, tabWidth: tabWidth)
            let cells = next - column
            if used > 0, used + cells > width {
                rows.append(rowStart..<grapheme.span.lowerBound)
                rowStart = grapheme.span.lowerBound
                used = 0
            }
            used += cells
            column = next
        }
        rows.append(rowStart..<line.contentEnd)
        return rows
    }
}

/// Buffer lines (`LineIndex`) and screen lines (`ScreenLayout`) together.
/// Every vertical and row-relative motion goes through here.
public struct ScreenModel {
    public let buffer: TextBuffer
    public let layout: any ScreenLayout
    public var tabWidth: Int
    /// Insert mode may stand after a line's last character and on the empty
    /// line that follows a final newline. Normal mode may not.
    public var insert: Bool

    public init(
        buffer: TextBuffer,
        layout: any ScreenLayout,
        tabWidth: Int = DisplayWidth.defaultTabWidth,
        insert: Bool = false
    ) {
        self.buffer = buffer
        self.layout = layout
        self.tabWidth = tabWidth
        self.insert = insert
    }

    /// The last buffer line a caret can reach.
    public var lastReachableLine: Int {
        insert ? buffer.lineCount - 1 : buffer.lastLine
    }

    /// Rows of buffer line `index`. Always at least one; together they cover
    /// the line's content exactly, and every break sits on a grapheme boundary.
    public func screenLines(of index: Int) -> [ScreenLine] {
        let line = buffer.line(index)
        let ranges = validated(layout.rowRanges(of: line, in: buffer), for: line) ?? [line.content]
        return ranges.enumerated().map { row, range in
            ScreenLine(bufferLine: line.index, row: row, range: range, isLastRow: row == ranges.count - 1)
        }
    }

    /// The row showing `offset`. A soft-wrap boundary belongs to the row it starts;
    /// the end of a line's content belongs to its last row.
    public func screenLine(containing offset: Int) -> ScreenLine {
        let clamped = min(max(0, offset), buffer.count)
        let rows = screenLines(of: buffer.lineIndex(containing: clamped))
        return rows.first { $0.range.contains(clamped) } ?? rows[rows.count - 1]
    }

    /// Cells between the start of `offset`'s screen line and `offset`.
    public func displayColumn(of offset: Int) -> Int {
        let cells = cells(of: screenLine(containing: offset))
        for cell in cells where cell.span.upperBound > offset {
            return cell.start
        }
        return cells.last?.end ?? 0
    }

    /// Caret for `want` on `row`. A column past the row clamps to its last character;
    /// in insert mode the end of a buffer line is also a place to stand.
    public func offset(on row: ScreenLine, want: Curswant) -> Int {
        let cells = cells(of: row)
        guard let last = cells.last else { return row.range.lowerBound }
        let pastEnd = insert && row.isLastRow ? row.range.upperBound : last.span.lowerBound
        switch want {
        case .end:
            return pastEnd
        case .fresh:
            return row.range.lowerBound
        case .column(let column):
            for cell in cells where column < cell.end {
                return cell.span.lowerBound
            }
            return pastEnd
        }
    }

    /// Neighbors are found by offset, not by `row.row`: a lazy layout can report
    /// a line in more or fewer rows than it did when `row` was read.
    public func next(after row: ScreenLine) -> ScreenLine? {
        if let below = screenLines(of: row.bufferLine).first(where: { $0.range.lowerBound >= row.range.upperBound && $0.range.lowerBound > row.range.lowerBound }) {
            return below
        }
        guard row.bufferLine < lastReachableLine else { return nil }
        return screenLines(of: row.bufferLine + 1).first
    }

    public func previous(before row: ScreenLine) -> ScreenLine? {
        if let above = screenLines(of: row.bufferLine).last(where: { $0.range.upperBound <= row.range.lowerBound && $0.range.lowerBound < row.range.lowerBound }) {
            return above
        }
        guard row.bufferLine > 0 else { return nil }
        return screenLines(of: row.bufferLine - 1).last
    }

    /// Up to `delta` rows away (negative is up). `moved` is how many rows it went.
    public func step(from row: ScreenLine, by delta: Int) -> (row: ScreenLine, moved: Int) {
        var current = row
        var moved = 0
        while moved < abs(delta) {
            guard let next = delta > 0 ? next(after: current) : previous(before: current) else { break }
            current = next
            moved += 1
        }
        return (current, moved)
    }

    /// Last place a normal-mode caret can sit on `row`.
    public func lastCursor(on row: ScreenLine) -> Int {
        cells(of: row).last?.span.lowerBound ?? row.range.lowerBound
    }

    public struct Cell: Equatable {
        public var span: Range<Int>
        /// First and one-past-last display column, relative to the row start.
        public var start: Int
        public var end: Int
    }

    /// Graphemes of `row` with their display columns. Tab stops count from the
    /// start of the buffer line, so a tab keeps its width when the row above wraps.
    public func cells(of row: ScreenLine) -> [Cell] {
        let line = buffer.line(row.bufferLine)
        var base = 0
        if row.range.lowerBound > line.start {
            for grapheme in buffer.graphemes(in: line.start..<row.range.lowerBound) {
                base = DisplayWidth.advance(base, over: grapheme.character, tabWidth: tabWidth)
            }
        }
        var column = base
        var out: [Cell] = []
        for grapheme in buffer.graphemes(in: row.range) {
            let next = DisplayWidth.advance(column, over: grapheme.character, tabWidth: tabWidth)
            out.append(Cell(span: grapheme.span, start: column - base, end: next - base))
            column = next
        }
        return out
    }

    private func validated(_ ranges: [Range<Int>]?, for line: BufferLine) -> [Range<Int>]? {
        guard let ranges, !line.isEmpty else { return nil }
        var rows: [Range<Int>] = []
        var at = line.start
        for range in ranges {
            let lower = max(range.lowerBound, line.start)
            let upper = min(range.upperBound, line.contentEnd)
            if upper <= at { continue }
            guard lower == at else { return nil }
            guard buffer.graphemeSpan(containing: upper - 1).upperBound == upper else { return nil }
            rows.append(at..<upper)
            at = upper
        }
        return at == line.contentEnd && !rows.isEmpty ? rows : nil
    }
}
