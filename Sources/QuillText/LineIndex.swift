/// A position as LSP and `file:line:col` see it: a 0-based buffer line and a
/// UTF-16 column from that line's start.
public struct TextPosition: Equatable, Hashable, Sendable {
    public var line: Int
    public var utf16Column: Int

    public init(line: Int, utf16Column: Int) {
        self.line = line
        self.utf16Column = utf16Column
    }
}

/// One logical line of the text. Ranges are UTF-16 offsets into the document.
/// `content` excludes the trailing newline; `full` includes it when present.
public struct BufferLine: Equatable, Hashable, Sendable {
    public var index: Int
    public var start: Int
    /// Offset of the newline that ends the line, or the document length on the last line.
    public var contentEnd: Int
    /// Start of the next line, or the document length on the last line.
    public var end: Int

    public init(index: Int, start: Int, contentEnd: Int, end: Int) {
        self.index = index
        self.start = start
        self.contentEnd = contentEnd
        self.end = end
    }

    public var content: Range<Int> { start..<contentEnd }
    public var full: Range<Int> { start..<end }
    public var isEmpty: Bool { start == contentEnd }
    public var hasNewline: Bool { end > contentEnd }
}

/// The canonical map from UTF-16 offsets to buffer lines. Only `\n` ends a line.
/// Every other component (motions, LSP, `file:line:col`, the directory view)
/// asks this type instead of scanning for newlines itself.
public struct LineIndex: Equatable, Sendable {
    /// UTF-16 offset of each line's first unit. Always starts with 0.
    public private(set) var starts: [Int]
    public private(set) var utf16Count: Int

    public init() {
        starts = [0]
        utf16Count = 0
    }

    public init(_ text: String) {
        self.init(utf16: text.utf16)
    }

    public init<Units: Sequence>(utf16 units: Units) where Units.Element == UInt16 {
        var starts = [0]
        var count = 0
        for unit in units {
            count += 1
            if unit == Self.newline {
                starts.append(count)
            }
        }
        self.starts = starts
        self.utf16Count = count
    }

    public static let newline: UInt16 = 10

    public var lineCount: Int { starts.count }

    /// Line holding `offset`. Offsets are clamped to `0...utf16Count`; the
    /// document end belongs to the last line.
    public func line(containing offset: Int) -> Int {
        let clamped = min(max(0, offset), utf16Count)
        var low = 0
        var high = starts.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if starts[mid] <= clamped {
                low = mid
            } else {
                high = mid - 1
            }
        }
        return low
    }

    public func line(_ index: Int) -> BufferLine {
        let i = min(max(0, index), starts.count - 1)
        let start = starts[i]
        if i + 1 < starts.count {
            let next = starts[i + 1]
            return BufferLine(index: i, start: start, contentEnd: next - 1, end: next)
        }
        return BufferLine(index: i, start: start, contentEnd: utf16Count, end: utf16Count)
    }

    public func bufferLine(containing offset: Int) -> BufferLine {
        line(line(containing: offset))
    }

    public func position(of offset: Int) -> TextPosition {
        let clamped = min(max(0, offset), utf16Count)
        let index = line(containing: clamped)
        return TextPosition(line: index, utf16Column: clamped - starts[index])
    }

    /// Offset for `position`. A column past the line's content clamps to the end of
    /// that content (LSP rule); a line past the last clamps to the document end.
    public func offset(of position: TextPosition) -> Int {
        if position.line < 0 { return 0 }
        if position.line >= starts.count { return utf16Count }
        let target = line(position.line)
        return min(target.start + max(0, position.utf16Column), target.contentEnd)
    }

    /// Keep the index in step with `text.replace(range, with: new)`.
    public mutating func replace(_ range: Range<Int>, with new: String) {
        replace(range, withUTF16: new.utf16)
    }

    public mutating func replace<Units: Sequence>(_ range: Range<Int>, withUTF16 new: Units) where Units.Element == UInt16 {
        let lower = min(max(0, range.lowerBound), utf16Count)
        let upper = min(max(lower, range.upperBound), utf16Count)
        let first = line(containing: lower)
        var next = Array(starts[0...first])
        var inserted = 0
        for unit in new {
            inserted += 1
            if unit == Self.newline {
                next.append(lower + inserted)
            }
        }
        let delta = inserted - (upper - lower)
        // A start in (lower, upper] follows a newline that was removed.
        var survivor = first + 1
        while survivor < starts.count, starts[survivor] <= upper {
            survivor += 1
        }
        while survivor < starts.count {
            next.append(starts[survivor] + delta)
            survivor += 1
        }
        starts = next
        utf16Count += delta
    }
}
