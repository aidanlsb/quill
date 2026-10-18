import AppKit
import QuillMarkdown
import QuillVim

/// One type scale and measure. Config defaults and `QuillTheme.current` both read this.
enum QuillMetrics {
    static let defaultFontSize: Double = 16
    static let defaultColumn = 70
    static let lineHeight: CGFloat = 1.5
    static let headingScale: [CGFloat] = [1.5, 1.3, 1.15, 1.05, 1.0, 1.0]
    static let monoScale: CGFloat = 0.85
    /// Directory listings use a smaller monospaced face than the writing body.
    static let directoryFontScale: CGFloat = 0.75
    static let directoryLineHeight: CGFloat = 1.28
    /// Left and right padding for the listing. The icon sits inside the left padding.
    static let directoryHorizontalInset: CGFloat = 44
    static let directoryHeaderHeight: CGFloat = 22
    static let directoryHeaderGap: CGFloat = 10
    static let directoryIconSize: CGFloat = 12
    static let directoryIconLeading: CGFloat = 16
    /// Minimum space between the text and the window edge. The column stays centered inside it.
    static let sideGutter: CGFloat = 128
    static let verticalInset: CGFloat = 128
    static let focusVerticalInset: CGFloat = 192

    /// Width of the text column and the inset that keeps it off both edges.
    static func columnSpan(width: CGFloat, column: CGFloat) -> (inset: CGFloat, column: CGFloat) {
        let available = max(160, width - sideGutter * 2)
        let span = min(max(column, 1), available)
        let inset = max(sideGutter, (width - span) / 2)
        return (inset, span)
    }

    /// Missing or out-of-range sizes fall back to the default. Accepted range is 10...32.
    static func fontSize(_ raw: Double?) -> Double {
        guard let raw, raw >= 10, raw <= 32 else { return defaultFontSize }
        return raw
    }

    /// Blank, missing, or not installed: the macOS system font. `family` is a family name, not a file.
    @MainActor
    static func bodyFont(family: String, size: CGFloat) -> NSFont {
        let name = family.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty,
           let match = NSFontManager.shared.font(withFamily: name, traits: [], weight: 5, size: size) {
            return match
        }
        return NSFont.systemFont(ofSize: size)
    }

    /// SF Mono when the family is installed, otherwise the system monospaced font (also SF Mono on macOS).
    @MainActor
    static func monoFont(ofSize size: CGFloat) -> NSFont {
        if let match = NSFontManager.shared.font(withFamily: "SF Mono", traits: [], weight: 5, size: size) {
            return match
        }
        return NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }

    static func directoryFontSize(body: CGFloat) -> CGFloat {
        body * directoryFontScale
    }

