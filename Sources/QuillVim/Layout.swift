/// Screen rows for vertical motion. The engine stores a buffer column
/// (`TextBuffer.preferredColumn`). A layout turns that into the column on
/// the screen row. `TextBuffer.endColumn` means the end of each row.
/// The engine never talks to AppKit; the macOS host supplies TextKit 2.
public protocol TextLayout: AnyObject {
    func displayColumn(of offset: Int, in buffer: TextBuffer) -> Int
    func position(
        from offset: Int,
        displayLines delta: Int,
        preferredColumn: Int,
        in buffer: TextBuffer
    ) -> Int
    func screenLineStart(at offset: Int, in buffer: TextBuffer) -> Int
    func screenLineEnd(at offset: Int, in buffer: TextBuffer) -> Int
}

/// One display line per buffer line. Used by tests and as a fallback.
/// Immutable, so the shared instance is safe to use from any isolation domain.
public final class LogicalLineLayout: TextLayout, Sendable {
    public static let shared = LogicalLineLayout()
    public init() {}

    public func displayColumn(of offset: Int, in buffer: TextBuffer) -> Int {
        buffer.column(of: offset)
    }

    public func position(
        from offset: Int,
        displayLines delta: Int,
        preferredColumn: Int,
        in buffer: TextBuffer
    ) -> Int {
        if buffer.isEmpty { return 0 }
        let line = buffer.lineIndex(containing: offset)
        let target = min(max(0, line + delta), buffer.lineCount - 1)
        if target == line && delta != 0 {
            return offset
        }
        let content = buffer.lineContentRange(at: target)
        if content.isEmpty { return content.lowerBound }
        if TextBuffer.isEndColumn(preferredColumn) {
            return content.upperBound - 1
        }
        let col = min(preferredColumn, content.count - 1)
        return content.lowerBound + max(0, col)
    }

    public func screenLineStart(at offset: Int, in buffer: TextBuffer) -> Int {
        if buffer.isEmpty { return 0 }
        let line = buffer.lineIndex(containing: offset)
        return buffer.lineContentRange(at: line).lowerBound
    }

    public func screenLineEnd(at offset: Int, in buffer: TextBuffer) -> Int {
        if buffer.isEmpty { return 0 }
        let line = buffer.lineIndex(containing: offset)
        return buffer.lastCharacterOffset(onLine: line)
    }
}

/// Wraps a buffer line every `width` characters. Lets tests cover display-line j/k.
public final class WrapLayout: TextLayout {
    public var width: Int

    public init(width: Int) {
        self.width = max(1, width)
    }

    public func displayColumn(of offset: Int, in buffer: TextBuffer) -> Int {
        screenColumn(buffer.column(of: offset))
    }

    public func position(
        from offset: Int,
        displayLines delta: Int,
        preferredColumn: Int,
        in buffer: TextBuffer
    ) -> Int {
        if buffer.isEmpty || delta == 0 { return offset }
        let screenCol = screenColumn(preferredColumn)
        var remaining = delta
        var pos = offset
        let step = remaining > 0 ? 1 : -1
        while remaining != 0 {
            let line = buffer.lineIndex(containing: pos)
            let content = buffer.lineContentRange(at: line)
            let col = content.isEmpty
                ? 0
                : min(max(0, pos - content.lowerBound), content.count - 1)
            let wrapIndex = content.isEmpty ? 0 : col / width
            let wraps = content.isEmpty ? 1 : max(1, (content.count + width - 1) / width)
            let nextWrap = wrapIndex + step
            if !content.isEmpty, nextWrap >= 0, nextWrap < wraps {
                pos = place(screenCol, in: content, wrap: nextWrap)
                remaining -= step
                continue
            }
            let nextLine = line + step
            if nextLine < 0 || nextLine >= buffer.lineCount { break }
            pos = place(screenCol, in: buffer.lineContentRange(at: nextLine), trailing: step < 0)
            remaining -= step
        }
        return pos
    }

    public func screenLineStart(at offset: Int, in buffer: TextBuffer) -> Int {
        screenRange(at: offset, in: buffer).lowerBound
    }

    public func screenLineEnd(at offset: Int, in buffer: TextBuffer) -> Int {
        buffer.lastCursor(in: screenRange(at: offset, in: buffer))
    }

    /// Buffer column 40 on a width of 40 is the left edge of the next screen row.
    /// Modulo keeps that edge. The end sentinel stays the last cell of the row.
    private func screenColumn(_ preferred: Int) -> Int {
        if TextBuffer.isEndColumn(preferred) { return max(0, width - 1) }
        if width <= 1 { return 0 }
        return preferred % width
    }

    private func screenRange(at offset: Int, in buffer: TextBuffer) -> Range<Int> {
        if buffer.isEmpty { return 0..<0 }
        let line = buffer.lineIndex(containing: offset)
        let content = buffer.lineContentRange(at: line)
        if content.isEmpty { return content }
        let col = min(max(0, offset - content.lowerBound), content.count - 1)
        let start = content.lowerBound + (col / width) * width
        let end = min(content.upperBound, start + width)
        return start..<end
    }

    private func place(
        _ screenCol: Int,
        in content: Range<Int>,
        wrap: Int = 0,
        trailing: Bool = false
    ) -> Int {
        if content.isEmpty { return content.lowerBound }
        let wraps = max(1, (content.count + width - 1) / width)
        let index = trailing ? wraps - 1 : min(max(0, wrap), wraps - 1)
        let start = index * width
        let rowCount = min(width, content.count - start)
        return content.lowerBound + start + min(screenCol, max(0, rowCount - 1))
    }
}
