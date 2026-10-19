import QuillText

/// Semantic markdown spans. The app maps these onto a theme; this module stays
/// free of AppKit and Foundation so styling can be tested on Linux.
public enum MarkdownToken: Equatable, Sendable {
    case heading(Int)
    case emphasis
    case strong
    case codeSpan
    case fence
    case frontmatter
    case wikilink
    case listMarker
    case taskBox
    case syntaxMarker
}

public struct TokenSpan: Equatable, Sendable {
    public var range: Range<Int>
    public var token: MarkdownToken

    public init(range: Range<Int>, token: MarkdownToken) {
        self.range = range
        self.token = token
    }
}

/// Block state *entering* a line. Re-tokenizing stops once this matches the cache.
public struct BlockState: Equatable, Sendable {
    public var inFence: Bool
    public var inFrontmatter: Bool

    public init(inFence: Bool = false, inFrontmatter: Bool = false) {
        self.inFence = inFence
        self.inFrontmatter = inFrontmatter
    }
}

public enum TokenStyle: Equatable, Sendable {
    case body
    case syntax
    case code
    case link
    case dim
    case heading(Int)
    case strong
    case emphasis
}

public enum MarkdownThemeMap {
    public static func style(for token: MarkdownToken) -> TokenStyle {
        switch token {
        case .heading(let level): return .heading(level)
        case .emphasis: return .emphasis
        case .strong: return .strong
        case .codeSpan, .fence: return .code
        case .frontmatter, .syntaxMarker, .listMarker, .taskBox: return .syntax
        case .wikilink: return .link
        }
    }
}

public struct MarkdownTokenizer: Equatable, Sendable {
    public private(set) var states: [BlockState]
    /// Absolute ranges. Lines at or after `shiftLine` are stored without `shift` added.
    private var storedSpans: [TokenSpan]
    private var source: String
    /// False after `apply`, which does not rewrite `source`. The next full
    /// `replace` rebuilds from the caller's string instead of diffing a stale one.
    private var sourceValid: Bool
    private var ready: Bool
    private var lines: [LineSplit.Line]
    private var lineStarts: [Int]
    /// How many spans each line owns. Parallel to the scanned prefix of `lineStarts`.
    private var spanCounts: [Int]
    /// Stored ranges on this line and after are behind by `shift` UTF-16 units.
    private var shiftLine: Int
    private var shift: Int

    /// `scanThroughLine` tokenizes only that line and the ones above it.
    /// The tail stays as line text until a later edit or `spans(overlapping:)` reaches it.
    public init(text: String, scanThroughLine: Int? = nil) {
        states = []
        storedSpans = []
        source = ""
        sourceValid = false
        ready = false
        lines = []
        lineStarts = []
        spanCounts = []
        shiftLine = 0
        shift = 0
        if let scanThroughLine {
            installLines(text)
            if !lines.isEmpty {
                ensureScanned(throughLine: scanThroughLine)
            }
        } else {
            installFull(text)
        }
    }

    /// Spans with absolute UTF-16 ranges. Reading this does not scan an unscanned tail.
    public var spans: [TokenSpan] {
        guard shift != 0, shiftLine < spanCounts.count else { return storedSpans }
        let start = spanIndex(ofLine: shiftLine)
        guard start < storedSpans.count else { return storedSpans }
        var copy = storedSpans
        for index in start..<copy.count {
            let range = copy[index].range
            copy[index].range = (range.lowerBound + shift)..<(range.upperBound + shift)
        }
        return copy
    }

    public var scannedLineCount: Int { spanCounts.count }

    public var utf16Count: Int { lines.last?.end ?? 0 }

    /// True once a document is loaded, including an empty one. Edits can then
    /// patch cached lines instead of scanning the whole string.
    public var acceptsEdits: Bool { ready }