    static func directoryRowHeight(for font: NSFont) -> CGFloat {
        max(1, (font.ascender - font.descender) * directoryLineHeight)
    }
}

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
    var selectionColor: NSColor
    var columnWidth: CGFloat
    var lineHeight: CGFloat
    var directoryFont: NSFont
    var directoryHeaderFont: NSFont
    var directoryBackgroundColor: NSColor
    var directoryAccentColor: NSColor
    var directoryHighlightColor: NSColor
    var directoryCreatedColor: NSColor
    var directoryRenamedColor: NSColor
    var directoryDeletedColor: NSColor
    var tableBackground: NSColor
    var tableHeaderRule: NSColor
    var tableRowRule: NSColor

    @MainActor
    static func current(
        fontFamily: String = "",
        fontSize: Double = QuillMetrics.defaultFontSize,
        columnCharacters: Int = QuillMetrics.defaultColumn,
        scheme: ThemeChoice = .system
    ) -> QuillTheme {
        let appearance = NSApp?.effectiveAppearance ?? NSAppearance.currentDrawing()
        let systemDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let dark = scheme.isDark(systemIsDark: systemDark)
        let size = CGFloat(QuillMetrics.fontSize(fontSize))
        let body = QuillMetrics.bodyFont(family: fontFamily, size: size)
        let mono = QuillMetrics.monoFont(ofSize: size * QuillMetrics.monoScale)
        let headings = QuillMetrics.headingScale.map { scale in
            NSFont.systemFont(ofSize: size * scale, weight: .semibold)
        }
        let text = dark ? NSColor(calibratedWhite: 0.86, alpha: 1) : NSColor(calibratedWhite: 0.22, alpha: 1)
        let directorySize = QuillMetrics.directoryFontSize(body: size)
        let directoryFont = QuillMetrics.monoFont(ofSize: directorySize)
        let directoryHeaderFont = QuillMetrics.monoFont(ofSize: max(10, directorySize - 1))
        let sample = "abcdefghijklmnopqrstuvwxyz" as NSString
        let average = sample.size(withAttributes: [.font: body]).width / 26
        return QuillTheme(
            bodyFont: body,
            monoFont: mono,
            headingFonts: headings,
            textColor: text,
            backgroundColor: dark
                ? NSColor(calibratedWhite: 0.11, alpha: 1)
                : NSColor(calibratedWhite: 0.965, alpha: 1),
            syntaxColor: dark ? NSColor(calibratedWhite: 0.42, alpha: 1) : NSColor(calibratedWhite: 0.58, alpha: 1),
            codeColor: dark ? NSColor(calibratedWhite: 0.72, alpha: 1) : NSColor(calibratedWhite: 0.32, alpha: 1),
            linkColor: dark
                ? NSColor(calibratedRed: 0.62, green: 0.68, blue: 0.74, alpha: 1)
                : NSColor(calibratedRed: 0.35, green: 0.42, blue: 0.48, alpha: 1),
            dimColor: dark ? NSColor(calibratedWhite: 0.40, alpha: 1) : NSColor(calibratedWhite: 0.62, alpha: 1),
            selectionColor: text.withAlphaComponent(0.10),
            columnWidth: average * CGFloat(max(1, columnCharacters)),
            lineHeight: QuillMetrics.lineHeight,
            directoryFont: directoryFont,
            directoryHeaderFont: directoryHeaderFont,
            directoryBackgroundColor: dark
                ? NSColor(calibratedRed: 0.128, green: 0.136, blue: 0.152, alpha: 1)
                : NSColor(calibratedRed: 0.918, green: 0.929, blue: 0.945, alpha: 1),
            directoryAccentColor: dark
                ? NSColor(calibratedRed: 0.66, green: 0.76, blue: 0.84, alpha: 1)
                : NSColor(calibratedRed: 0.27, green: 0.40, blue: 0.55, alpha: 1),
            directoryHighlightColor: dark
                ? NSColor(calibratedWhite: 1, alpha: 0.06)
                : NSColor(calibratedWhite: 0, alpha: 0.045),
            directoryCreatedColor: dark
                ? NSColor(calibratedRed: 0.55, green: 0.72, blue: 0.60, alpha: 1)
                : NSColor(calibratedRed: 0.33, green: 0.48, blue: 0.38, alpha: 1),
            directoryRenamedColor: dark
                ? NSColor(calibratedRed: 0.84, green: 0.70, blue: 0.45, alpha: 1)
                : NSColor(calibratedRed: 0.62, green: 0.46, blue: 0.24, alpha: 1),
            directoryDeletedColor: dark
                ? NSColor(calibratedRed: 0.78, green: 0.52, blue: 0.48, alpha: 1)
                : NSColor(calibratedRed: 0.55, green: 0.32, blue: 0.30, alpha: 1),
            tableBackground: dark
                ? NSColor(calibratedWhite: 1, alpha: 0.045)
                : NSColor(calibratedWhite: 0, alpha: 0.04),
            tableHeaderRule: dark
                ? NSColor(calibratedWhite: 1, alpha: 0.32)
                : NSColor(calibratedWhite: 0, alpha: 0.28),
            tableRowRule: dark
                ? NSColor(calibratedWhite: 1, alpha: 0.12)
                : NSColor(calibratedWhite: 0, alpha: 0.10)
        )
    }

    /// Semibold mono so the header reads as emphasis and columns stay aligned.
    @MainActor
    func tableHeaderFont() -> NSFont {
        let font = NSFont.monospacedSystemFont(ofSize: monoFont.pointSize, weight: .semibold)
        return font.isFixedPitch ? font : monoFont
    }

    /// Table lines do not wrap. A wide row clips at the column instead of breaking the grid.
    @MainActor
    func tableParagraphStyle() -> NSParagraphStyle {
        let para = NSMutableParagraphStyle()
        para.lineHeightMultiple = lineHeight
        para.paragraphSpacing = 0
        para.lineBreakMode = .byClipping
        para.allowsDefaultTighteningForTruncation = false
        return para
    }

    var bodyAttributes: [NSAttributedString.Key: Any] {
        let para = NSMutableParagraphStyle()
        para.lineHeightMultiple = lineHeight
        para.paragraphSpacing = 0
        return [
            .font: bodyFont,
            .foregroundColor: textColor,
            .paragraphStyle: para,
        ]
    }
}

