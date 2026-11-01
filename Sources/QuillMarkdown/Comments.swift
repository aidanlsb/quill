/// CriticMarkup comments stored in the markdown itself.
/// A standalone comment is `{>>body<<}`. An anchored comment is
/// `{==passage==}{>>body<<}`. Both stay on one line; a span that would
/// cross a newline is not a comment. Code spans and fences are not comments.
public struct InlineComment: Equatable, Sendable {
    /// UTF-16 range of the whole construct, markers included.
    public var range: Range<Int>
    /// Inner highlighted passage, without `{==` / `==}`. Nil when standalone.
    public var highlight: Range<Int>?
    /// Inner comment text, without `{>>` / `<<}`. Empty for `{>><<}`.
    public var body: Range<Int>

    public init(range: Range<Int>, highlight: Range<Int>? = nil, body: Range<Int>) {
        self.range = range
        self.highlight = highlight
        self.body = body
    }

    /// Text left after resolving: the highlighted passage, or nothing.
    public func resolvedText(in text: String) -> String {
        guard let highlight else { return "" }
        return LineSplit.utf16Slice(text, from: highlight.lowerBound, to: highlight.upperBound)
    }

    public func bodyText(in text: String) -> String {
        LineSplit.utf16Slice(text, from: body.lowerBound, to: body.upperBound)
    }

    public func highlightText(in text: String) -> String? {
        guard let highlight else { return nil }
        return LineSplit.utf16Slice(text, from: highlight.lowerBound, to: highlight.upperBound)
    }
}

public enum MarkdownComments {
    public static let open = "{>>"
    public static let close = "<<}"
    public static let highlightOpen = "{=="
    public static let highlightClose = "==}"
    public static let empty = "{>><<}"

    /// Wrap a one-line visual selection as an anchored comment ready for typing.
    public static func wrap(_ selected: String) -> String {
        highlightOpen + selected + highlightClose + empty
    }

    /// UTF-16 offset of the caret inside a just-inserted empty comment body.
    public static var emptyBodyUTF16: Int { 3 }

    /// UTF-16 offset of the caret inside a wrapped selection's empty comment body.
    public static func wrapInsertUTF16(selectedUTF16: Int) -> Int {
        highlightOpen.utf16.count + selectedUTF16 + highlightClose.utf16.count + emptyBodyUTF16
    }

    /// True when wrapping `selected` would cross a line.
    public static func isSingleLine(_ selected: String) -> Bool {
        !selected.contains(where: { $0 == "\n" || $0 == "\r" })
    }

    /// Every comment outside frontmatter, fenced code, and inline code.
    public static func find(in text: String) -> [InlineComment] {
        var comments: [InlineComment] = []
        var index = text.startIndex
        var utf16 = 0
        var line = 0
        var inFence = false
        var inFrontmatter = text.hasPrefix("---")
        while index < text.endIndex {
            let lineStart = index
            let lineUTF = utf16
            var hasBrace = false
            while index < text.endIndex, text[index] != "\n" {
                if text[index] == "{" { hasBrace = true }
                utf16 += text[index].utf16.count
                index = text.index(after: index)
            }
            let lineEnd = index
            if inFrontmatter {
                if line > 0, text[lineStart..<lineEnd] == "---" {
                    inFrontmatter = false
                }
            } else if isFence(text, lineStart, lineEnd) {
                inFence.toggle()
            } else if !inFence, hasBrace {
                let slice = String(text[lineStart..<lineEnd])
                comments.append(contentsOf: inLine(slice, lineStart: lineUTF))
            }
            if index < text.endIndex {
                utf16 += text[index].utf16.count
                index = text.index(after: index)
            }
            line += 1
        }
        return comments
    }

    public static func at(cursor utf16: Int, in text: String) -> InlineComment? {
        let comments = find(in: text)
        return comments.last { $0.range.lowerBound <= utf16 && utf16 < $0.range.upperBound }
            ?? comments.last { $0.range.lowerBound <= utf16 && utf16 == $0.range.upperBound && $0.range.upperBound == text.utf16.count }
    }

    /// Next comment starting after `utf16`, or previous starting before it.
    public static func jump(from utf16: Int, forward: Bool, in text: String) -> InlineComment? {
        let comments = find(in: text)
        if forward {
            return comments.first { $0.range.lowerBound > utf16 }
        }
        return comments.last { $0.range.lowerBound < utf16 }
    }

    public static func inLine(_ line: String, lineStart: Int) -> [InlineComment] {
        var comments: [InlineComment] = []
        var index = line.startIndex
        var utf16 = 0
        while index < line.endIndex {
            let ch = line[index]
            if ch == "`", let end = line[line.index(after: index)...].firstIndex(of: "`") {
                let close = line.utf16.distance(from: line.startIndex, to: end)
                utf16 = close + 1
                index = line.index(after: end)
                continue
            }
            if ch == "{", let match = CriticMarkup.match(in: line, from: index, utf16: utf16, lineStart: lineStart) {
                comments.append(match.comment)
                utf16 = match.endUTF16
                index = match.end
                continue
            }
            utf16 += ch.utf16.count
            index = line.index(after: index)
        }
        return comments
    }