    /// Rebuild spans that an edit can affect, and report that line range.
    /// `dirtyUTF16` is the first unit that changed. Lines before it are kept.
    /// Scanning stops once a later line's entering block state matches the
    /// cache; spans after that point are shifted by the UTF-16 delta instead
    /// of being tokenized again.
    @discardableResult
    public mutating func replace(text: String, dirtyUTF16: Int) -> Range<Int> {
        if !sourceValid || !ready || spanCounts.count != lineStarts.count || states.count != lineStarts.count + 1 {
            installFull(text)
            return 0..<lines.count
        }
        if text == source { return 0..<0 }
        let bounds = LineSplit.bounds(in: text)
        let oldLen = source.utf16.count
        let newLen = text.utf16.count
        let dirty = min(max(0, dirtyUTF16), oldLen, newLen)
        let suffix = LineSplit.commonSuffixLength(source, text, maxLength: min(oldLen - dirty, newLen - dirty))
        let newEditEnd = newLen - suffix
        let delta = newLen - oldLen
        let first = LineSplit.lineIndex(containing: min(dirty, max(0, oldLen - 1)), starts: lineStarts)
        guard first < lineStarts.count, first < states.count else {
            installFull(text)
            return 0..<lines.count
        }
        for index in 0..<first {
            if index >= bounds.count || bounds[index].start != lineStarts[index] {
                installFull(text)
                return 0..<lines.count
            }
        }
        if bounds.isEmpty {
            installFull(text)
            return 0..<0
        }
        let oldLineCount = lineStarts.count
        let lineDelta = bounds.count - oldLineCount
        let lastNew = LineSplit.lineIndex(containing: max(0, newEditEnd - 1), bounds: bounds)

        var scan = first
        var entering = states[first]
        var produced: [TokenSpan] = []
        var producedCounts: [Int] = []
        var producedStates: [BlockState] = []
        var cursor = LineSplit.Cursor(text)
        var convergedOld: Int?
        while scan < bounds.count {
            producedStates.append(entering)
            let line = LineSplit.materialize(text, bounds[scan], cursor: &cursor)
            let (spansOut, exit) = Scanner.scan(line: line, entering: entering)
            produced.append(contentsOf: spansOut)
            producedCounts.append(spansOut.count)
            entering = exit
            let nextNew = scan + 1
            let nextOld = nextNew - lineDelta
            if nextNew > lastNew,
               nextOld >= 0,
               nextOld < states.count,
               states[nextOld] == exit {
                convergedOld = nextOld
                scan = nextNew
                break
            }
            scan = nextNew
        }

        materializeAll()
        let prefixSpans = spanCounts.prefix(first).reduce(0, +)
        var mergedSpans = Array(storedSpans.prefix(prefixSpans))
        mergedSpans.append(contentsOf: produced)
        var mergedCounts = Array(spanCounts.prefix(first)) + producedCounts
        var mergedStates = Array(states.prefix(first)) + producedStates
        if let nextOld = convergedOld {
            let suffixSpanStart = spanCounts.prefix(nextOld).reduce(0, +)
            if delta == 0 {
                if suffixSpanStart < storedSpans.count {
                    mergedSpans.append(contentsOf: storedSpans[suffixSpanStart...])
                }
            } else if suffixSpanStart < storedSpans.count {
                for span in storedSpans[suffixSpanStart...] {
                    mergedSpans.append(TokenSpan(
                        range: (span.range.lowerBound + delta)..<(span.range.upperBound + delta),
                        token: span.token
                    ))
                }
            }
            if nextOld < spanCounts.count {
                mergedCounts.append(contentsOf: spanCounts[nextOld...])
            }
            mergedStates.append(contentsOf: states[nextOld...])
        } else {
            mergedStates.append(entering)
        }

        source = text
        sourceValid = true
        storedSpans = mergedSpans
        shift = 0
        shiftLine = 0
        spanCounts = mergedCounts
        states = mergedStates
        lines = LineSplit.lines(in: text)
        lineStarts = lines.map(\.start)
        return first..<max(first, scan)
    }

