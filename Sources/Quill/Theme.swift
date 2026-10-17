import AppKit

struct QuillTheme {
    var bodyFont: NSFont
    var monoFont: NSFont
    var headingFonts: [NSFont]
    var textColor: NSColor
    var backgroundColor: NSColor
    var syntaxColor: NSColor
    var codeColor: NSColor
    var linkColor: NSColor
    var dimColor: NSColor
    var columnWidth: CGFloat
    var lineHeight: CGFloat

    static func current(columnCharacters: Int = 76) -> QuillTheme {
        let appearance = NSApp.effectiveAppearance
        let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let body = NSFont(name: "New York", size: 20)
            ?? NSFont(name: "Iowan Old Style", size: 20)
            ?? NSFont(name: "Palatino", size: 20)
            ?? NSFont.systemFont(ofSize: 20)
        let mono = NSFont.monospacedSystemFont(ofSize: 15, weight: .regular)
        func heading(_ size: CGFloat, _ weight: NSFont.Weight) -> NSFont {
            if let base = NSFont(name: body.fontName, size: size) {
                return NSFontManager.shared.convert(base, toHaveTrait: .boldFontMask)
            }
            return NSFont.systemFont(ofSize: size, weight: weight)
        }
        let avg = body.maximumAdvancement.width * 0.52
        return QuillTheme(
            bodyFont: body,
            monoFont: mono,
            headingFonts: [
                heading(32, .bold),
                heading(26, .bold),
                heading(22, .semibold),
                heading(20, .semibold),
                heading(20, .medium),
                heading(20, .medium),
            ],
            textColor: dark ? NSColor(calibratedWhite: 0.92, alpha: 1) : NSColor(calibratedWhite: 0.14, alpha: 1),
            backgroundColor: dark
                ? NSColor(calibratedRed: 0.11, green: 0.105, blue: 0.10, alpha: 1)
                : NSColor(calibratedRed: 0.985, green: 0.975, blue: 0.96, alpha: 1),
            syntaxColor: dark ? NSColor(calibratedWhite: 0.45, alpha: 1) : NSColor(calibratedWhite: 0.62, alpha: 1),
            codeColor: dark ? NSColor(calibratedRed: 0.75, green: 0.85, blue: 0.7, alpha: 1)
                : NSColor(calibratedRed: 0.25, green: 0.4, blue: 0.3, alpha: 1),
            linkColor: dark ? NSColor(calibratedRed: 0.65, green: 0.78, blue: 0.95, alpha: 1)
                : NSColor(calibratedRed: 0.25, green: 0.4, blue: 0.65, alpha: 1),
            dimColor: dark ? NSColor(calibratedWhite: 0.4, alpha: 1) : NSColor(calibratedWhite: 0.55, alpha: 1),
            columnWidth: max(480, CGFloat(columnCharacters) * avg),
            lineHeight: 1.65
        )
    }

    var bodyAttributes: [NSAttributedString.Key: Any] {
        let para = NSMutableParagraphStyle()
        para.lineHeightMultiple = lineHeight
        para.paragraphSpacing = 2
        return [
            .font: bodyFont,
            .foregroundColor: textColor,
            .paragraphStyle: para,
        ]
    }
}

