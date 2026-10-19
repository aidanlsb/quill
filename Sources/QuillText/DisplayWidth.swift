/// Display columns are terminal-style cells, not points. A column is the same on
/// a 32pt heading, bold text, a proportional body font, or a monospaced table,
/// so vertical motion cannot drift when styling changes glyph widths.
///
/// One cell for most graphemes, two for East Asian wide characters and emoji
/// presentation, and a tab advances to the next multiple of `tabWidth`.
public enum DisplayWidth {
    public static let defaultTabWidth = 4

    /// Cells for one grapheme other than a tab.
    public static func cells(_ grapheme: Character) -> Int {
        let scalars = grapheme.unicodeScalars
        guard let first = scalars.first else { return 0 }
        if scalars.count > 1 {
            for scalar in scalars where scalar.value == 0xFE0F || scalar.value == 0x200D {
                return 2
            }
        }
        if first.properties.isEmojiPresentation { return 2 }
        if isWide(first.value) { return 2 }
        return 1
    }

    /// Column after `grapheme` when it starts at `column`.
    public static func advance(_ column: Int, over grapheme: Character, tabWidth: Int = defaultTabWidth) -> Int {
        if grapheme == "\t" {
            let width = max(1, tabWidth)
            return (column / width + 1) * width
        }
        return column + cells(grapheme)
    }

    /// Total cells for `text` starting at column 0.
    public static func columns(of text: String, tabWidth: Int = defaultTabWidth) -> Int {
        var column = 0
        for grapheme in text {
            column = advance(column, over: grapheme, tabWidth: tabWidth)
        }
        return column
    }

    private static func isWide(_ value: UInt32) -> Bool {
        switch value {
        case 0x1100...0x115F, 0x231A...0x231B, 0x2329...0x232A, 0x2E80...0x303E,
             0x3041...0x33FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xA000...0xA4CF,
             0xA960...0xA97F, 0xAC00...0xD7A3, 0xF900...0xFAFF, 0xFE10...0xFE19,
             0xFE30...0xFE6F, 0xFF00...0xFF60, 0xFFE0...0xFFE6, 0x1F300...0x1F64F,
             0x1F900...0x1F9FF, 0x20000...0x2FFFD, 0x30000...0x3FFFD:
            return true
        default:
            return false
        }
    }
}