    /// Patch cached lines from one UTF-16 edit. Unchanged lines are not read
    /// back out of the document string, so a keystroke does not walk the file.
    @discardableResult
    public mutating func apply(start utf16Start: Int, removedUTF16: Int, replacement: String) -> Range<Int> {
        guard ready else {
            installFull(replacement)
            return 0..<lines.count
        }
        let oldLen = utf16Count
        let start = min(max(0, utf16Start), oldLen)
        let removed = min(max(0, removedUTF16), oldLen - start)
        if lines.isEmpty {
            installFull(replacement)
            return 0..<lines.count
        }
        let oldEnd = start + removed
        let delta = replacement.utf16.count - removed
        let first = LineSplit.lineIndex(containing: start == oldLen ? oldLen - 1 : start, starts: lineStarts)
        var last = LineSplit.lineIndex(containing: max(0, removed == 0 ? start : oldEnd - 1), starts: lineStarts)
        // Deleting the newline joins the next line. That line has to be part of the splice.
        if removed > 0, last + 1 < lines.count, oldEnd == lines[last].end, oldEnd < oldLen {
            last += 1
        }
        if spanCounts.count <= last {
            ensureScanned(throughLine: last)
        }
        let blockStart = lines[first].start
        var block = ""
        for index in first...last {
            block += LineSplit.storageForm(lines[index])
        }
        let localStart = start - blockStart
        let localEnd = oldEnd - blockStart
        let merged = LineSplit.utf16Slice(block, from: 0, to: localStart)
            + replacement
            + LineSplit.utf16Slice(block, from: localEnd, to: block.utf16.count)
        let newLines = LineSplit.lines(in: merged).map { line in
            LineSplit.Line(
                text: line.text,
                start: line.start + blockStart,
                end: line.end + blockStart,
                isBlank: line.isBlank
            )
        }
        let oldSpan = last - first + 1
        if newLines.count == oldSpan {
            // Mutate the suffix in place. Rebuilding the line array copied every
            // later line's string on a keystroke at the top of the file.
            for offset in 0..<newLines.count {
                lines[first + offset] = newLines[offset]
                if first + offset < lineStarts.count {
                    lineStarts[first + offset] = newLines[offset].start
                }
            }
            if delta != 0 {
                var index = last + 1
                while index < lines.count {
                    lines[index].start += delta
                    lines[index].end += delta
                    if index < lineStarts.count {
                        lineStarts[index] += delta
                    }
                    index += 1
                }
            }
        } else {
            var rebuilt: [LineSplit.Line] = []
            rebuilt.reserveCapacity(lines.count - oldSpan + newLines.count)
            rebuilt.append(contentsOf: lines[..<first])
            rebuilt.append(contentsOf: newLines)
            if last + 1 < lines.count {
                for index in (last + 1)..<lines.count {
                    var line = lines[index]
                    line.start += delta
                    line.end += delta
                    rebuilt.append(line)
                }
            }
            lines = rebuilt
            lineStarts = lines.map(\.start)
        }
        sourceValid = false

        let replacedEnd = first + newLines.count
        var scan = first
        var entering = first < states.count ? states[first] : BlockState()
        var produced: [TokenSpan] = []
        var producedCounts: [Int] = []
        var producedStates: [BlockState] = []
        var convergedOld: Int?
        while scan < lines.count {
            producedStates.append(entering)
            let (spansOut, exit) = Scanner.scan(line: lines[scan], entering: entering)
            produced.append(contentsOf: spansOut)
            producedCounts.append(spansOut.count)
            entering = exit
            let nextNew = scan + 1
            if nextNew >= replacedEnd {
                let nextOld = (last + 1) + (nextNew - replacedEnd)
                if nextOld < states.count, states[nextOld] == exit {
                    convergedOld = nextOld
                    scan = nextNew
                    break
                }
            }
            scan = nextNew
        }

        let boundary = convergedOld ?? spanCounts.count
        materialize(beforeLine: boundary)
        if shift != 0, shiftLine > boundary {
            materializeAll()
        }
        let carried = shift
        let prefixSpans = spanIndex(ofLine: first)
        var mergedSpans = Array(storedSpans.prefix(prefixSpans))
        mergedSpans.append(contentsOf: produced)
        var mergedCounts = Array(spanCounts.prefix(first)) + producedCounts
        var mergedStates = Array(states.prefix(first)) + producedStates
        if let nextOld = convergedOld {
            let suffixSpanStart = spanIndex(ofLine: nextOld)
            if suffixSpanStart < storedSpans.count {
                mergedSpans.append(contentsOf: storedSpans[suffixSpanStart...])
            }
            if nextOld < spanCounts.count {
                mergedCounts.append(contentsOf: spanCounts[nextOld...])
            }
            if nextOld < states.count {
                mergedStates.append(contentsOf: states[nextOld...])
            }
        } else {
            mergedStates.append(entering)
        }
        storedSpans = mergedSpans
        spanCounts = mergedCounts
        states = mergedStates
        let suffixStart = first + producedCounts.count
        if carried + delta != 0, suffixStart < spanCounts.count {
            shift = carried + delta
            shiftLine = suffixStart
        } else {
            shift = 0
            shiftLine = 0
        }
        return first..<max(first, scan)
    }

