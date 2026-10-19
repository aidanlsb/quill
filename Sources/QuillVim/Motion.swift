public enum FindKind: Equatable, Sendable {
    case findForward
    case tillForward
    case findBackward
    case tillBackward

    public var isForward: Bool {
        self == .findForward || self == .tillForward
    }

    public var isTill: Bool {
        self == .tillForward || self == .tillBackward
    }

    public var reversed: FindKind {
        switch self {
        case .findForward: return .findBackward
        case .tillForward: return .tillBackward
        case .findBackward: return .findForward
        case .tillBackward: return .tillForward
        }
    }
}

public enum MotionKind: Equatable, Sendable {
    case left
    case right
    /// `j`, `gj`: the next screen line at `curswant`. Under an operator, the next
    /// buffer line, linewise.
    case down
    /// `k`, `gk`.
    case up
    case word
    case wordEnd
    case wordBack
    case WORD
    case WORDEnd
    case WORDBack
    case lineStart
    case firstNonBlank
    case lineEnd
    /// `0`: the start of the screen line. Under an operator, the buffer line.
    case screenLineStart
    /// `$`: the last character of the screen line. Under an operator, the buffer line.
    case screenLineEnd
    case fileStart
    case gotoLine
    case find(FindKind)
    case paragraph(forward: Bool)
    case sentence(forward: Bool)
    case search(forward: Bool)
}

public struct ResolvedMotion: Equatable, Sendable {
    public var position: Int
    public var inclusive: Bool
    public var linewise: Bool
    public var failed: Bool

    public static func move(_ position: Int, inclusive: Bool = false, linewise: Bool = false) -> ResolvedMotion {
        ResolvedMotion(position: position, inclusive: inclusive, linewise: linewise, failed: false)
    }

    public static func fail(_ position: Int) -> ResolvedMotion {
        ResolvedMotion(position: position, inclusive: false, linewise: false, failed: true)
    }
}

enum MotionResolver {
    static func resolve(
        _ kind: MotionKind,
        count: Int,
        buffer: TextBuffer,
        layout: any ScreenLayout,
        find: (FindKind, Character)? = nil,
        searchPattern: String? = nil,
        searchForward: Bool = true,
        operatorPending: Bool = false,
        insert: Bool = false
    ) -> ResolvedMotion {
        let n = max(1, count)
        let screen = ScreenModel(buffer: buffer, layout: layout, insert: insert)
        switch kind {
        case .left:
            return horizontal(buffer, delta: -n, operatorPending: operatorPending)
        case .right:
            return horizontal(buffer, delta: n, operatorPending: operatorPending)
        case .down:
            if operatorPending { return bufferVertical(buffer, delta: n) }
            return screenVertical(screen, delta: n)
        case .up:
            if operatorPending { return bufferVertical(buffer, delta: -n) }
            return screenVertical(screen, delta: -n)
        case .word:
            return wordMotion(buffer, count: n, kind: .start, big: false, backward: false)
        case .wordEnd:
            return wordMotion(buffer, count: n, kind: .end, big: false, backward: false)
        case .wordBack:
            return wordMotion(buffer, count: n, kind: .start, big: false, backward: true)
        case .WORD:
            return wordMotion(buffer, count: n, kind: .start, big: true, backward: false)
        case .WORDEnd:
            return wordMotion(buffer, count: n, kind: .end, big: true, backward: false)
        case .WORDBack:
            return wordMotion(buffer, count: n, kind: .start, big: true, backward: true)
        case .lineStart:
            return .move(buffer.bufferLine(containing: buffer.cursor).start)
        case .firstNonBlank:
            let line = buffer.lineIndex(containing: buffer.cursor)
            return .move(buffer.firstNonBlank(onLine: line))
        case .lineEnd:
            var pos = buffer.cursor
            for step in 0..<n {
                let line = buffer.lineIndex(containing: pos)
                pos = buffer.lastCharacterOffset(onLine: line)
                if line + 1 < buffer.lineCount, step < n - 1 {
                    pos = buffer.line(line + 1).start
                }
            }
            return .move(pos, inclusive: true)
        case .screenLineStart:
            if operatorPending {
                return .move(buffer.bufferLine(containing: buffer.cursor).start)
            }
            return .move(screen.screenLine(containing: buffer.cursor).range.lowerBound)
        case .screenLineEnd:
            if operatorPending {
                return resolve(.lineEnd, count: n, buffer: buffer, layout: layout)
            }
            let row = screen.step(from: screen.screenLine(containing: buffer.cursor), by: n - 1).row
            return .move(screen.lastCursor(on: row), inclusive: true)
        case .fileStart:
            let line = min(max(0, n - 1), buffer.lineCount - 1)
            return .move(buffer.firstNonBlank(onLine: line), linewise: true)
        case .gotoLine:
            let line: Int
            if count <= 0 {
                line = max(0, buffer.lineCount - 1)
            } else {
                line = min(max(0, n - 1), buffer.lineCount - 1)
            }
            return .move(buffer.firstNonBlank(onLine: line), linewise: true)
        case .find(let findKind):
            guard let find else { return .fail(buffer.cursor) }
            return findChar(buffer, kind: findKind, target: find.1, count: n)
        case .paragraph(let forward):
            return paragraph(buffer, count: n, forward: forward)
        case .sentence(let forward):
            return sentence(buffer, count: n, forward: forward)
        case .search(let forward):
            guard let pattern = searchPattern, !pattern.isEmpty else {
                return .fail(buffer.cursor)
            }
            return search(buffer, pattern: pattern, count: n, forward: forward == searchForward)
        }
    }

