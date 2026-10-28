import AppKit
import QuillMarkdown

extension MarkdownStyler {
    static func applyTables(
        _ storage: NSTextStorage,
        theme: QuillTheme,
        limit: NSRange,
        focus: Bool,
        focusRange: Range<Int>,
        spans: [TokenSpan],
        tables: [TableBlock],
        columnWidth: CGFloat?
    ) {
        let length = storage.length
        guard length > 0, !tables.isEmpty else { return }
        let advance = monoAdvance(theme.monoFont)
        let headerFont = theme.tableHeaderFont()
        let fitColumns = columnWidth.map { Self.fitColumns(width: $0, advance: advance) }
        for block in tables {
            let aligned = fitColumns.map { block.alignsWithin(columns: $0) } ?? true
            for row in block.rows {
                let content = nsRange(row.range, length: length)
                guard content.length > 0, NSIntersectionRange(content, limit).length > 0 else { continue }
                let dimmed = focus && (content.location >= focusRange.upperBound || NSMaxRange(content) <= focusRange.lowerBound)
                paint(
                    row,
                    content: content,
                    theme: theme,
                    storage: storage,
                    dimmed: dimmed,
                    aligned: aligned,
                    advance: advance,
                    headerFont: headerFont,
                    spans: spans,
                    length: length
                )
            }
        }
    }

    private static func paint(
        _ row: TableRow,
        content: NSRange,
        theme: QuillTheme,
        storage: NSTextStorage,
        dimmed: Bool,
        aligned: Bool,
        advance: CGFloat,
        headerFont: NSFont,
        spans: [TokenSpan],
        length: Int
    ) {
        storage.addAttribute(.font, value: theme.monoFont, range: content)
        storage.addAttribute(.foregroundColor, value: theme.textColor, range: content)
        storage.addAttribute(.backgroundColor, value: theme.tableBackground, range: content)
        let para = theme.tableParagraphStyle().mutableCopy() as? NSMutableParagraphStyle ?? NSMutableParagraphStyle()
        if aligned, let first = row.cells.first, first.precedingPipe == nil, first.leadingPad > 0 {
            let indent = advance * CGFloat(first.leadingPad)
            para.headIndent = indent
            para.firstLineHeadIndent = indent
        }
        storage.addAttribute(
            .paragraphStyle,
            value: para,
            range: paragraphRange(content, length: length, storage: storage)
        )
        if row.role == .header || row.role == .body {
            let rule = row.role == .header ? theme.tableHeaderRule : theme.tableRowRule
            storage.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: content)
            storage.addAttribute(.underlineColor, value: rule, range: content)
        }
        for pipe in row.pipes {
            let range = nsRange(pipe, length: length)
            guard range.length > 0 else { continue }
            storage.addAttribute(.foregroundColor, value: theme.syntaxColor, range: range)
        }
        if row.role == .separator {
            for cell in row.cells where !cell.text.isEmpty {
                let range = nsRange(cell.text, length: length)
                guard range.length > 0 else { continue }
                storage.addAttribute(.foregroundColor, value: theme.syntaxColor, range: range)
            }
        }
        if row.role == .header {
            for cell in row.cells where !cell.text.isEmpty {
                let range = nsRange(cell.text, length: length)
                guard range.length > 0 else { continue }
                storage.addAttribute(.font, value: headerFont, range: range)
            }
        }
        for cell in row.cells where aligned {
            if cell.leadingPad > 0, let pipe = cell.precedingPipe {
                let range = nsRange(pipe..<(pipe + 1), length: length)
                guard range.length == 1 else { continue }
                storage.addAttribute(.kern, value: advance * CGFloat(cell.leadingPad), range: range)
            }
            if cell.trailingPad > 0, cell.raw.upperBound > cell.raw.lowerBound {
                let at = cell.raw.upperBound - 1
                let range = nsRange(at..<(at + 1), length: length)
                guard range.length == 1 else { continue }
                storage.addAttribute(.kern, value: advance * CGFloat(cell.trailingPad), range: range)
            }
        }
        if dimmed {
            storage.addAttribute(.foregroundColor, value: theme.dimColor, range: content)
            return
        }
        for span in spans {
            let hit = NSIntersectionRange(nsRange(span.range, length: length), content)
            guard hit.length > 0 else { continue }
            switch span.token {
            case .syntaxMarker:
                storage.addAttribute(.foregroundColor, value: theme.syntaxColor, range: hit)
            case .codeSpan:
                storage.addAttribute(.font, value: theme.monoFont, range: hit)
                storage.addAttribute(.foregroundColor, value: theme.codeColor, range: hit)
                storage.addAttribute(.backgroundColor, value: theme.codeBackground, range: hit)
            case .strong:
                storage.addAttribute(.font, value: headerFont, range: hit)
            case .emphasis:
                storage.addAttribute(.font, value: tableItalicFont(theme.monoFont), range: hit)
            case .wikilink, .link:
                storage.addAttribute(.foregroundColor, value: theme.linkColor, range: hit)
            case .strikethrough:
                storage.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: hit)
                storage.addAttribute(.strikethroughColor, value: theme.textColor, range: hit)
            default:
                break
            }
        }
    }

    private static func paragraphRange(_ content: NSRange, length: Int, storage: NSTextStorage) -> NSRange {
        guard NSMaxRange(content) < length else { return content }
        let next = (storage.string as NSString).substring(with: NSRange(location: NSMaxRange(content), length: 1))
        guard next == "\n" || next == "\r" else { return content }
        return NSRange(location: content.location, length: content.length + 1)
    }

    /// Mono cells that fit in `width`, with one spare for the semibold header.
    static func fitColumns(width: CGFloat, advance: CGFloat) -> Int {
        max(0, Int(floor(width / max(advance, 1))) - 1)
    }

    static func monoAdvance(_ font: NSFont) -> CGFloat {
        let width = ("0" as NSString).size(withAttributes: [.font: font]).width
        return max(width, 1)
    }

    /// Italic mono when the converter keeps a fixed pitch, otherwise the table face.
    private static func tableItalicFont(_ mono: NSFont) -> NSFont {
        let converted = NSFontManager.shared.convert(mono, toHaveTrait: .italicFontMask)
        if converted.isFixedPitch { return converted }
        let traits = mono.fontDescriptor.symbolicTraits.union(.italic)
        if let italic = NSFont(descriptor: mono.fontDescriptor.withSymbolicTraits(traits), size: mono.pointSize),
           italic.isFixedPitch {
            return italic
        }
        return mono
    }

    private static func nsRange(_ range: Range<Int>, length: Int) -> NSRange {
        let loc = min(max(0, range.lowerBound), length)
        let end = min(max(loc, range.upperBound), length)
        return NSRange(location: loc, length: end - loc)
    }
}