    /// Paragraph containing `utf16`, from the line cache. Does not walk the document string.
    public func paragraphRange(containing utf16: Int) -> Range<Int> {
        guard !lines.isEmpty else { return 0..<0 }
        let total = utf16Count
        let probe = min(max(0, utf16), max(0, total - 1))
        var index = LineSplit.lineIndex(containing: probe, starts: lineStarts)
        while index > 0, !lines[index].isBlank, !lines[index - 1].isBlank { index -= 1 }
        var end = index
        while end < lines.count, !lines[end].isBlank { end += 1 }
        let upper = end < lines.count ? lines[end].start : (lines.last?.end ?? 0)
        return lines[index].start..<upper
    }

    /// UTF-16 span of the line containing `utf16`, including its newline.
    public func lineContentSpan(containing utf16: Int) -> Range<Int> {
        guard !lines.isEmpty, utf16Count > 0 else { return 0..<0 }
        let probe = min(max(0, utf16), utf16Count - 1)
        let index = LineSplit.lineIndex(containing: probe, starts: lineStarts)
        return lineSpan(index..<(index + 1))
    }

    /// True when `after` is `before` with ranges shifted by an edit that did not
    /// change tokens. AppKit already shifted those attribute runs.
    public static func spansFollowEdit(
        _ before: [TokenSpan],
        _ after: [TokenSpan],
        editAt: Int,
        delta: Int
    ) -> Bool {
        guard before.count == after.count else { return false }
        for (old, new) in zip(before, after) {
            if old.token != new.token { return false }
            if old.range.lowerBound < editAt && editAt < old.range.upperBound { return false }
            let shift = old.range.lowerBound >= editAt ? delta : 0
            let moved = (old.range.lowerBound + shift)..<(old.range.upperBound + shift)
            if new.range != moved { return false }
        }
        return true
    }

    /// UTF-16 length of the list prefix a wrapped row should line up under.
    /// Nil when `line` is not a list item. The source is not rewritten.
    public static func listHangPrefixUTF16(_ line: String) -> Int? {
        Scanner.listHangPrefixUTF16(line)
    }

    /// UTF-16 span of `changed` lines. The caller restyles that span; later lines
    /// keep the attributes AppKit shifted with the edit.
    public func lineSpan(_ changed: Range<Int>) -> Range<Int> {
        guard !lines.isEmpty, !changed.isEmpty else { return 0..<utf16Count }
        let lower = min(changed.lowerBound, lines.count - 1)
        let upperIndex = changed.upperBound
        let upper = upperIndex >= lines.count ? (lines.last?.end ?? 0) : lines[upperIndex].start
        return lines[lower].start..<max(lines[lower].start, upper)
    }

    private mutating func installLines(_ text: String) {
        let parsed = LineSplit.lines(in: text)
        var entering = BlockState()
        if text.hasPrefix("---") { entering.inFrontmatter = true }
        source = text
        sourceValid = true
        ready = true
        lines = parsed
        lineStarts = parsed.map(\.start)
        states = [entering]
        storedSpans = []
        spanCounts = []
        shift = 0
        shiftLine = 0
    }

    private mutating func installFull(_ text: String) {
        installLines(text)
        if !lines.isEmpty {
            ensureScanned(throughLine: lines.count - 1)
        }
    }

    /// Tokenize lines up through `target` that are not scanned yet. Already-scanned
    /// lines are left alone, including a pending suffix shift.
    public mutating func ensureScanned(throughLine target: Int) {
        guard ready, !lines.isEmpty else { return }
        let goal = min(max(0, target), lines.count - 1)
        guard spanCounts.count <= goal else { return }
        materializeAll()
        var entering = states.last ?? BlockState()
        if states.isEmpty {
            entering = BlockState()
            states = [entering]
        }
        var index = spanCounts.count
        while index <= goal {
            let (produced, exit) = Scanner.scan(line: lines[index], entering: entering)
            storedSpans.append(contentsOf: produced)
            spanCounts.append(produced.count)
            entering = exit
            states.append(entering)
            index += 1
        }
    }

    /// Absolute spans that overlap `utf16`, scanning any gap in front of that range.
    public mutating func spans(overlapping utf16: Range<Int>) -> [TokenSpan] {
        guard !lines.isEmpty, !utf16.isEmpty, utf16Count > 0 else { return [] }
        let endProbe = min(max(utf16.lowerBound, utf16.upperBound - 1), utf16Count - 1)
        let first = LineSplit.lineIndex(containing: min(utf16.lowerBound, utf16Count - 1), starts: lineStarts)
        let last = LineSplit.lineIndex(containing: endProbe, starts: lineStarts)
        ensureScanned(throughLine: last)
        guard first < spanCounts.count else { return [] }
        var index = spanIndex(ofLine: first)
        var result: [TokenSpan] = []
        let stop = min(last, spanCounts.count - 1)
        for line in first...stop {
            let count = spanCounts[line]
            let extra = (shift != 0 && line >= shiftLine) ? shift : 0
            for _ in 0..<count {
                guard index < storedSpans.count else { break }
                var span = storedSpans[index]
                index += 1
                if extra != 0 {
                    span.range = (span.range.lowerBound + extra)..<(span.range.upperBound + extra)
                }
                if span.range.upperBound > utf16.lowerBound, span.range.lowerBound < utf16.upperBound {
                    result.append(span)
                }
            }
        }
        return result
    }