    /// `h` / `l`: graphemes within the buffer line. Never crosses a newline, and
    /// never looks at layout, so styling and wrapping cannot make it skip.
    /// Under an operator `l` may reach the end of the content, so `dl` takes the last character.
    private static func horizontal(_ buffer: TextBuffer, delta: Int, operatorPending: Bool) -> ResolvedMotion {
        if buffer.isEmpty { return .fail(0) }
        let content = buffer.bufferLine(containing: buffer.cursor).content
        if content.isEmpty { return .fail(buffer.cursor) }
        var dest = buffer.cursor
        if delta > 0 {
            for _ in 0..<delta {
                let next = buffer.graphemeSpan(containing: dest).upperBound
                if operatorPending, next <= content.upperBound {
                    dest = next
                    if next == content.upperBound { break }
                    continue
                }
                if next >= content.upperBound {
                    let last = content.upperBound == content.lowerBound
                        ? content.lowerBound
                        : buffer.graphemeStart(before: content.upperBound)
                    if last == dest { return .fail(buffer.cursor) }
                    dest = last
                    break
                }
                dest = next
            }
        } else if delta < 0 {
            for _ in 0..<(-delta) {
                if dest <= content.lowerBound { break }
                dest = buffer.graphemeStart(before: dest)
            }
        }
        if dest == buffer.cursor { return .fail(buffer.cursor) }
        return .move(dest)
    }

    /// `j` / `k`: `delta` screen lines, straight down or up, at `curswant`.
    /// A count past the document stops on the last row it reaches.
    private static func screenVertical(_ screen: ScreenModel, delta: Int) -> ResolvedMotion {
        let buffer = screen.buffer
        let (row, moved) = screen.step(from: screen.screenLine(containing: buffer.cursor), by: delta)
        if moved == 0 { return .fail(buffer.cursor) }
        var want = buffer.curswant
        if want == .fresh {
            want = .column(screen.displayColumn(of: buffer.cursor))
        }
        return .move(screen.offset(on: row, want: want))
    }

