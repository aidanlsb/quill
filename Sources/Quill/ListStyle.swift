import AppKit
import CoreText
import QuillMarkdown

extension QuillTheme {
    /// First line sits in the list gutter. Wrapped rows start at the same
    /// gutter plus the marker width, so they line up with the item text.
    @MainActor
    func listParagraphStyle(hang: CGFloat) -> NSParagraphStyle {
        let para = NSMutableParagraphStyle()
        para.lineHeightMultiple = lineHeight
        para.paragraphSpacing = listItemSpacing
        para.firstLineHeadIndent = listIndent
        para.headIndent = listIndent + hang
        return para
    }
}

extension MarkdownStyler {
    /// Visual hanging indent for list items. The buffer stays the characters the
    /// user typed; only the paragraph style moves wrapped rows and the gutter.
    static func applyListHangingIndents(
        _ storage: NSTextStorage,
        theme: QuillTheme,
        spans: [TokenSpan],
        limit: NSRange
    ) {
        guard limit.length > 0, storage.length > 0 else { return }
        let ns = storage.string as NSString
        for span in spans where span.token == .listMarker {
            let start = span.range.lowerBound
            guard start >= 0, start < ns.length else { continue }
            let line = ns.lineRange(for: NSRange(location: start, length: 0))
            guard NSIntersectionRange(line, limit).length > 0 else { continue }
            let content = contentRange(line, in: ns)
            guard content.length > 0, content.location == start else { continue }
            guard let prefix = hangPrefix(ns, content: content), prefix > 0 else { continue }
            let hang = prefixWidth(storage, content: content, prefix: prefix)
            guard hang > 0.5 else { continue }
            storage.addAttribute(.paragraphStyle, value: theme.listParagraphStyle(hang: hang), range: line)
        }
    }

    /// Marker length from the tokenizer, measured on a short prefix so a long
    /// item does not copy the whole line on the keystroke path.
    private static func hangPrefix(_ ns: NSString, content: NSRange) -> Int? {
        let sniff = min(content.length, 1024)
        var end = content.location + sniff
        if sniff > 0, end < NSMaxRange(content) {
            let unit = ns.character(at: end - 1)
            if unit >= 0xD800, unit <= 0xDBFF { end -= 1 }
        }
        let length = end - content.location
        guard length > 0 else { return nil }
        let head = ns.substring(with: NSRange(location: content.location, length: length))
        guard let prefix = MarkdownTokenizer.listHangPrefixUTF16(head), prefix > 0, prefix <= length else {
            return nil
        }
        return prefix
    }

    /// Width of `prefix` UTF-16 units as drawn, including the heavier marker
    /// face. One extra character is included so kerning at the marker boundary
    /// matches the laid-out first row.
    private static func prefixWidth(_ storage: NSTextStorage, content: NSRange, prefix: Int) -> CGFloat {
        let count = min(prefix, content.length)
        guard count > 0 else { return 0 }
        let sampleLength = min(content.length, count + 1)
        let sampleRange = NSRange(location: content.location, length: sampleLength)
        guard NSMaxRange(sampleRange) <= storage.length else { return 0 }
        let sample = NSMutableAttributedString(attributedString: storage.attributedSubstring(from: sampleRange))
        let full = NSRange(location: 0, length: sample.length)
        sample.removeAttribute(.paragraphStyle, range: full)
        let line = CTLineCreateWithAttributedString(sample as CFAttributedString)
        return CGFloat(CTLineGetOffsetForStringIndex(line, count, nil))
    }

    private static func contentRange(_ line: NSRange, in ns: NSString) -> NSRange {
        var range = line
        while range.length > 0 {
            let ch = ns.character(at: NSMaxRange(range) - 1)
            if ch == 10 || ch == 13 {
                range.length -= 1
                continue
            }
            break
        }
        return range
    }
}