    /// True when the line under `utf16` contains a pipe. Table edits use this
    /// to skip the plain-shift fast path, which would leave column kern stale.
    public func lineContainsPipe(at utf16: Int) -> Bool {
        guard !lines.isEmpty, utf16Count > 0 else { return false }
        let probe = min(max(0, utf16), utf16Count - 1)
        let index = LineSplit.lineIndex(containing: probe, starts: lineStarts)
        return lines[index].text.contains("|")
    }

    /// Tables overlapping `utf16`. Rows outside the range are included so column
    /// widths stay correct. Lines with no pipe nearby are not parsed.
    public mutating func tableBlocks(overlapping utf16: Range<Int>) -> [TableBlock] {
        guard ready, !lines.isEmpty, !utf16.isEmpty, utf16Count > 0 else { return [] }
        let lower = min(max(0, utf16.lowerBound), utf16Count - 1)
        let upper = min(max(lower, utf16.upperBound - 1), utf16Count - 1)
        let first = LineSplit.lineIndex(containing: lower, starts: lineStarts)
        let last = LineSplit.lineIndex(containing: upper, starts: lineStarts)
        if !pipeNear(first, last) { return [] }
        ensureScanned(throughLine: last)
        var start = first
        while start > 0, MarkdownTables.tableLine(lines, start - 1, isBlocked: lineBlocked) {
            start -= 1
        }
        var end = last
        while end + 1 < lines.count {
            ensureScanned(throughLine: end + 1)
            if !MarkdownTables.tableLine(lines, end + 1, isBlocked: lineBlocked) { break }
            end += 1
        }
        return MarkdownTables.blocks(lines: lines, from: start, through: end, isBlocked: lineBlocked)
    }

    private func pipeNear(_ first: Int, _ last: Int) -> Bool {
        let lower = max(0, first - 1)
        let upper = min(lines.count - 1, last + 1)
        guard lower <= upper else { return false }
        for index in lower...upper where lines[index].text.contains("|") {
            return true
        }
        return false
    }

    private func lineBlocked(_ index: Int) -> Bool {
        guard index >= 0, index < states.count else { return false }
        return states[index].inFence || states[index].inFrontmatter
    }

    private func spanIndex(ofLine line: Int) -> Int {
        spanCounts.prefix(min(max(0, line), spanCounts.count)).reduce(0, +)
    }

    private mutating func materializeAll() {
        materialize(beforeLine: spanCounts.count)
    }

    /// Make stored ranges absolute for lines before `line`. The tail keeps `shift`.
    private mutating func materialize(beforeLine line: Int) {
        guard shift != 0 else { return }
        let endLine = min(max(0, line), spanCounts.count)
        guard shiftLine < endLine else { return }
        let start = spanIndex(ofLine: shiftLine)
        let end = spanIndex(ofLine: endLine)
        if start < end {
            for index in start..<min(end, storedSpans.count) {
                let range = storedSpans[index].range
                storedSpans[index].range = (range.lowerBound + shift)..<(range.upperBound + shift)
            }
        }
        shiftLine = endLine
        if shiftLine >= spanCounts.count {
            shift = 0
            shiftLine = 0
        }
    }

    public func spans(onLine line: Int, in text: String) -> [TokenSpan] {
        let lines = LineSplit.lines(in: text)
        guard lines.indices.contains(line) else { return [] }
        let start = lines[line].start
        let end = lines[line].end
        return spans.filter { $0.range.lowerBound >= start && $0.range.lowerBound < end }
    }
}

enum LineSplit {
    struct Line: Equatable {
        var text: String
        var start: Int
        var end: Int
        var isBlank: Bool
    }