    /// `dj` / `yk` / `>j`: whole buffer lines. Wrapping never changes what an operator covers.
    private static func bufferVertical(_ buffer: TextBuffer, delta: Int) -> ResolvedMotion {
        let line = buffer.lineIndex(containing: buffer.cursor)
        let last = buffer.lineCount - 1
        if delta > 0, line >= last { return .fail(buffer.cursor) }
        if delta < 0, line <= 0 { return .fail(buffer.cursor) }
        let target = min(max(0, line + delta), last)
        return .move(buffer.line(target).start, linewise: true)
    }

    private enum WordSeek {
        case start
        case end
    }

    private static func wordMotion(
        _ buffer: TextBuffer,
        count: Int,
        kind: WordSeek,
        big: Bool,
        backward: Bool
    ) -> ResolvedMotion {
        if buffer.isEmpty { return .fail(0) }
        var pos = buffer.cursor
        for _ in 0..<count {
            let next = big
                ? stepWORD(buffer, from: pos, toEnd: kind == .end, backward: backward)
                : stepWord(buffer, from: pos, toEnd: kind == .end, backward: backward)
            if next == pos { break }
            pos = next
        }
        if pos == buffer.cursor && kind != .end {
            return .fail(pos)
        }
        if kind == .start, !backward, pos < buffer.count,
           buffer.graphemeSpan(containing: pos).upperBound == buffer.count {
            // `w` ran out of words and stopped on the last character. Unless a word
            // starts there, the operator takes that character too (`dw` on the last word).
            let here = buffer.charClass(at: pos)
            let before = pos > 0 ? buffer.charClass(at: buffer.graphemeStart(before: pos)) : .whitespace
            let startsWord = here != .whitespace && here != .newline && !sameWordClass(before, here, big: big)
            if !startsWord {
                return .move(pos, inclusive: true)
            }
        }
        return .move(pos, inclusive: kind == .end)
    }

    private static func sameWordClass(_ a: CharClass, _ b: CharClass, big: Bool) -> Bool {
        if big { return a.isWORD && b.isWORD }
        if a == .keyword { return b == .keyword }
        if a == .other { return b == .other }
        return false
    }

    private static func stepWord(_ buffer: TextBuffer, from: Int, toEnd: Bool, backward: Bool) -> Int {
        stepGeneric(buffer, from: from, toEnd: toEnd, backward: backward, big: false)
    }

    private static func stepWORD(_ buffer: TextBuffer, from: Int, toEnd: Bool, backward: Bool) -> Int {
        stepGeneric(buffer, from: from, toEnd: toEnd, backward: backward, big: true)
    }

    private static func stepGeneric(
        _ buffer: TextBuffer,
        from: Int,
        toEnd: Bool,
        backward: Bool,
        big: Bool
    ) -> Int {
        let last = max(0, buffer.count - 1)
        var i = min(max(0, from), last)

        func cls(_ off: Int) -> CharClass { buffer.charClass(at: off) }
        func isBlank(_ off: Int) -> Bool {
            let c = cls(off)
            return c == .whitespace || c == .newline
        }

        if backward {
            if i == 0 { return 0 }
            i -= 1
            while i > 0 && isBlank(i) { i -= 1 }
            if toEnd {
                return i
            }
            let current = cls(i)
            while i > 0 && sameWordClass(cls(i - 1), current, big: big) {
                i -= 1
            }
            return i
        }

        if toEnd {
            // If already at end of a word, move off it first.
            if !isBlank(i) {
                let current = cls(i)
                let atEnd = i == last || !sameWordClass(cls(i + 1), current, big: big)
                if atEnd {
                    if i < last { i += 1 }
                    while i < last && isBlank(i) { i += 1 }
                }
            } else {
                while i < last && isBlank(i) { i += 1 }
            }
            if isBlank(i) { return i }
            let current = cls(i)
            while i < last && sameWordClass(cls(i + 1), current, big: big) {
                i += 1
            }
            return i
        }

        // w / W: next word start
        if !isBlank(i) {
            let current = cls(i)
            while i < last && sameWordClass(cls(i + 1), current, big: big) {
                i += 1
            }
            if i < last { i += 1 }
        }
        while i < last && isBlank(i) { i += 1 }
        return i
    }

