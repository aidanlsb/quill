import AppKit
import QuillMarkdown
import QuillVim

/// One type scale and measure. Config defaults and `QuillTheme.current` both read this.
enum QuillMetrics {
    static let defaultFontSize: Double = 16
    static let defaultColumn = 70
    /// Book-like leading for long-form prose. Tight enough to scan, open enough to rest.
    static let lineHeight: CGFloat = 1.58
    static let headingScale: [CGFloat] = [1.68, 1.38, 1.18, 1.08, 1.0, 1.0]
    /// H1 and H4–H6 use medium; H2/H3 stay semibold so the outline still scans.
    static let headingWeights: [NSFont.Weight] = [.medium, .semibold, .semibold, .medium, .medium, .medium]
    /// Tracking on heading text, in points. Negative pulls a display line together.
    static let headingKern: [CGFloat] = [-0.55, -0.28, -0.12, 0, 0.12, 0.28]
    /// Mono optically matched to SF Pro's x-height at body size.
    static let monoScale: CGFloat = 0.88
    /// Directory listings use a smaller monospaced face than the writing body.
    static let directoryFontScale: CGFloat = 0.75
    static let directoryLineHeight: CGFloat = 1.28
    static let statusBarHeight: CGFloat = 32
    static let modePillHeight: CGFloat = 20
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
    /// Extra first-line inset for list items, in ems of the body size.
    static let listIndentEm: CGFloat = 1.25
    /// Space after each list item, in ems of the body size.
    static let listItemSpacingEm: CGFloat = 0.28

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
    var listMarkerColor: NSColor
    var listMarkerFont: NSFont
    var accentColor: NSColor
    var codeBackground: NSColor
    var quoteBarColor: NSColor
    var quoteColor: NSColor
    var ruleColor: NSColor
    var taskDoneColor: NSColor

    var listIndent: CGFloat { bodyFont.pointSize * QuillMetrics.listIndentEm }
    var listItemSpacing: CGFloat { bodyFont.pointSize * QuillMetrics.listItemSpacingEm }

    @MainActor
    static func current(
        fontFamily: String = "",
        fontSize: Double = QuillMetrics.defaultFontSize,
        columnCharacters: Int = QuillMetrics.defaultColumn,
        scheme: ThemeChoice = .system,
        systemIsDark: Bool? = nil
    ) -> QuillTheme {
        let themeBegan = StartupProbe.begin("themeMs")
        defer { StartupProbe.end("themeMs", themeBegan) }
        let appearance = NSApp?.effectiveAppearance ?? NSAppearance.currentDrawing()
        let detected = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let dark = scheme.isDark(systemIsDark: systemIsDark ?? detected)
        let size = CGFloat(QuillMetrics.fontSize(fontSize))
        let fontsBegan = StartupProbe.begin("fontsMs")
        let body = QuillMetrics.bodyFont(family: fontFamily, size: size)
        let mono = QuillMetrics.monoFont(ofSize: size * QuillMetrics.monoScale)
        let headings = zip(QuillMetrics.headingScale, QuillMetrics.headingWeights).map { scale, weight in
            NSFont.systemFont(ofSize: size * scale, weight: weight)
        }
        let ink = QuillPalette.ink(dark: dark)
        let directorySize = QuillMetrics.directoryFontSize(body: size)
        let directoryFont = QuillMetrics.monoFont(ofSize: directorySize)
        let directoryHeaderFont = QuillMetrics.monoFont(ofSize: max(10, directorySize - 1))
        StartupProbe.end("fontsMs", fontsBegan)
        let glyphBegan = StartupProbe.begin("glyphMs")
        let sample = "abcdefghijklmnopqrstuvwxyz" as NSString
        let average = sample.size(withAttributes: [.font: body]).width / 26
        StartupProbe.end("glyphMs", glyphBegan)
        return QuillTheme(
            bodyFont: body,
            monoFont: mono,
            headingFonts: headings,
            textColor: ink.text,
            backgroundColor: ink.paper,
            syntaxColor: ink.syntax,
            codeColor: ink.code,
            linkColor: ink.link,
            dimColor: ink.dim,
            selectionColor: ink.accent.withAlphaComponent(dark ? 0.22 : 0.16),
            columnWidth: average * CGFloat(max(1, columnCharacters)),
            lineHeight: QuillMetrics.lineHeight,
            directoryFont: directoryFont,
            directoryHeaderFont: directoryHeaderFont,
            directoryBackgroundColor: ink.directoryPaper,
            directoryAccentColor: ink.directoryAccent,
            directoryHighlightColor: ink.accent.withAlphaComponent(dark ? 0.14 : 0.10),
            directoryCreatedColor: ink.created,
            directoryRenamedColor: ink.renamed,
            directoryDeletedColor: ink.deleted,
            tableBackground: ink.accent.withAlphaComponent(dark ? 0.08 : 0.05),
            tableHeaderRule: ink.accent.withAlphaComponent(dark ? 0.42 : 0.32),
            tableRowRule: ink.accent.withAlphaComponent(dark ? 0.16 : 0.12),
            listMarkerColor: ink.accent,
            listMarkerFont: Self.makeListMarkerFont(from: body),
            accentColor: ink.accent,
            codeBackground: ink.codeWash,
            quoteBarColor: ink.accent.withAlphaComponent(dark ? 0.72 : 0.55),
            quoteColor: ink.quote,
            ruleColor: ink.syntax.withAlphaComponent(0.85),
            taskDoneColor: ink.dim
        )
    }