    /// Markdown lines: `LineIndex` lines up to its `lastLine`, so a final `\n`
    /// ends the last line instead of adding an empty one. `text` excludes the `\n`.
    static func lines(in text: String) -> [Line] {
        var cursor = Cursor(text)
        return bounds(in: text).map { materialize(text, $0, cursor: &cursor) }
    }

    struct Bounds {
        var start: Int
        /// Offset of the line's `\n`, or `end` when it has none.
        var contentEnd: Int
        var end: Int
        var isBlank: Bool
    }

    /// Walks forward through `text` in UTF-16 units, so a slice never stops inside
    /// a grapheme that straddles a line break.
    struct Cursor {
        var index: String.Index
        var utf16: Int

        init(_ text: String) {
            index = text.startIndex
            utf16 = 0
        }

        mutating func slice(_ text: String, start: Int, end: Int) -> String {
            let units = text.utf16
            let begin = units.index(index, offsetBy: start - utf16)
            let finish = units.index(begin, offsetBy: end - start)
            index = finish
            utf16 = end
            return String(text[begin..<finish])
        }
    }

    static func bounds(in text: String) -> [Bounds] {
        if text.isEmpty { return [] }
        let index = LineIndex(text)
        var units = text.utf16.makeIterator()
        return (0...index.lastLine).map { number in
            let line = index.line(number)
            var isBlank = true
            for _ in line.start..<line.contentEnd {
                let unit = units.next()
                if unit != 32, unit != 9 { isBlank = false }
            }
            if line.hasNewline { _ = units.next() }
            return Bounds(start: line.start, contentEnd: line.contentEnd, end: line.end, isBlank: isBlank)
        }
    }

    static func materialize(_ text: String, _ bounds: Bounds, cursor: inout Cursor) -> Line {
        let content = cursor.slice(text, start: bounds.start, end: bounds.contentEnd)
        cursor.utf16 = bounds.end
        cursor.index = text.utf16.index(cursor.index, offsetBy: bounds.end - bounds.contentEnd)
        return Line(text: content, start: bounds.start, end: bounds.end, isBlank: bounds.isBlank)
    }

    static func lineIndex(containing offset: Int, lines: [Line]) -> Int {
        lineIndex(containing: offset, starts: lines.map(\.start))
    }

    static func lineIndex(containing offset: Int, bounds: [Bounds]) -> Int {
        guard !bounds.isEmpty else { return 0 }
        var low = 0
        var high = bounds.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if bounds[mid].start <= offset { low = mid } else { high = mid - 1 }
        }
        return low
    }

    static func storageForm(_ line: Line) -> String {
        if line.end > line.start + line.text.utf16.count {
            return line.text + "\n"
        }
        return line.text
    }

    static func utf16Slice(_ text: String, from: Int, to: Int) -> String {
        if to <= from || from < 0 { return "" }
        let view = text.utf16
        guard let start = view.index(view.startIndex, offsetBy: from, limitedBy: view.endIndex) else { return "" }
        let end = view.index(start, offsetBy: to - from, limitedBy: view.endIndex) ?? view.endIndex
        return String(decoding: view[start..<end], as: UTF16.self)
    }

    static func lineIndex(containing offset: Int, starts: [Int]) -> Int {
        guard !starts.isEmpty else { return 0 }
        var low = 0
        var high = starts.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if starts[mid] <= offset { low = mid } else { high = mid - 1 }
        }
        return low
    }

    static func commonSuffixLength(_ a: String, _ b: String, maxLength: Int) -> Int {
        if maxLength <= 0 { return 0 }
        let au = a.utf16
        let bu = b.utf16
        var ai = au.endIndex
        var bi = bu.endIndex
        var count = 0
        while count < maxLength {
            if ai == au.startIndex || bi == bu.startIndex { break }
            au.formIndex(before: &ai)
            bu.formIndex(before: &bi)
            if au[ai] != bu[bi] { break }
            count += 1
        }
        return count
    }

    static func blank(_ line: String) -> Bool {
        for ch in line where ch != " " && ch != "\t" { return false }
        return true
    }

    static func paragraphRange(in text: String, utf16: Int) -> Range<Int> {
        let lines = bounds(in: text)
        guard !lines.isEmpty else { return 0..<0 }
        var index = lineIndex(containing: utf16, starts: lines.map(\.start))
        while index > 0, !lines[index].isBlank, !lines[index - 1].isBlank { index -= 1 }
        var end = index
        while end < lines.count, !lines[end].isBlank { end += 1 }
        let upper = end < lines.count ? lines[end].start : (lines.last?.end ?? 0)
        return lines[index].start..<upper
    }
}

