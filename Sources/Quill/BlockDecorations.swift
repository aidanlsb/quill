import AppKit
import QuillMarkdown

extension VimTextView {
    /// Quote bars and thematic-break rules behind the characters. O(visible).
    func drawBlockDecorations(in rect: NSRect) {
        guard engine != nil, !isDirectoryBuffer else { return }
        let spans = decorationSpans(in: rect)
        guard !spans.isEmpty else { return }
        for span in spans {
            switch span.token {
            case .blockquote:
                drawQuoteBar(utf16: span.range.lowerBound, in: rect)
            case .thematicBreak:
                drawThematicRule(utf16: span.range.lowerBound, in: rect)
            default:
                continue
            }
        }
    }

    fileprivate func decorationSpans(in rect: NSRect) -> [TokenSpan] {
        let visible = visibleUTF16(in: rect)
        guard !visible.isEmpty else { return [] }
        return tokenizer.spans(overlapping: visible).filter {
            $0.token == .blockquote || $0.token == .thematicBreak
        }
    }

    fileprivate func drawQuoteBar(utf16: Int, in dirty: NSRect) {
        guard let box = inkBox(at: utf16), box.row.intersects(dirty) else { return }
        let height = max(8, box.row.height - 6)
        let bar = NSRect(
            x: box.text.minX - 11,
            y: box.row.minY + 3,
            width: 2,
            height: height
        )
        theme.quoteBarColor.setFill()
        NSBezierPath(roundedRect: bar, xRadius: 1, yRadius: 1).fill()
    }

    fileprivate func drawThematicRule(utf16: Int, in dirty: NSRect) {
        guard let box = inkBox(at: utf16), box.row.intersects(dirty) else { return }
        let width = max(24, (textContainer?.size.width ?? box.row.width) - 16)
        let rule = NSRect(
            x: textContainerInset.width + 8,
            y: box.row.midY - 0.5,
            width: width,
            height: 1
        )
        theme.ruleColor.setFill()
        NSBezierPath(roundedRect: rule, xRadius: 0.5, yRadius: 0.5).fill()
    }

    fileprivate func visibleUTF16(in rect: NSRect) -> Range<Int> {
        guard let lm = textLayoutManager else { return 0..<0 }
        let origin = textContainerOrigin
        let probe = CGPoint(x: 0, y: max(0, rect.minY - origin.y))
        let startLoc = lm.textLayoutFragment(for: probe)?.rangeInElement.location ?? lm.documentRange.location
        let doc = lm.documentRange.location
        let start = max(0, lm.offset(from: doc, to: startLoc))
        var end = start
        let docEnd = lm.offset(from: doc, to: lm.documentRange.endLocation)
        lm.enumerateTextLayoutFragments(from: startLoc, options: [.ensuresLayout]) { fragment in
            let frame = fragment.layoutFragmentFrame
            let minY = frame.minY + origin.y
            if minY >= rect.maxY { return false }
            let fragmentEnd = lm.offset(from: doc, to: fragment.rangeInElement.endLocation)
            if fragmentEnd != NSNotFound { end = max(end, fragmentEnd) }
            return true
        }
        if docEnd != NSNotFound { end = min(end, docEnd) }
        return start..<max(start, end)
    }

    fileprivate func inkBox(at utf16: Int) -> (row: NSRect, text: NSRect)? {
        guard let lm = textLayoutManager else { return nil }
        let doc = lm.documentRange.location
        let index = min(max(0, utf16), (string as NSString).length)
        guard let location = lm.location(doc, offsetBy: index),
              let fragment = lm.textLayoutFragment(for: location) else { return nil }
        let fragmentStart = lm.offset(from: doc, to: fragment.rangeInElement.location)
        let local = index - fragmentStart
        guard let line = fragment.textLineFragments.first(where: { line in
            let span = line.characterRange
            return local >= span.location && local < span.location + max(span.length, 1)
        }) ?? fragment.textLineFragments.last else { return nil }
        let container = textContainerOrigin
        let fragmentFrame = fragment.layoutFragmentFrame
        var text = line.typographicBounds
        text.origin.x += container.x + fragmentFrame.minX
        text.origin.y += container.y + fragmentFrame.minY
        var row = text
        row.origin.x = 0
        row.size.width = bounds.width
        return (row, text)
    }
}
