public enum TextObjectKind: Equatable, Sendable {
    case innerWord
    case aWord
    case innerWORD
    case aWORD
    case innerSentence
    case aSentence
    case innerParagraph
    case aParagraph
    case innerQuote(Character)
    case aQuote(Character)
    case innerBracket(Character, Character)
    case aBracket(Character, Character)

    public static func parse(inner: Bool, specifier: Character) -> TextObjectKind? {
        switch (inner, specifier) {
        case (true, "w"): return .innerWord
        case (false, "w"): return .aWord
        case (true, "W"): return .innerWORD
        case (false, "W"): return .aWORD
        case (true, "s"): return .innerSentence
        case (false, "s"): return .aSentence
        case (true, "p"): return .innerParagraph
        case (false, "p"): return .aParagraph
        case (true, "\""), (true, "'"), (true, "`"):
            return .innerQuote(specifier)
        case (false, "\""), (false, "'"), (false, "`"):
            return .aQuote(specifier)
        case (true, "("), (true, ")"), (true, "b"):
            return .innerBracket("(", ")")
        case (false, "("), (false, ")"), (false, "b"):
            return .aBracket("(", ")")
        case (true, "["), (true, "]"):
            return .innerBracket("[", "]")
        case (false, "["), (false, "]"):
            return .aBracket("[", "]")
        case (true, "{"), (true, "}"), (true, "B"):
            return .innerBracket("{", "}")
        case (false, "{"), (false, "}"), (false, "B"):
            return .aBracket("{", "}")
        case (true, "<"), (true, ">"):
            return .innerBracket("<", ">")
        case (false, "<"), (false, ">"):
            return .aBracket("<", ">")
        default:
            return nil
        }
    }
}

enum TextObjectResolver {
    static func resolve(_ kind: TextObjectKind, buffer: TextBuffer) -> (Range<Int>, RangeStyle)? {
        switch kind {
        case .innerWord:
            return word(buffer, inner: true, big: false)
        case .aWord:
            return word(buffer, inner: false, big: false)
        case .innerWORD:
            return word(buffer, inner: true, big: true)
        case .aWORD:
            return word(buffer, inner: false, big: true)
        case .innerSentence:
            return sentence(buffer, inner: true)
        case .aSentence:
            return sentence(buffer, inner: false)
        case .innerParagraph:
            return paragraph(buffer, inner: true)
        case .aParagraph:
            return paragraph(buffer, inner: false)
        case .innerQuote(let q):
            return quotes(buffer, quote: q, inner: true)
        case .aQuote(let q):
            return quotes(buffer, quote: q, inner: false)
        case .innerBracket(let open, let close):
            return brackets(buffer, open: open, close: close, inner: true)
        case .aBracket(let open, let close):
            return brackets(buffer, open: open, close: close, inner: false)
        }
    }

    private static func isBlank(_ buffer: TextBuffer, _ offset: Int) -> Bool {
        guard offset >= 0, offset < buffer.count else { return true }
        let c = buffer.charClass(at: offset)
        return c == .whitespace || c == .newline
    }

    private static func word(_ buffer: TextBuffer, inner: Bool, big: Bool) -> (Range<Int>, RangeStyle)? {
        if buffer.isEmpty { return nil }
        let cursor = min(buffer.cursor, max(0, buffer.count - 1))
        let onBlank = isBlank(buffer, cursor)

        var start = cursor
        var end = cursor

        if onBlank {
            while start > 0, isBlank(buffer, start - 1), buffer.character(at: start - 1) != "\n" {
                start -= 1
            }
            while end < buffer.count, isBlank(buffer, end), buffer.character(at: end) != "\n" {
                end += 1
            }
            if inner {
                return (start..<end, .characterwise)
            }
            // aw on whitespace includes the following word
            var w = end
            while w < buffer.count, isBlank(buffer, w) { w += 1 }
            if w < buffer.count {
                let cls = buffer.charClass(at: w)
                w += 1
                while w < buffer.count, matches(buffer.charClass(at: w), cls, big: big) {
                    w += 1
                }
                end = w
            }
            return (start..<end, .characterwise)
        }

        let cls = buffer.charClass(at: cursor)
        while start > 0, matches(buffer.charClass(at: start - 1), cls, big: big) {
            start -= 1
        }
        end = cursor + 1
        while end < buffer.count, matches(buffer.charClass(at: end), cls, big: big) {
            end += 1
        }
        if inner {
            return (start..<end, .characterwise)
        }
        // trailing whitespace (not crossing newline), else leading
        var trail = end
        while trail < buffer.count, isBlank(buffer, trail), buffer.character(at: trail) != "\n" {
            trail += 1
        }
        if trail > end {
            return (start..<trail, .characterwise)
        }
        var lead = start
        while lead > 0, isBlank(buffer, lead - 1), buffer.character(at: lead - 1) != "\n" {
            lead -= 1
        }
        return (lead..<end, .characterwise)
    }

    private static func matches(_ a: CharClass, _ b: CharClass, big: Bool) -> Bool {
        if big { return a.isWORD && b.isWORD }
        return a == b && a.isWord
    }