enum Scanner {
    static func scan(line: LineSplit.Line, entering: BlockState) -> ([TokenSpan], BlockState) {
        var exit = entering
        let raw = line.text
        if entering.inFrontmatter {
            if raw == "---", line.start > 0 { exit.inFrontmatter = false }
            return ([TokenSpan(range: line.start..<line.end, token: .frontmatter)], exit)
        }
        if raw.hasPrefix("```") {
            exit.inFence.toggle()
            return ([TokenSpan(range: line.start..<line.end, token: .fence)], exit)
        }
        if entering.inFence {
            return ([TokenSpan(range: line.start..<line.end, token: .fence)], exit)
        }
        var spans: [TokenSpan] = []
        if let level = headingLevel(raw) {
            spans.append(TokenSpan(range: line.start..<(line.start + level), token: .syntaxMarker))
            spans.append(TokenSpan(range: line.start..<(line.start + raw.utf16.count), token: .heading(level)))
        }
        if let marker = listMarkerUTF16(raw) {
            spans.append(TokenSpan(range: line.start..<(line.start + marker), token: .listMarker))
        }
        spans.append(contentsOf: inline(raw, lineStart: line.start))
        return (spans, exit)
    }

    static func headingLevel(_ line: String) -> Int? {
        var level = 0
        var index = line.startIndex
        while index < line.endIndex, line[index] == "#" {
            level += 1
            index = line.index(after: index)
            if level > 6 { return nil }
        }
        guard level >= 1, index < line.endIndex, line[index] == " " else { return nil }
        return level
    }

    static func listMarkerUTF16(_ line: String) -> Int? {
        var index = line.startIndex
        var indent = 0
        while index < line.endIndex, line[index] == " " || line[index] == "\t" {
            indent += line[index].utf16.count
            index = line.index(after: index)
        }
        let rest = line[index...]
        if rest.hasPrefix("- ") || rest.hasPrefix("* ") || rest.hasPrefix("+ ") {
            return indent + 2
        }
        var digits = 0
        var cursor = rest.startIndex
        while cursor < rest.endIndex, rest[cursor].isNumber {
            digits += 1
            cursor = rest.index(after: cursor)
        }
        if digits > 0, rest[cursor...].hasPrefix(". ") {
            return indent + digits + 2
        }
        return nil
    }

    /// UTF-16 length of the prefix a wrapped list line hangs under.
    /// The marker, a task box written against that marker (`[ ]`, `[x]`, `[X]`),
    /// and the single space or tab after the box. Nil when `line` is not a list item.
    static func listHangPrefixUTF16(_ line: String) -> Int? {
        guard let marker = listMarkerUTF16(line) else { return nil }
        let units = line.utf16
        guard let box = units.index(units.startIndex, offsetBy: marker, limitedBy: units.endIndex),
              let mark = units.index(box, offsetBy: 1, limitedBy: units.endIndex),
              let close = units.index(box, offsetBy: 2, limitedBy: units.endIndex),
              close < units.endIndex
        else { return marker }
        let openUnit = units[box]
        let markUnit = units[mark]
        let closeUnit = units[close]
        guard openUnit == 0x5B, closeUnit == 0x5D, markUnit == 0x20 || markUnit == 0x78 || markUnit == 0x58 else {
            return marker
        }
        var end = marker + 3
        let after = units.index(after: close)
        if after < units.endIndex {
            let unit = units[after]
            if unit == 0x20 || unit == 0x09 { end += 1 }
        }
        return end
    }

