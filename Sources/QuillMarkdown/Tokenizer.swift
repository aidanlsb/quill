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
    public private(set) var spans: [TokenSpan]
    private var source: String
    /// False after `apply`, which does not rewrite `source`. The next full
    /// `replace` rebuilds from the caller's string instead of diffing a stale one.
    private var sourceValid: Bool
    private var ready: Bool
    private var lines: [LineSplit.Line]
    private var lineStarts: [Int]
    /// How many spans each line owns. Parallel to `lineStarts`.
    private var spanCounts: [Int]

    public init(text: String) {
        states = []
        spans = []
        source = ""
        sourceValid = false
        ready = false
        lines = []
        lineStarts = []
        spanCounts = []
        _ = replace(text: text, dirtyUTF16: 0)
    }

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

        let prefixSpans = spanCounts.prefix(first).reduce(0, +)
        var mergedSpans = Array(spans.prefix(prefixSpans))
        mergedSpans.append(contentsOf: produced)
        var mergedCounts = Array(spanCounts.prefix(first)) + producedCounts
        var mergedStates = Array(states.prefix(first)) + producedStates
        if let nextOld = convergedOld {
            let suffixSpanStart = spanCounts.prefix(nextOld).reduce(0, +)
            if delta == 0 {
                mergedSpans.append(contentsOf: spans[suffixSpanStart...])
            } else {
                for span in spans[suffixSpanStart...] {
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
        spans = mergedSpans
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
        let newCount = newLines.count
        var rebuilt: [LineSplit.Line] = []
        rebuilt.reserveCapacity(lines.count - (last - first + 1) + newCount)
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
        sourceValid = false

        let replacedEnd = first + newCount
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

        let prefixSpans = spanCounts.prefix(first).reduce(0, +)
        var mergedSpans = Array(spans.prefix(prefixSpans))
        mergedSpans.append(contentsOf: produced)
        var mergedCounts = Array(spanCounts.prefix(first)) + producedCounts
        var mergedStates = Array(states.prefix(first)) + producedStates
        if let nextOld = convergedOld {
            let suffixSpanStart = spanCounts.prefix(nextOld).reduce(0, +)
            if delta == 0 {
                if suffixSpanStart < spans.count {
                    mergedSpans.append(contentsOf: spans[suffixSpanStart...])
                }
            } else if suffixSpanStart < spans.count {
                for span in spans[suffixSpanStart...] {
                    mergedSpans.append(TokenSpan(
                        range: (span.range.lowerBound + delta)..<(span.range.upperBound + delta),
                        token: span.token
                    ))
                }
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
        spans = mergedSpans
        spanCounts = mergedCounts
        states = mergedStates
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

    /// UTF-16 span of `changed` lines. The caller restyles that span; later lines
    /// keep the attributes AppKit shifted with the edit.
    public func lineSpan(_ changed: Range<Int>) -> Range<Int> {
        guard !lines.isEmpty, !changed.isEmpty else { return 0..<utf16Count }
        let lower = min(changed.lowerBound, lines.count - 1)
        let upperIndex = changed.upperBound
        let upper = upperIndex >= lines.count ? (lines.last?.end ?? 0) : lines[upperIndex].start
        return lines[lower].start..<max(lines[lower].start, upper)
    }

    private mutating func installFull(_ text: String) {
        let parsed = LineSplit.lines(in: text)
        var entering = BlockState()
        if text.hasPrefix("---") { entering.inFrontmatter = true }
        var nextStates: [BlockState] = []
        var nextSpans: [TokenSpan] = []
        var counts: [Int] = []
        nextStates.reserveCapacity(parsed.count + 1)
        counts.reserveCapacity(parsed.count)
        for line in parsed {
            nextStates.append(entering)
            let before = nextSpans.count
            let (produced, exit) = Scanner.scan(line: line, entering: entering)
            nextSpans.append(contentsOf: produced)
            counts.append(nextSpans.count - before)
            entering = exit
        }
        nextStates.append(entering)
        source = text
        sourceValid = true
        ready = true
        lines = parsed
        lineStarts = parsed.map(\.start)
        states = nextStates
        spans = nextSpans
        spanCounts = counts
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

    static func lines(in text: String) -> [Line] {
        if text.isEmpty { return [] }
        var result: [Line] = []
        var startIndex = text.startIndex
        var startUTF16 = 0
        var index = text.startIndex
        while index < text.endIndex {
            if text[index] == "\n" {
                let slice = text[startIndex..<index]
                let line = String(slice)
                let endUTF16 = startUTF16 + line.utf16.count + 1
                result.append(Line(text: line, start: startUTF16, end: endUTF16, isBlank: blank(line)))
                startUTF16 = endUTF16
                index = text.index(after: index)
                startIndex = index
                continue
            }
            index = text.index(after: index)
        }
        if startIndex < text.endIndex {
            let line = String(text[startIndex..<text.endIndex])
            result.append(Line(
                text: line,
                start: startUTF16,
                end: startUTF16 + line.utf16.count,
                isBlank: blank(line)
            ))
        }
        return result
    }

    struct Bounds {
        var start: Int
        var end: Int
        var isBlank: Bool
    }

    struct Cursor {
        var index: String.Index
        var utf16: Int

        init(_ text: String) {
            index = text.startIndex
            utf16 = 0
        }

        mutating func slice(_ text: String, start: Int, end: Int) -> String {
            while utf16 < start, index < text.endIndex {
                utf16 += text[index].utf16.count
                index = text.index(after: index)
            }
            let begin = index
            var cursor = index
            var pos = utf16
            while pos < end, cursor < text.endIndex {
                pos += text[cursor].utf16.count
                cursor = text.index(after: cursor)
            }
            index = cursor
            utf16 = pos
            return String(text[begin..<cursor])
        }
    }

    static func bounds(in text: String) -> [Bounds] {
        if text.isEmpty { return [] }
        var result: [Bounds] = []
        var lineStart = 0
        var utf16 = 0
        var lineBlank = true
        for character in text {
            if character == "\n" {
                let end = utf16 + 1
                result.append(Bounds(start: lineStart, end: end, isBlank: lineBlank))
                utf16 = end
                lineStart = end
                lineBlank = true
                continue
            }
            if character != " ", character != "\t" { lineBlank = false }
            utf16 += character.utf16.count
        }
        if lineStart < utf16 {
            result.append(Bounds(start: lineStart, end: utf16, isBlank: lineBlank))
        }
        return result
    }

    static func materialize(_ text: String, _ bounds: Bounds, cursor: inout Cursor) -> Line {
        let raw = cursor.slice(text, start: bounds.start, end: bounds.end)
        let content = raw.hasSuffix("\n") ? String(raw.dropLast()) : raw
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
            if ch == "[", let next = line.index(index, offsetBy: 2, limitedBy: line.endIndex), line[line.index(after: index)] != "\n" {
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

/// Theme files are JSON objects. Parsing stays dependency-free: name, focusDim, and token color strings.
public struct ThemeFile: Equatable, Sendable {
    public var name: String
    public var focusDim: Bool
    public var colors: [String: String]

    public init(name: String, focusDim: Bool = true, colors: [String: String] = [:]) {
        self.name = name
        self.focusDim = focusDim
        self.colors = colors
    }

    public static func parse(_ json: String) -> ThemeFile? {
        func find(_ needle: String, in text: String) -> String.Index? {
            var index = text.startIndex
            while index < text.endIndex {
                if text[index...].hasPrefix(needle) { return index }
                index = text.index(after: index)
            }
            return nil
        }
        func string(after key: String) -> String? {
            guard let found = find("\"\(key)\"", in: json) else { return nil }
            let rest = json[found...]
            guard let colon = rest.firstIndex(of: ":"),
                  let open = rest[colon...].firstIndex(of: "\""),
                  let close = rest[rest.index(after: open)...].firstIndex(of: "\"") else { return nil }
            return String(rest[rest.index(after: open)..<close])
        }
        guard let name = string(after: "name") else { return nil }
        var colors: [String: String] = [:]
        for key in ["text", "syntax", "code", "link", "dim", "background"] {
            if let value = string(after: key) { colors[key] = value }
        }
        let dim = !json.contains("\"focusDim\"") || json.contains("true")
        return ThemeFile(name: name, focusDim: dim, colors: colors)
    }
}