    /// Medium of the body family so `-`, `*`, `+`, numbers, and `[ ]` read as
    /// structure. The system face uses `weight: .medium`; other families ask
    /// the font manager, then fall back to the system medium face.
    @MainActor
    private static func makeListMarkerFont(from body: NSFont) -> NSFont {
        let size = body.pointSize
        let systemMedium = NSFont.systemFont(ofSize: size, weight: .medium)
        let family = body.familyName ?? ""
        if family.isEmpty || family == NSFont.systemFont(ofSize: size).familyName {
            return systemMedium
        }
        if let match = NSFontManager.shared.font(withFamily: family, traits: [], weight: 7, size: size) {
            return match
        }
        return systemMedium
    }

    /// Semibold mono so the header reads as emphasis and columns stay aligned.
    @MainActor
    func tableHeaderFont() -> NSFont {
        let font = NSFont.monospacedSystemFont(ofSize: monoFont.pointSize, weight: .semibold)
        return font.isFixedPitch ? font : monoFont
    }

    /// A row wider than the column wraps like any other line. Clipping hid the
    /// end of the row and let the caret walk off the right edge of the column.
    @MainActor
    func tableParagraphStyle() -> NSParagraphStyle {
        let para = NSMutableParagraphStyle()
        para.lineHeightMultiple = lineHeight
        para.paragraphSpacing = 0
        para.lineBreakMode = .byWordWrapping
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

    /// Breathing room that makes the outline scan: more space above than below,
    /// scaled to the body so a custom font size still feels composed.
    func headingParagraphStyle(level: Int) -> NSParagraphStyle {
        let para = NSMutableParagraphStyle()
        para.lineHeightMultiple = lineHeight
        let size = bodyFont.pointSize
        switch min(max(1, level), 6) {
        case 1:
            para.paragraphSpacingBefore = size * 0.28
            para.paragraphSpacing = size * 0.42
        case 2:
            para.paragraphSpacingBefore = size * 0.82
            para.paragraphSpacing = size * 0.30
        case 3:
            para.paragraphSpacingBefore = size * 0.62
            para.paragraphSpacing = size * 0.22
        default:
            para.paragraphSpacingBefore = size * 0.42
            para.paragraphSpacing = size * 0.16
        }
        return para
    }

    func quoteParagraphStyle() -> NSParagraphStyle {
        let para = NSMutableParagraphStyle()
        para.lineHeightMultiple = lineHeight
        let inset = bodyFont.pointSize * 0.55
        para.firstLineHeadIndent = inset
        para.headIndent = inset
        para.paragraphSpacing = bodyFont.pointSize * 0.12
        return para
    }

    func headingKern(level: Int) -> CGFloat {
        let index = min(max(0, level - 1), QuillMetrics.headingKern.count - 1)
        return QuillMetrics.headingKern[index]
    }
}

/// Hidden title bar, no toolbar, window fill matches the editor.
enum WindowChrome {
    /// How many times the theme-wide apply ran. The editor calls it only when the theme or focus changes.
    @MainActor static var applyCount = 0

    @MainActor
    static func apply(theme: QuillTheme, background: NSColor? = nil) {
        applyCount += 1
        NSApplication.shared.windows.forEach { apply(theme, to: $0, background: background) }
    }