    public static func tokenSpans(for comment: InlineComment) -> [TokenSpan] {
        var spans: [TokenSpan] = []
        let start = comment.range.lowerBound
        let end = comment.range.upperBound
        if let highlight = comment.highlight {
            spans.append(TokenSpan(range: start..<(start + 3), token: .syntaxMarker))
            if !highlight.isEmpty {
                spans.append(TokenSpan(range: highlight, token: .commentHighlight))
            }
            spans.append(TokenSpan(range: highlight.upperBound..<(highlight.upperBound + 3), token: .syntaxMarker))
            let open = highlight.upperBound + 3
            spans.append(TokenSpan(range: open..<(open + 3), token: .syntaxMarker))
            if !comment.body.isEmpty {
                spans.append(TokenSpan(range: comment.body, token: .comment))
            }
            spans.append(TokenSpan(range: (end - 3)..<end, token: .syntaxMarker))
        } else {
            spans.append(TokenSpan(range: start..<(start + 3), token: .syntaxMarker))
            if !comment.body.isEmpty {
                spans.append(TokenSpan(range: comment.body, token: .comment))
            }
            spans.append(TokenSpan(range: (end - 3)..<end, token: .syntaxMarker))
        }
        return spans
    }

    private static func isFence(_ text: String, _ start: String.Index, _ end: String.Index) -> Bool {
        var index = start
        var spaces = 0
        while index < end, text[index] == " ", spaces < 3 {
            spaces += 1
            index = text.index(after: index)
        }
        guard index < end else { return false }
        return hasPrefix(text, index, end, "```") || hasPrefix(text, index, end, "~~~")
    }

    private static func hasPrefix(_ text: String, _ start: String.Index, _ end: String.Index, _ prefix: String) -> Bool {
        var index = start
        for character in prefix {
            if index >= end || text[index] != character { return false }
            index = text.index(after: index)
        }
        return true
    }
}

enum CriticMarkup {
    struct Match {
        var comment: InlineComment
        var end: String.Index
        var endUTF16: Int
    }

    static func match(in line: String, from index: String.Index, utf16: Int, lineStart: Int) -> Match? {
        guard index < line.endIndex, line[index] == "{" else { return nil }
        let rest = line[index...]
        if rest.hasPrefix(MarkdownComments.highlightOpen) {
            return matchAnchored(in: line, from: index, utf16: utf16, lineStart: lineStart)
        }
        if rest.hasPrefix(MarkdownComments.open) {
            return matchStandalone(in: line, from: index, utf16: utf16, lineStart: lineStart)
        }
        return nil
    }

    private static func matchAnchored(in line: String, from index: String.Index, utf16: Int, lineStart: Int) -> Match? {
        let openLen = MarkdownComments.highlightOpen.utf16.count
        guard let highlightStart = line.index(index, offsetBy: openLen, limitedBy: line.endIndex) else { return nil }
        guard let mark = find(MarkdownComments.highlightClose, in: line, from: highlightStart) else { return nil }
        let afterHighlight = mark.upperBound
        guard hasPrefix(line, afterHighlight, MarkdownComments.open) else { return nil }
        let commentOpenLen = MarkdownComments.open.utf16.count
        guard let bodyStart = line.index(afterHighlight, offsetBy: commentOpenLen, limitedBy: line.endIndex) else {
            return nil
        }
        guard let close = find(MarkdownComments.close, in: line, from: bodyStart) else { return nil }
        let highlightUTF = line.utf16.distance(from: line.startIndex, to: highlightStart)
        let highlightEndUTF = line.utf16.distance(from: line.startIndex, to: mark.lowerBound)
        let bodyUTF = line.utf16.distance(from: line.startIndex, to: bodyStart)
        let closeUTF = line.utf16.distance(from: line.startIndex, to: close.lowerBound)
        let endUTF = closeUTF + MarkdownComments.close.utf16.count
        let abs = lineStart
        return Match(
            comment: InlineComment(
                range: (abs + utf16)..<(abs + endUTF),
                highlight: (abs + highlightUTF)..<(abs + highlightEndUTF),
                body: (abs + bodyUTF)..<(abs + closeUTF)
            ),
            end: close.upperBound,
            endUTF16: endUTF
        )
    }

    private static func matchStandalone(in line: String, from index: String.Index, utf16: Int, lineStart: Int) -> Match? {
        let openLen = MarkdownComments.open.utf16.count
        guard let bodyStart = line.index(index, offsetBy: openLen, limitedBy: line.endIndex) else { return nil }
        guard let close = find(MarkdownComments.close, in: line, from: bodyStart) else { return nil }
        let bodyUTF = line.utf16.distance(from: line.startIndex, to: bodyStart)
        let closeUTF = line.utf16.distance(from: line.startIndex, to: close.lowerBound)
        let endUTF = closeUTF + MarkdownComments.close.utf16.count
        let abs = lineStart
        return Match(
            comment: InlineComment(
                range: (abs + utf16)..<(abs + endUTF),
                highlight: nil,
                body: (abs + bodyUTF)..<(abs + closeUTF)
            ),
            end: close.upperBound,
            endUTF16: endUTF
        )
    }

    /// First `needle` at or after `from`. No Foundation; Linux tests this module.
    private static func find(_ needle: String, in line: String, from: String.Index) -> Range<String.Index>? {
        guard !needle.isEmpty, from < line.endIndex else { return nil }
        var index = from
        while index < line.endIndex {
            if hasPrefix(line, index, needle) {
                return index..<line.index(index, offsetBy: needle.count)
            }
            index = line.index(after: index)
        }
        return nil
    }

    private static func hasPrefix(_ line: String, _ start: String.Index, _ prefix: String) -> Bool {
        var index = start
        for character in prefix {
            guard index < line.endIndex, line[index] == character else { return false }
            index = line.index(after: index)
        }
        return true
    }
}