    private static func sentence(_ buffer: TextBuffer, inner: Bool) -> (Range<Int>, RangeStyle)? {
        if buffer.isEmpty { return nil }
        var s = buffer.cursor
        // Walk back to previous sentence end, then skip whitespace for start.
        var i = min(buffer.cursor, max(0, buffer.count - 1))
        while i > 0, !MotionResolver.isSentenceEnd(buffer, at: i) {
            i -= 1
        }
        if MotionResolver.isSentenceEnd(buffer, at: i) {
            s = i + 1
            while s < buffer.count {
                let ch = buffer.character(at: s)
                if ch == " " || ch == "\t" || ch == "\n" { s += 1; continue }
                break
            }
        } else {
            s = 0
        }
        var e = buffer.cursor
        while e < buffer.count, !MotionResolver.isSentenceEnd(buffer, at: e) {
            e += 1
        }
        if e < buffer.count, MotionResolver.isSentenceEnd(buffer, at: e) {
            e += 1
            while e < buffer.count {
                let ch = buffer.character(at: e)
                if ch == ")" || ch == "]" || ch == "\"" || ch == "'" { e += 1; continue }
                break
            }
            if !inner {
                while e < buffer.count {
                    let ch = buffer.character(at: e)
                    if ch == " " || ch == "\t" || ch == "\n" { e += 1; continue }
                    break
                }
            }
        }
        if s >= e { return nil }
        return (s..<e, .characterwise)
    }

    private static func paragraph(_ buffer: TextBuffer, inner: Bool) -> (Range<Int>, RangeStyle)? {
        if buffer.isEmpty { return nil }
        var line = buffer.lineIndex(containing: buffer.cursor)
        while line > 0, !buffer.isBlankLine(line - 1) {
            line -= 1
        }
        if buffer.isBlankLine(line) && inner {
            // inner paragraph on a blank line is the blank run
            let start = line
            var end = line
            while end + 1 < buffer.lineCount, buffer.isBlankLine(end + 1) {
                end += 1
            }
            return (buffer.linesRange(from: start, through: end), .linewise)
        }
        if buffer.isBlankLine(line) {
            line += 1
        }
        var startLine = line
        while startLine > 0, !buffer.isBlankLine(startLine - 1) {
            startLine -= 1
        }
        var endLine = startLine
        while endLine + 1 < buffer.lineCount, !buffer.isBlankLine(endLine + 1) {
            endLine += 1
        }
        if !inner {
            if startLine > 0 {
                startLine -= 1
            } else if endLine + 1 < buffer.lineCount {
                endLine += 1
            }
        }
        return (buffer.linesRange(from: startLine, through: endLine), .linewise)
    }

    private static func quotes(
        _ buffer: TextBuffer,
        quote: Character,
        inner: Bool
    ) -> (Range<Int>, RangeStyle)? {
        let line = buffer.lineIndex(containing: buffer.cursor)
        let content = buffer.lineContentRange(at: line)
        guard !content.isEmpty else { return nil }
        var opens: [Int] = []
        var i = content.lowerBound
        while i < content.upperBound {
            if buffer.character(at: i) == quote {
                opens.append(i)
            }
            i += 1
        }
        guard opens.count >= 2 else { return nil }
        let cursor = buffer.cursor
        var pair: (Int, Int)?
        var idx = 0
        while idx + 1 < opens.count {
            let a = opens[idx]
            let b = opens[idx + 1]
            if cursor >= a && cursor <= b {
                pair = (a, b)
                break
            }
            idx += 2
        }
        if pair == nil, let last = opens.last, cursor > last, opens.count >= 2 {
            pair = (opens[opens.count - 2], last)
        }
        guard let (a, b) = pair, b > a else { return nil }
        if inner {
            return ((a + 1)..<b, .characterwise)
        }
        return (a..<(b + 1), .characterwise)
    }

    private static func brackets(
        _ buffer: TextBuffer,
        open: Character,
        close: Character,
        inner: Bool
    ) -> (Range<Int>, RangeStyle)? {
        if buffer.isEmpty { return nil }
        let cursor = min(buffer.cursor, max(0, buffer.count - 1))
        var depth = 0
        var start: Int?
        var i = cursor
        // If on the closing bracket, start just inside.
        if buffer.character(at: i) == close, i > 0 {
            i -= 1
        }
        while i >= 0 {
            let ch = buffer.character(at: i)
            if ch == close { depth += 1 }
            else if ch == open {
                if depth == 0 {
                    start = i
                    break
                }
                depth -= 1
            }
            if i == 0 { break }
            i -= 1
        }
        guard let openAt = start else { return nil }
        depth = 0
        var j = openAt + 1
        var end: Int?
        while j < buffer.count {
            let ch = buffer.character(at: j)
            if ch == open { depth += 1 }
            else if ch == close {
                if depth == 0 {
                    end = j
                    break
                }
                depth -= 1
            }
            j += 1
        }
        guard let closeAt = end else { return nil }
        if inner {
            return ((openAt + 1)..<closeAt, .characterwise)
        }
        return (openAt..<(closeAt + 1), .characterwise)
    }
}