    @MainActor
    static func apply(_ theme: QuillTheme, to window: NSWindow, background: NSColor? = nil) {
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.titlebarSeparatorStyle = .none
        window.styleMask.insert(.fullSizeContentView)
        window.toolbar = nil
        window.backgroundColor = background ?? theme.backgroundColor
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
        paragraphUTF16: Range<Int>? = nil,
        focus: Bool = false,
        caret: Int = 0,
        focusParagraph: Range<Int>? = nil,
        diagnostics: [(NSRange, Int)] = [],
        tables: [TableBlock]? = nil,
        tableColumnWidth: CGFloat? = nil
    ) {
        let ns = storage.string as NSString
        let full = NSRange(location: 0, length: ns.length)
        let limit: NSRange
        if let paragraphUTF16 {
            limit = nsRange(paragraphUTF16, length: ns.length)
        } else if let dirtyUTF16 {
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
        let focusRange: Range<Int>
        if let focusParagraph {
            focusRange = focusParagraph
        } else if focus {
            focusRange = Paragraphs.range(in: storage.string, utf16: caret)
        } else {
            focusRange = 0..<ns.length
        }
        for span in Self.spans(overlapping: limit, in: spans) {
            let range = nsRange(span.range, length: ns.length)
            guard range.location != NSNotFound, range.length > 0, NSMaxRange(range) <= ns.length else { continue }
            let dimmed = focus && (range.location >= focusRange.upperBound || NSMaxRange(range) <= focusRange.lowerBound)
            apply(span.token, range: range, theme: theme, storage: storage, dimmed: dimmed)
        }
        let discovered = tables ?? Self.tables(in: storage.string, limit: limit)
        applyTables(
            storage,
            theme: theme,
            limit: limit,
            focus: focus,
            focusRange: focusRange,
            spans: spans,
            tables: discovered,
            columnWidth: tableColumnWidth
        )
        applyListHangingIndents(storage, theme: theme, spans: spans, limit: limit)
        for (range, severity) in diagnostics {
            let marked = NSIntersectionRange(range, limit)
            guard marked.length > 0, NSMaxRange(marked) <= storage.length else { continue }
            let color: NSColor = severity <= 1 ? .systemRed : .systemOrange
            storage.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: marked)
            storage.addAttribute(.underlineColor, value: color, range: marked)
        }
        storage.endEditing()
    }

    /// A caller that already parsed the visible tables passes them in.
    /// `nil` discovers tables from the string, and a partial limit only walks
    /// the lines that can belong to those tables.
    private static func tables(in text: String, limit: NSRange) -> [TableBlock] {
        guard limit.length > 0, !text.isEmpty else { return [] }
        let length = (text as NSString).length
        if limit.location == 0, limit.length == length {
            return MarkdownTables.blocks(in: text)
        }
        let end = min(length, NSMaxRange(limit))
        guard limit.location < end else { return [] }
        return MarkdownTables.blocks(in: text, overlapping: limit.location..<end)
    }

    /// Spans are ordered by start. Skip the prefix that ends before `limit`
    /// instead of testing every span in a 10k-line document on each keystroke.
    private static func spans(overlapping limit: NSRange, in spans: [TokenSpan]) -> ArraySlice<TokenSpan> {
        var low = 0
        var high = spans.count
        while low < high {
            let mid = (low + high) / 2
            if spans[mid].range.upperBound <= limit.location {
                low = mid + 1
            } else {
                high = mid
            }
        }
        var end = low
        let limitEnd = NSMaxRange(limit)
        while end < spans.count, spans[end].range.lowerBound < limitEnd {
            end += 1
        }
        return spans[low..<end]
    }

    private static func nsRange(_ range: Range<Int>, length: Int) -> NSRange {
        let loc = min(max(0, range.lowerBound), length)
        let end = min(max(loc, range.upperBound), length)
        return NSRange(location: loc, length: end - loc)
    }

