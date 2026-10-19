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
        let cursor = buffer.clampedCursor(min(buffer.cursor, buffer.graphemeStart(before: buffer.count)), normalMode: false)
        func next(_ off: Int) -> Int { buffer.nextGrapheme(after: off) }
        func previous(_ off: Int) -> Int { buffer.graphemeStart(before: off) }
        func isNewline(_ off: Int) -> Bool { buffer.charClass(at: off) == .newline }
        let onBlank = isBlank(buffer, cursor)

        var start = cursor
        var end = cursor

        if onBlank {
            while start > 0, isBlank(buffer, previous(start)), !isNewline(previous(start)) {
                start = previous(start)
            }
            while end < buffer.count, isBlank(buffer, end), !isNewline(end) {
                end = next(end)
            }
            if inner {
                return (start..<end, .characterwise)
            }
            // aw on whitespace includes the following word
            var w = end
            while w < buffer.count, isBlank(buffer, w) { w = next(w) }
            if w < buffer.count {
                let cls = buffer.charClass(at: w)
                w = next(w)
                while w < buffer.count, matches(buffer.charClass(at: w), cls, big: big) {
                    w = next(w)
                }
                end = w
            }
            return (start..<end, .characterwise)
        }

        let cls = buffer.charClass(at: cursor)
        while start > 0, matches(buffer.charClass(at: previous(start)), cls, big: big) {
            start = previous(start)
        }
        end = next(cursor)
        while end < buffer.count, matches(buffer.charClass(at: end), cls, big: big) {
            end = next(end)
        }
        if inner {
            return (start..<end, .characterwise)
        }
        // trailing whitespace (not crossing newline), else leading
        var trail = end
        while trail < buffer.count, isBlank(buffer, trail), !isNewline(trail) {
            trail = next(trail)
        }
        if trail > end {
            return (start..<trail, .characterwise)
        }
        var lead = start
        while lead > 0, isBlank(buffer, previous(lead)), !isNewline(previous(lead)) {
            lead = previous(lead)
        }
        return (lead..<end, .characterwise)
    }

    private static func matches(_ a: CharClass, _ b: CharClass, big: Bool) -> Bool {
        if big { return a.isWORD && b.isWORD }
        return a == b && a.isWord
    }

    private static func sentence(_ buffer: TextBuffer, inner: Bool) -> (Range<Int>, RangeStyle)? {
        if buffer.isEmpty { return nil }
        func next(_ off: Int) -> Int { buffer.nextGrapheme(after: off) }
        var s = buffer.cursor
        // Walk back to previous sentence end, then skip whitespace for start.
        var i = buffer.clampedCursor(min(buffer.cursor, buffer.graphemeStart(before: buffer.count)), normalMode: false)
        while i > 0, !MotionResolver.isSentenceEnd(buffer, at: i) {
            i = buffer.graphemeStart(before: i)
        }
        if MotionResolver.isSentenceEnd(buffer, at: i) {
            s = next(i)
            while s < buffer.count {
                let ch = buffer.character(at: s)
                if ch == " " || ch == "\t" || ch == "\n" { s = next(s); continue }
                break
            }
        } else {
            s = 0
        }
        var e = buffer.cursor
        while e < buffer.count, !MotionResolver.isSentenceEnd(buffer, at: e) {
            e = next(e)
        }
        if e < buffer.count, MotionResolver.isSentenceEnd(buffer, at: e) {
            e = next(e)
            while e < buffer.count {
                let ch = buffer.character(at: e)
                if ch == ")" || ch == "]" || ch == "\"" || ch == "'" { e = next(e); continue }
                break
            }
            if !inner {
                while e < buffer.count {
                    let ch = buffer.character(at: e)
                    if ch == " " || ch == "\t" || ch == "\n" { e = next(e); continue }
                    break
                }
            }
        }
        if s >= e { return nil }
        return (s..<e, .characterwise)
    }

    /// `ip` is the run of lines sharing the cursor line's blankness. `ap` adds the
    /// run after it, or for a paragraph at the end of the buffer the blanks before it.
    private static func paragraph(_ buffer: TextBuffer, inner: Bool) -> (Range<Int>, RangeStyle)? {
        if buffer.isEmpty { return nil }
        let last = buffer.lastLine
        let line = min(buffer.lineIndex(containing: buffer.cursor), last)
        let blank = buffer.isBlankLine(line)
        var startLine = line
        while startLine > 0, buffer.isBlankLine(startLine - 1) == blank { startLine -= 1 }
        var endLine = line
        while endLine < last, buffer.isBlankLine(endLine + 1) == blank { endLine += 1 }
        if !inner {
            if endLine < last {
                endLine += 1
                while endLine < last, buffer.isBlankLine(endLine + 1) != blank { endLine += 1 }
            } else if !blank, startLine > 0 {
                startLine -= 1
                while startLine > 0, buffer.isBlankLine(startLine - 1) { startLine -= 1 }
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
        let opens = buffer.graphemes(in: content).filter { $0.character == quote }.map(\.span.lowerBound)
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
        let afterOpen = buffer.nextGrapheme(after: a)
        let afterClose = buffer.nextGrapheme(after: b)
        if inner {
            return (afterOpen..<b, .characterwise)
        }
        return (a..<afterClose, .characterwise)
    }

    private static func brackets(
        _ buffer: TextBuffer,
        open: Character,
        close: Character,
        inner: Bool
    ) -> (Range<Int>, RangeStyle)? {
        if buffer.isEmpty { return nil }
        let cursor = buffer.clampedCursor(min(buffer.cursor, buffer.graphemeStart(before: buffer.count)), normalMode: false)
        var depth = 0
        var start: Int?
        var i = cursor
        // If on the closing bracket, start just inside.
        if buffer.character(at: i) == close, i > 0 {
            i = buffer.graphemeStart(before: i)
        }
        while true {
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
            i = buffer.graphemeStart(before: i)
        }
        guard let openAt = start else { return nil }
        depth = 0
        var j = buffer.nextGrapheme(after: openAt)
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
            j = buffer.nextGrapheme(after: j)
        }
        guard let closeAt = end else { return nil }
        if inner {
            return (buffer.nextGrapheme(after: openAt)..<closeAt, .characterwise)
        }
        return (openAt..<buffer.nextGrapheme(after: closeAt), .characterwise)
    }
}