/// Hidden title bar, no toolbar, window fill matches the editor.
enum WindowChrome {
    @MainActor
    static func apply(theme: QuillTheme) {
        NSApplication.shared.windows.forEach { apply(theme, to: $0) }
    }

    @MainActor
    static func apply(_ theme: QuillTheme, to window: NSWindow) {
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.titlebarSeparatorStyle = .none
        window.styleMask.insert(.fullSizeContentView)
        window.toolbar = nil
        window.backgroundColor = theme.backgroundColor
        window.isMovableByWindowBackground = true
    }
}

@MainActor
enum MarkdownStyler {
    static func restyle(
        _ storage: NSTextStorage,
        theme: QuillTheme,
        spans: [TokenSpan] = [],
        dirtyUTF16: Int? = nil,
        focus: Bool = false,
        caret: Int = 0,
        diagnostics: [(NSRange, Int)] = []
    ) {
        let ns = storage.string as NSString
        let full = NSRange(location: 0, length: ns.length)
        let limit: NSRange
        if let dirtyUTF16 {
            let paragraph = Paragraphs.range(in: storage.string, utf16: dirtyUTF16)
            let loc = min(paragraph.lowerBound, ns.length)
            let end = min(paragraph.upperBound, ns.length)
            limit = NSRange(location: loc, length: max(0, end - loc))
        } else {
            limit = full
        }
        storage.beginEditing()
        if limit.length > 0 {
            storage.setAttributes(theme.bodyAttributes, range: limit)
        }
        let focusRange = focus ? Paragraphs.range(in: storage.string, utf16: caret) : 0..<ns.length
        for span in spans where NSIntersectionRange(nsRange(span.range, length: ns.length), limit).length > 0 {
            let range = nsRange(span.range, length: ns.length)
            guard range.location != NSNotFound, range.length > 0, NSMaxRange(range) <= ns.length else { continue }
            let dimmed = focus && (range.location >= focusRange.upperBound || NSMaxRange(range) <= focusRange.lowerBound)
            apply(span.token, range: range, theme: theme, storage: storage, dimmed: dimmed)
        }
        applyTables(storage, theme: theme, limit: limit, focus: focus, focusRange: focusRange, spans: spans)
        for (range, severity) in diagnostics {
            guard NSMaxRange(range) <= storage.length else { continue }
            let color: NSColor = severity <= 1 ? .systemRed : .systemOrange
            storage.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: range)
            storage.addAttribute(.underlineColor, value: color, range: range)
        }
        storage.endEditing()
    }

    private static func nsRange(_ range: Range<Int>, length: Int) -> NSRange {
        let loc = min(max(0, range.lowerBound), length)
        let end = min(max(loc, range.upperBound), length)
        return NSRange(location: loc, length: end - loc)
    }

    private static func apply(_ token: MarkdownToken, range: NSRange, theme: QuillTheme, storage: NSTextStorage, dimmed: Bool) {
        if dimmed {
            storage.addAttribute(.foregroundColor, value: theme.dimColor, range: range)
            return
        }
        if token == .frontmatter {
            storage.addAttribute(.font, value: theme.monoFont, range: range)
            storage.addAttribute(.foregroundColor, value: theme.syntaxColor, range: range)
            return
        }
        switch MarkdownThemeMap.style(for: token) {
        case .heading(let level):
            let font = theme.headingFonts[min(max(0, level - 1), theme.headingFonts.count - 1)]
            storage.addAttribute(.font, value: font, range: range)
        case .strong:
            storage.addAttribute(.font, value: NSFontManager.shared.convert(theme.bodyFont, toHaveTrait: .boldFontMask), range: range)
        case .emphasis:
            let italic = NSFontManager.shared.convert(theme.bodyFont, toHaveTrait: .italicFontMask)
            storage.addAttribute(.font, value: italic, range: range)
        case .code:
            storage.addAttribute(.font, value: theme.monoFont, range: range)
            storage.addAttribute(.foregroundColor, value: theme.codeColor, range: range)
        case .link:
            storage.addAttribute(.foregroundColor, value: theme.linkColor, range: range)
        case .syntax, .dim:
            storage.addAttribute(.foregroundColor, value: theme.syntaxColor, range: range)
        case .body:
            break
        }
    }

    static func restyleLegacy(_ storage: NSTextStorage, theme: QuillTheme, diagnostics: [(NSRange, Int)] = []) {
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