    private static func apply(_ token: MarkdownToken, range: NSRange, theme: QuillTheme, storage: NSTextStorage, dimmed: Bool) {
        let style = MarkdownThemeMap.style(for: token)
        if style == .list {
            storage.addAttribute(.font, value: theme.listMarkerFont, range: range)
            storage.addAttribute(.foregroundColor, value: dimmed ? theme.dimColor : theme.listMarkerColor, range: range)
            if token == .taskBox {
                applyCheckedTask(range: range, theme: theme, storage: storage)
            }
            return
        }
        if dimmed {
            storage.addAttribute(.foregroundColor, value: theme.dimColor, range: range)
            return
        }
        if token == .frontmatter {
            storage.addAttribute(.font, value: theme.monoFont, range: range)
            storage.addAttribute(.foregroundColor, value: theme.syntaxColor, range: range)
            return
        }
        switch style {
        case .heading(let level):
            applyHeading(level: level, range: range, theme: theme, storage: storage)
        case .strong:
            storage.addAttribute(.font, value: NSFontManager.shared.convert(theme.bodyFont, toHaveTrait: .boldFontMask), range: range)
        case .emphasis:
            let italic = NSFontManager.shared.convert(theme.bodyFont, toHaveTrait: .italicFontMask)
            storage.addAttribute(.font, value: italic, range: range)
        case .strikethrough:
            storage.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: range)
            storage.addAttribute(.strikethroughColor, value: theme.textColor, range: range)
        case .code:
            storage.addAttribute(.font, value: theme.monoFont, range: range)
            storage.addAttribute(.foregroundColor, value: theme.codeColor, range: range)
            storage.addAttribute(.backgroundColor, value: theme.codeBackground, range: range)
        case .link:
            storage.addAttribute(.foregroundColor, value: theme.linkColor, range: range)
            if token == .link {
                storage.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: range)
                storage.addAttribute(.underlineColor, value: theme.linkColor.withAlphaComponent(0.42), range: range)
            }
        case .quote:
            applyQuote(range: range, theme: theme, storage: storage)
        case .rule:
            storage.addAttribute(.foregroundColor, value: theme.syntaxColor.withAlphaComponent(0.42), range: range)
            storage.addAttribute(.font, value: theme.monoFont, range: range)
        case .syntax, .dim:
            storage.addAttribute(.foregroundColor, value: theme.syntaxColor, range: range)
        case .list, .body:
            break
        }
    }

    /// Heading face on the title text only, so `#` markers stay body-sized and dim.
    /// Paragraph spacing is the outline's breathing room; the characters stay put.
    private static func applyHeading(level: Int, range: NSRange, theme: QuillTheme, storage: NSTextStorage) {
        let font = theme.headingFonts[min(max(0, level - 1), theme.headingFonts.count - 1)]
        let hashes = min(max(1, level), range.length)
        var textStart = range.location + hashes
        if textStart < NSMaxRange(range) {
            let ns = storage.string as NSString
            let unit = ns.character(at: textStart)
            if unit == 32 || unit == 9 { textStart += 1 }
        }
        let textLength = NSMaxRange(range) - textStart
        if textLength > 0 {
            let textRange = NSRange(location: textStart, length: textLength)
            storage.addAttribute(.font, value: font, range: textRange)
            let kern = theme.headingKern(level: level)
            if abs(kern) > 0.01 {
                storage.addAttribute(.kern, value: kern, range: textRange)
            }
        }
        storage.addAttribute(
            .paragraphStyle,
            value: theme.headingParagraphStyle(level: level),
            range: paragraphRange(range, length: storage.length, storage: storage)
        )
    }

    private static func applyQuote(range: NSRange, theme: QuillTheme, storage: NSTextStorage) {
        let italic = NSFontManager.shared.convert(theme.bodyFont, toHaveTrait: .italicFontMask)
        let ns = storage.string as NSString
        var start = range.location
        let end = NSMaxRange(range)
        while start < end, ns.character(at: start) == 32 { start += 1 }
        if start < end, ns.character(at: start) == 62 {
            start += 1
            if start < end, ns.character(at: start) == 32 { start += 1 }
        }
        if start < end {
            let text = NSRange(location: start, length: end - start)
            storage.addAttribute(.font, value: italic, range: text)
            storage.addAttribute(.foregroundColor, value: theme.quoteColor, range: text)
        }
        storage.addAttribute(
            .paragraphStyle,
            value: theme.quoteParagraphStyle(),
            range: paragraphRange(range, length: storage.length, storage: storage)
        )
    }

    /// Completed tasks recede: the item text after `[x]` is dimmed and struck.
    /// The checkbox characters stay, so `h`/`l` still land on them.
    private static func applyCheckedTask(range: NSRange, theme: QuillTheme, storage: NSTextStorage) {
        guard range.length >= 3, NSMaxRange(range) <= storage.length else { return }
        let ns = storage.string as NSString
        let mark = ns.substring(with: NSRange(location: range.location + 1, length: 1))
        guard mark == "x" || mark == "X" else { return }
        let line = ns.lineRange(for: NSRange(location: range.location, length: 0))
        var start = NSMaxRange(range)
        let lineEnd = NSMaxRange(line)
        if start < lineEnd {
            let unit = ns.character(at: start)
            if unit == 32 || unit == 9 { start += 1 }
        }
        var end = lineEnd
        while end > start {
            let unit = ns.character(at: end - 1)
            if unit == 10 || unit == 13 {
                end -= 1
                continue
            }
            break
        }
        guard start < end else { return }
        let rest = NSRange(location: start, length: end - start)
        storage.addAttribute(.foregroundColor, value: theme.taskDoneColor, range: rest)
        storage.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: rest)
        storage.addAttribute(.strikethroughColor, value: theme.taskDoneColor, range: rest)
    }

    private static func paragraphRange(_ range: NSRange, length: Int, storage: NSTextStorage) -> NSRange {
        guard NSMaxRange(range) < length else { return range }
        let next = (storage.string as NSString).substring(with: NSRange(location: NSMaxRange(range), length: 1))
        guard next == "\n" || next == "\r" else { return range }
        return NSRange(location: range.location, length: range.length + 1)
    }
}
