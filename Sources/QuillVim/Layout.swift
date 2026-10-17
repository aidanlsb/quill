/// Abstracts wrapped (display) lines so j/k can move the way a writer sees the buffer.
/// The engine never talks to AppKit; the macOS host supplies a TextKit 2 implementation.
public protocol TextLayout: AnyObject {
    func displayColumn(of offset: Int, in buffer: TextBuffer) -> Int
    func position(
        from offset: Int,
        displayLines delta: Int,
        preferredColumn: Int,
        in buffer: TextBuffer
    ) -> Int
}

/// One display line per buffer line. Used by tests and as a fallback.
public final class LogicalLineLayout: TextLayout, @unchecked Sendable {
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
        let col = min(preferredColumn, content.count - 1)
        return content.lowerBound + max(0, col)
    }
}

/// Wraps a buffer line every `width` characters. Lets tests cover display-line j/k.
public final class WrapLayout: TextLayout, @unchecked Sendable {
    public var width: Int

    public init(width: Int) {
        self.width = max(1, width)
    }

    public func displayColumn(of offset: Int, in buffer: TextBuffer) -> Int {
        buffer.column(of: offset) % width
    }

    public func position(
        from offset: Int,
        displayLines delta: Int,
        preferredColumn: Int,
        in buffer: TextBuffer
    ) -> Int {
        if buffer.isEmpty || delta == 0 { return offset }
        var remaining = delta
        var pos = offset
        let step = remaining > 0 ? 1 : -1
        while remaining != 0 {
            let line = buffer.lineIndex(containing: pos)
            let content = buffer.lineContentRange(at: line)
            let col = pos - content.lowerBound
            let wrapIndex = content.isEmpty ? 0 : col / width
            let wraps = content.isEmpty ? 1 : (content.count + width - 1) / width
            let nextWrap = wrapIndex + step
            if nextWrap >= 0 && nextWrap < max(wraps, 1) {
                let newCol = min(nextWrap * width + min(preferredColumn, width - 1), max(0, content.count - 1))
                pos = content.lowerBound + max(0, newCol)
                remaining -= step
                continue
            }
            let nextLine = line + step
            if nextLine < 0 || nextLine >= buffer.lineCount {
                break
            }
            let nextContent = buffer.lineContentRange(at: nextLine)
            if step > 0 {
                let newCol = min(preferredColumn, width - 1)
                pos = nextContent.isEmpty ? nextContent.lowerBound : nextContent.lowerBound + min(newCol, max(0, nextContent.count - 1))
            } else {
                let wrapsOnPrev = nextContent.isEmpty ? 1 : max(1, (nextContent.count + width - 1) / width)
                let startCol = (wrapsOnPrev - 1) * width
                let newCol = startCol + min(preferredColumn, width - 1)
                pos = nextContent.isEmpty
                    ? nextContent.lowerBound
                    : nextContent.lowerBound + min(newCol, max(0, nextContent.count - 1))
            }
            remaining -= step
        }
        return pos
    }
}
