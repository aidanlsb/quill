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

    public init(text: String) {
        states = []
        spans = []
        _ = replace(text: text, dirtyUTF16: 0)
    }

    /// Rebuild spans, and report the line range whose block state changed.
    /// The view restyles that range; later lines are reused once a fence or
    /// frontmatter state converges.
    @discardableResult
    public mutating func replace(text: String, dirtyUTF16: Int) -> Range<Int> {
        let lines = LineSplit.lines(in: text)
        let dirty = LineSplit.lineIndex(containing: dirtyUTF16, lines: lines)
        let previous = states
        var entering = BlockState()
        if text.hasPrefix("---") { entering.inFrontmatter = true }
        var nextStates: [BlockState] = []
        nextStates.reserveCapacity(lines.count + 1)
        var nextSpans: [TokenSpan] = []
        var changedEnd = lines.count
        var stopped = false
        for (index, line) in lines.enumerated() {
            nextStates.append(entering)
            if !stopped {
                let (produced, exit) = Scanner.scan(line: line, entering: entering)
                nextSpans.append(contentsOf: produced)
                let cachedExit = index + 1 < previous.count ? previous[index + 1] : nil
                entering = exit
                if index >= dirty, let cachedExit, cachedExit == exit, index + 1 < lines.count {
                    changedEnd = index + 1
                    stopped = true
                }
            }
            if stopped, index + 1 < lines.count {
                // Later lines keep the cached entering state. Their spans are
                // rebuilt from that state so offsets stay correct after the edit.
                let (produced, exit) = Scanner.scan(line: lines[index + 1], entering: entering)
                _ = produced
                _ = exit
            }
        }
        if stopped {
            nextSpans.removeAll()
            entering = nextStates.first ?? BlockState()
            if text.hasPrefix("---") { entering.inFrontmatter = true }
            nextStates = []
            for line in lines {
                nextStates.append(entering)
                let (produced, exit) = Scanner.scan(line: line, entering: entering)
                nextSpans.append(contentsOf: produced)
                entering = exit
            }
        }
        nextStates.append(entering)
        states = nextStates
        spans = nextSpans
        if lines.isEmpty { return 0..<0 }
        return dirty..<max(dirty, changedEnd)
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
    struct Line {
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

    static func lineIndex(containing offset: Int, lines: [Line]) -> Int {
        guard !lines.isEmpty else { return 0 }
        var low = 0
        var high = lines.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if lines[mid].start <= offset { low = mid } else { high = mid - 1 }
        }
        return low
    }

    static func blank(_ line: String) -> Bool {
        for ch in line where ch != " " && ch != "\t" { return false }
        return true
    }

    static func paragraphRange(in text: String, utf16: Int) -> Range<Int> {
        let lines = lines(in: text)
        guard !lines.isEmpty else { return 0..<0 }
        var index = lineIndex(containing: utf16, lines: lines)
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