    private static func findChar(
        _ buffer: TextBuffer,
        kind: FindKind,
        target: Character,
        count: Int
    ) -> ResolvedMotion {
        let line = buffer.lineIndex(containing: buffer.cursor)
        let content = buffer.lineContentRange(at: line)
        if content.isEmpty { return .fail(buffer.cursor) }
        var pos = buffer.cursor
        for _ in 0..<count {
            let found = scanFind(buffer, kind: kind, target: target, from: pos, content: content)
            guard let found else { return .fail(buffer.cursor) }
            pos = found
        }
        let inclusive = kind.isForward
        return .move(pos, inclusive: inclusive)
    }

    private static func scanFind(
        _ buffer: TextBuffer,
        kind: FindKind,
        target: Character,
        from: Int,
        content: Range<Int>
    ) -> Int? {
        if kind.isForward {
            var i = from + 1
            while i < content.upperBound {
                if buffer.character(at: i) == target {
                    if kind.isTill {
                        return i > from + 1 || i - 1 > from ? i - 1 : nil
                    }
                    return i
                }
                i += 1
            }
        } else {
            var i = from - 1
            while i >= content.lowerBound {
                if buffer.character(at: i) == target {
                    if kind.isTill {
                        return i + 1 < from ? i + 1 : nil
                    }
                    return i
                }
                i -= 1
            }
        }
        return nil
    }

    private static func paragraph(_ buffer: TextBuffer, count: Int, forward: Bool) -> ResolvedMotion {
        if buffer.isEmpty { return .fail(0) }
        var line = buffer.lineIndex(containing: buffer.cursor)
        for _ in 0..<count {
            if forward {
                if buffer.isBlankLine(line) && line + 1 < buffer.lineCount {
                    line += 1
                    while line < buffer.lineCount && buffer.isBlankLine(line) {
                        line += 1
                    }
                }
                while line < buffer.lineCount && !buffer.isBlankLine(line) {
                    line += 1
                }
                if line >= buffer.lineCount {
                    line = buffer.lineCount - 1
                }
            } else {
                if line == 0 {
                    return .move(0)
                }
                if buffer.isBlankLine(line) && line > 0 {
                    line -= 1
                    while line > 0 && buffer.isBlankLine(line) {
                        line -= 1
                    }
                }
                while line > 0 && !buffer.isBlankLine(line) {
                    line -= 1
                }
            }
        }
        return .move(buffer.line(line).start)
    }

    private static func sentence(_ buffer: TextBuffer, count: Int, forward: Bool) -> ResolvedMotion {
        if buffer.isEmpty { return .fail(0) }
        var pos = buffer.cursor
        for _ in 0..<count {
            let next = forward ? nextSentence(buffer, from: pos) : prevSentence(buffer, from: pos)
            if next == pos { break }
            pos = next
        }
        return .move(pos)
    }

    private static func isSentencePunct(_ ch: Character) -> Bool {
        ch == "." || ch == "!" || ch == "?"
    }

    private static func isCloser(_ ch: Character) -> Bool {
        ch == ")" || ch == "]" || ch == "\"" || ch == "'"
    }

    static func isSentenceEnd(_ buffer: TextBuffer, at offset: Int) -> Bool {
        guard offset < buffer.count, isSentencePunct(buffer.character(at: offset)) else {
            return false
        }
        var i = offset + 1
        while i < buffer.count, isCloser(buffer.character(at: i)) {
            i += 1
        }
        if i >= buffer.count { return true }
        let ch = buffer.character(at: i)
        return ch == " " || ch == "\t" || ch == "\n"
    }