    static func inline(_ line: String, lineStart: Int) -> [TokenSpan] {
        var spans: [TokenSpan] = []
        var index = line.startIndex
        var utf16 = 0
        while index < line.endIndex {
            let ch = line[index]
            if ch == "`", let end = line[line.index(after: index)...].firstIndex(of: "`") {
                let close = line.utf16.distance(from: line.startIndex, to: end)
                spans.append(TokenSpan(range: (lineStart + utf16)..<(lineStart + utf16 + 1), token: .syntaxMarker))
                spans.append(TokenSpan(range: (lineStart + utf16)..<(lineStart + close + 1), token: .codeSpan))
                spans.append(TokenSpan(range: (lineStart + close)..<(lineStart + close + 1), token: .syntaxMarker))
                utf16 = close + 1
                index = line.index(after: end)
                continue
            }
            if ch == "*", line[line.index(after: index)...].hasPrefix("*") {
                let from = line.index(index, offsetBy: 2, limitedBy: line.endIndex) ?? line.endIndex
                if let end = doubleStar(line, from: from) {
                    let close = line.utf16.distance(from: line.startIndex, to: end)
                    spans.append(TokenSpan(range: (lineStart + utf16)..<(lineStart + utf16 + 2), token: .syntaxMarker))
                    spans.append(TokenSpan(range: (lineStart + utf16 + 2)..<(lineStart + close), token: .strong))
                    spans.append(TokenSpan(range: (lineStart + close)..<(lineStart + close + 2), token: .syntaxMarker))
                    utf16 = close + 2
                    index = line.index(end, offsetBy: 2)
                    continue
                }
            }
            if ch == "*", let end = line[line.index(after: index)...].firstIndex(of: "*"), line.distance(from: index, to: end) > 1 {
                let close = line.utf16.distance(from: line.startIndex, to: end)
                spans.append(TokenSpan(range: (lineStart + utf16)..<(lineStart + utf16 + 1), token: .syntaxMarker))
                spans.append(TokenSpan(range: (lineStart + utf16 + 1)..<(lineStart + close), token: .emphasis))
                spans.append(TokenSpan(range: (lineStart + close)..<(lineStart + close + 1), token: .syntaxMarker))
                utf16 = close + 1
                index = line.index(after: end)
                continue
            }
            if ch == "[", line[line.index(after: index)...].hasPrefix("[") {
                if let end = wikiClose(line, from: line.index(index, offsetBy: 2)) {
                    let close = line.utf16.distance(from: line.startIndex, to: end) + 2
                    spans.append(TokenSpan(range: (lineStart + utf16)..<(lineStart + close), token: .wikilink))
                    spans.append(TokenSpan(range: (lineStart + utf16)..<(lineStart + utf16 + 2), token: .syntaxMarker))
                    utf16 = close
                    index = line.index(end, offsetBy: 2)
                    continue
                }
            }
            if ch == "[", let next = line.index(index, offsetBy: 2, limitedBy: line.endIndex), next < line.endIndex, line[line.index(after: index)] != "\n" {
                let mark = line[line.index(after: index)]
                if line[next] == "]", mark == " " || mark == "x" || mark == "X" {
                    spans.append(TokenSpan(range: (lineStart + utf16)..<(lineStart + utf16 + 3), token: .taskBox))
                    utf16 += 3
                    index = line.index(after: next)
                    continue
                }
            }
            utf16 += ch.utf16.count
            index = line.index(after: index)
        }
        return spans
    }

    static func doubleStar(_ line: String, from: String.Index) -> String.Index? {
        var index = from
        while index < line.endIndex {
            if line[index] == "*", let next = line.index(after: index) as String.Index?, next < line.endIndex, line[next] == "*" {
                return index
            }
            index = line.index(after: index)
        }
        return nil
    }

    static func wikiClose(_ line: String, from: String.Index) -> String.Index? {
        var index = from
        while index < line.endIndex {
            if line[index] == "]", let next = line.index(after: index) as String.Index?, next < line.endIndex, line[next] == "]" {
                return index
            }
            index = line.index(after: index)
        }
        return nil
    }
}

public enum WikilinkQuery {
    public static func at(cursor utf16: Int, in text: String) -> String? {
        let units = Array(text.utf16)
        guard !units.isEmpty else { return nil }
        var i = min(max(0, utf16), units.count - 1)
        var start: Int?
        while i >= 1 {
            if units[i] == 93, units[i - 1] == 93 { return nil }
            if units[i] == 91, units[i - 1] == 91 {
                start = i + 1
                break
            }
            i -= 1
        }
        guard let start else { return nil }
        var end = start
        while end < units.count, units[end] != 93 { end += 1 }
        return String(decoding: units[start..<end], as: UTF16.self)
    }

    public static func prefix(before utf16: Int, in text: String) -> String? {
        let limit = min(utf16, text.utf16.count)
        let units = Array(text.utf16.prefix(limit))
        guard units.count >= 2 else { return nil }
        var i = units.count - 1
        while i >= 1 {
            if units[i] == 93 { return nil }
            if units[i] == 91, units[i - 1] == 91 {
                return String(decoding: units[(i + 1)...], as: UTF16.self)
            }
            i -= 1
        }
        return nil
    }
}

public enum Paragraphs {
    public static func range(in text: String, utf16: Int) -> Range<Int> {
        LineSplit.paragraphRange(in: text, utf16: utf16)
    }
}