enum MarkdownStyler {
    static func restyle(_ storage: NSTextStorage, theme: QuillTheme, diagnostics: [(NSRange, Int)] = []) {
        let text = storage.string
        let full = NSRange(location: 0, length: (text as NSString).length)
        storage.beginEditing()
        storage.setAttributes(theme.bodyAttributes, range: full)

        var inFence = false
        var inFrontmatter = text.hasPrefix("---")
        var frontmatterClosed = false
        let ns = text as NSString
        var lineStart = 0
        while lineStart <= ns.length {
            let lineEnd = ns.rangeOfCharacter(from: .newlines, options: [], range: NSRange(location: lineStart, length: ns.length - lineStart)).location
            let end = lineEnd == NSNotFound ? ns.length : lineEnd
            let lineRange = NSRange(location: lineStart, length: end - lineStart)
            let line = ns.substring(with: lineRange)

            if inFrontmatter, !frontmatterClosed {
                storage.addAttribute(.foregroundColor, value: theme.dimColor, range: lineRange)
                storage.addAttribute(.font, value: theme.monoFont, range: lineRange)
                if lineStart > 0, line == "---" {
                    inFrontmatter = false
                    frontmatterClosed = true
                }
                lineStart = end + (lineEnd == NSNotFound ? 1 : 1)
                if lineEnd == NSNotFound { break }
                continue
            }

            if line.hasPrefix("```") {
                inFence.toggle()
                storage.addAttribute(.foregroundColor, value: theme.syntaxColor, range: lineRange)
                storage.addAttribute(.font, value: theme.monoFont, range: lineRange)
                lineStart = end + 1
                if lineEnd == NSNotFound { break }
                continue
            }

            if inFence {
                storage.addAttribute(.font, value: theme.monoFont, range: lineRange)
                storage.addAttribute(.foregroundColor, value: theme.codeColor, range: lineRange)
                lineStart = end + 1
                if lineEnd == NSNotFound { break }
                continue
            }

            if let heading = headingMatch(line) {
                let font = theme.headingFonts[min(heading.level - 1, theme.headingFonts.count - 1)]
                storage.addAttribute(.font, value: font, range: lineRange)
                let marks = NSRange(location: lineRange.location, length: heading.level)
                storage.addAttribute(.foregroundColor, value: theme.syntaxColor, range: marks)
            }

            applyInline(ns, lineRange: lineRange, theme: theme, storage: storage)

            if lineEnd == NSNotFound { break }
            lineStart = end + 1
        }

        for (range, severity) in diagnostics {
            guard NSMaxRange(range) <= storage.length else { continue }
            let color: NSColor = severity <= 1 ? .systemRed : .systemOrange
            storage.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: range)
            storage.addAttribute(.underlineColor, value: color, range: range)
        }
        storage.endEditing()
    }

    private static func headingMatch(_ line: String) -> (level: Int, title: String)? {
        var i = 0
        let chars = Array(line)
        while i < chars.count, chars[i] == "#" { i += 1 }
        guard i >= 1, i <= 6, i < chars.count, chars[i] == " " else { return nil }
        return (i, String(chars[(i + 1)...]))
    }

    private static func applyInline(_ ns: NSString, lineRange: NSRange, theme: QuillTheme, storage: NSTextStorage) {
        let patterns: [(String, (NSTextCheckingResult, NSString) -> Void)] = []
        _ = patterns
        highlight(ns, lineRange: lineRange, pattern: #"`([^`]+)`"#, storage: storage) { result in
            storage.addAttribute(.font, value: theme.monoFont, range: result.range)
            storage.addAttribute(.foregroundColor, value: theme.codeColor, range: result.range)
            if result.numberOfRanges > 1 {
                dimMarks(result, inner: 1, storage: storage, color: theme.syntaxColor)
            }
        }
        highlight(ns, lineRange: lineRange, pattern: #"\*\*([^*]+)\*\*"#, storage: storage) { result in
            storage.addAttribute(.font, value: NSFontManager.shared.convert(theme.bodyFont, toHaveTrait: .boldFontMask), range: result.range(at: 1))
            dimMarks(result, inner: 1, storage: storage, color: theme.syntaxColor)
        }
        highlight(ns, lineRange: lineRange, pattern: #"(?<!\*)\*([^*]+)\*(?!\*)"#, storage: storage) { result in
            storage.addAttribute(.obliqueness, value: 0.15, range: result.range(at: 1))
            dimMarks(result, inner: 1, storage: storage, color: theme.syntaxColor)
        }
        highlight(ns, lineRange: lineRange, pattern: #"\[\[[^\]]+\]\]"#, storage: storage) { result in
            storage.addAttribute(.foregroundColor, value: theme.linkColor, range: result.range)
        }
        highlight(ns, lineRange: lineRange, pattern: #"^\s*([-*+]|\d+\.)\s"#, storage: storage) { result in
            storage.addAttribute(.foregroundColor, value: theme.syntaxColor, range: result.range)
        }
        highlight(ns, lineRange: lineRange, pattern: #"\[[ xX]\]"#, storage: storage) { result in
            storage.addAttribute(.font, value: theme.monoFont, range: result.range)
            storage.addAttribute(.foregroundColor, value: theme.syntaxColor, range: result.range)
        }
    }

    private static func dimMarks(_ result: NSTextCheckingResult, inner: Int, storage: NSTextStorage, color: NSColor) {
        let full = result.range
        let innerRange = result.range(at: inner)
        let left = NSRange(location: full.location, length: innerRange.location - full.location)
        let right = NSRange(location: NSMaxRange(innerRange), length: NSMaxRange(full) - NSMaxRange(innerRange))
        storage.addAttribute(.foregroundColor, value: color, range: left)
        storage.addAttribute(.foregroundColor, value: color, range: right)
    }

    private static func highlight(
        _ ns: NSString,
        lineRange: NSRange,
        pattern: String,
        storage: NSTextStorage,
        apply: (NSTextCheckingResult) -> Void
    ) {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return }
        regex.enumerateMatches(in: ns as String, options: [], range: lineRange) { match, _, _ in
            if let match { apply(match) }
        }
    }
}

enum Wikilink {
    static func at(cursor: Int, in text: String) -> String? {
        let chars = Array(text)
        guard !chars.isEmpty else { return nil }
        var i = min(cursor, chars.count - 1)
        var start: Int?
        while i >= 1 {
            if chars[i] == "]" && chars[i - 1] == "]" { return nil }
            if chars[i] == "[" && chars[i - 1] == "[" {
                start = i + 1
                break
            }
            i -= 1
        }
        guard let start else { return nil }
        var end = start
        while end < chars.count, chars[end] != "]" {
            end += 1
        }
        return String(chars[start..<end])
    }

    static func prefixBeforeCursor(_ text: String, cursor: Int) -> String? {
        let idx = min(cursor, text.count)
        let prefix = String(text.prefix(idx))
        guard let open = prefix.range(of: "[[", options: .backwards) else { return nil }
        let inner = prefix[open.upperBound...]
        if inner.contains("]") { return nil }
        return String(inner)
    }
}