    private static func nextSentence(_ buffer: TextBuffer, from: Int) -> Int {
        var i = from
        while i < buffer.count {
            if isSentenceEnd(buffer, at: i) {
                i += 1
                while i < buffer.count {
                    let ch = buffer.character(at: i)
                    if ch == " " || ch == "\t" || ch == "\n" || isCloser(ch) {
                        i += 1
                        continue
                    }
                    break
                }
                return min(i, max(0, buffer.count - 1))
            }
            i += 1
        }
        return max(0, buffer.count - 1)
    }

    private static func sentenceStart(afterEndAt end: Int, in buffer: TextBuffer) -> Int {
        var start = end + 1
        while start < buffer.count {
            let ch = buffer.character(at: start)
            if ch == " " || ch == "\t" || ch == "\n" || isCloser(ch) {
                start += 1
                continue
            }
            break
        }
        return min(start, max(0, buffer.count - 1))
    }

    private static func prevSentence(_ buffer: TextBuffer, from: Int) -> Int {
        if from == 0 { return 0 }
        var searchFrom = from - 1
        let currentStart: Int? = {
            var i = from - 1
            while i > 0, !isSentenceEnd(buffer, at: i) { i -= 1 }
            guard isSentenceEnd(buffer, at: i) else { return 0 }
            return sentenceStart(afterEndAt: i, in: buffer)
        }()
        if let currentStart, from <= currentStart {
            searchFrom = max(0, currentStart - 1)
        } else if let currentStart, from > currentStart {
            return currentStart
        }
        var i = searchFrom
        while i > 0, !isSentenceEnd(buffer, at: i) {
            i -= 1
        }
        if isSentenceEnd(buffer, at: i) {
            let start = sentenceStart(afterEndAt: i, in: buffer)
            if start < from { return start }
        }
        return 0
    }

    private static func search(
        _ buffer: TextBuffer,
        pattern: String,
        count: Int,
        forward: Bool
    ) -> ResolvedMotion {
        guard !pattern.isEmpty, !buffer.isEmpty else { return .fail(buffer.cursor) }
        var pos = buffer.cursor
        for _ in 0..<count {
            guard let found = findPattern(buffer, pattern: pattern, from: pos, forward: forward, wrap: true) else {
                return .fail(buffer.cursor)
            }
            if found == pos { break }
            pos = found
        }
        return .move(pos)
    }

    static func findPattern(
        _ buffer: TextBuffer,
        pattern: String,
        from: Int,
        forward: Bool,
        wrap: Bool
    ) -> Int? {
        return Searcher.find(text: buffer.text, pattern: pattern, from: from, forward: forward, wrap: wrap)
    }
}

enum OperatorRange {
    static func compute(
        from cursor: Int,
        motion: ResolvedMotion,
        buffer: TextBuffer
    ) -> (Range<Int>, RangeStyle)? {
        if motion.failed { return nil }
        if motion.linewise {
            let l1 = buffer.lineIndex(containing: cursor)
            let l2 = buffer.lineIndex(containing: motion.position)
            return (buffer.linesRange(from: l1, through: l2), .linewise)
        }

        let a = min(cursor, motion.position)
        var b = max(cursor, motion.position)
        var inclusive = motion.inclusive

        // Exclusive motion ending on column 0 of a later line: stop at the
        // previous line's newline without including it (vim exception 1 / `dw`).
        if !inclusive,
           b > a,
           buffer.bufferLine(containing: b).start == b,
           buffer.lineIndex(containing: a) != buffer.lineIndex(containing: b),
           b > 0 {
            b -= 1
            inclusive = false
        }

        if inclusive, b < buffer.count {
            b = buffer.graphemeSpan(containing: b).upperBound
        }
        if a >= b {
            if a < buffer.count {
                return (a..<buffer.graphemeSpan(containing: a).upperBound, .characterwise)
            }
            return nil
        }
        return (a..<b, .characterwise)
    }
}
