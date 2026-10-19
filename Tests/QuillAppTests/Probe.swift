import AppKit
import XCTest
@testable import Quill

/// Collects the same messages the in-binary smoke printed, and fails at the line.
final class Failures {
    private(set) var messages: [String] = []

    func append(_ message: String, file: StaticString = #filePath, line: UInt = #line) {
        messages.append(message)
        XCTFail(message, file: file, line: line)
    }
}


/// Measurements moved out of the in-binary smoke.
@MainActor
enum Probe {
    static func check(
        _ condition: Bool,
        _ message: String,
        failures: Failures,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        if !condition { failures.append(message, file: file, line: line) }
    }

    static func fontWeight(_ font: NSFont) -> CGFloat {
        let traits = font.fontDescriptor.object(forKey: .traits) as? [NSFontDescriptor.TraitKey: Any]
        if let number = traits?[.weight] as? NSNumber {
            return CGFloat(truncating: number)
        }
        return 0
    }

    static func brightness(_ color: NSColor) -> CGFloat {
        let rgb = color.usingColorSpace(.sRGB) ?? color
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        rgb.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return red
    }

    static func colorDistance(_ lhs: NSColor, _ rhs: NSColor) -> CGFloat {
        let a = lhs.usingColorSpace(.sRGB) ?? lhs
        let b = rhs.usingColorSpace(.sRGB) ?? rhs
        var ar: CGFloat = 0, ag: CGFloat = 0, ab: CGFloat = 0, aa: CGFloat = 0
        var br: CGFloat = 0, bg: CGFloat = 0, bb: CGFloat = 0, ba: CGFloat = 0
        a.getRed(&ar, green: &ag, blue: &ab, alpha: &aa)
        b.getRed(&br, green: &bg, blue: &bb, alpha: &ba)
        return abs(ar - br) + abs(ag - bg) + abs(ab - bb)
    }

    static let motionDocument = [
        "# Heading line with several words here",
        "**bold words** in prose long enough to wrap when narrow",
        "- list item longer",
        "short",
        "",
        "| Name | Quantity |",
        "| --- | ---: |",
        "| apple | 12 |",
        "| pear and a much longer description cell | 3 |",
        "emoji 😀 and 日本語 wide",
        "\tindented with a tab",
        "restored column line that is also fairly long so it wraps",
    ]

    /// j / k by screen line and h / l by grapheme, at a narrow and a wide column,
    /// against rows read straight from TextKit line fragments.
    static func expectCaret(_ engine: Engine, _ want: (Int, Int), label: String, failures: Failures) {
        let got = engine.buffer.position(of: engine.cursor)
        check(
            got.line == want.0 && got.utf16Column == want.1,
            "\(label) landed \(got.line),\(got.utf16Column) want \(want.0),\(want.1)",
            failures: failures
        )
    }

    /// Walks every screen row down and back up and compares each landing with
    /// an oracle built from TextKit's rows and display widths, not `ScreenModel`.
    struct OracleCell {
        var offset: Int
        var start: Int
        var end: Int
    }

    /// Display cells of a drawn row. Tab stops count from the buffer line start.
    static func oracleCells(_ ns: NSString, row: Range<Int>, lineStart: Int) -> [OracleCell] {
        var base = 0
        if row.lowerBound > lineStart {
            for character in ns.substring(with: NSRange(location: lineStart, length: row.lowerBound - lineStart)) {
                base = DisplayWidth.advance(base, over: character)
            }
        }
        var column = base
        var offset = row.lowerBound
        var out: [OracleCell] = []
        for character in ns.substring(with: NSRange(location: row.lowerBound, length: row.count)) {
            let next = DisplayWidth.advance(column, over: character)
            out.append(OracleCell(offset: offset, start: column - base, end: next - base))
            column = next
            offset += character.utf16.count
        }
        return out
    }

    /// `l` across headings, bold, table rows, and wide characters visits every
    /// grapheme once and stops at the end of the line. At every step the drawn
    /// caret sits on the glyph TextKit drew for that character, and moves right
    /// within a row, so styling or table padding cannot make it skip or stick.
    static func segmentFrame(_ tv: NSTextView, utf16: Int) -> NSRect? {
        guard let lm = tv.textLayoutManager else { return nil }
        let ns = tv.string as NSString
        guard utf16 < ns.length, let frame = segmentUnion(lm, range: ns.rangeOfComposedCharacterSequence(at: utf16)) else { return nil }
        return frame.offsetBy(dx: tv.textContainerOrigin.x, dy: tv.textContainerOrigin.y)
    }

    static func segmentUnion(_ lm: NSTextLayoutManager, range: NSRange) -> NSRect? {
        let doc = lm.documentRange.location
        guard let start = lm.location(doc, offsetBy: range.location),
              let end = lm.location(start, offsetBy: range.length),
              let textRange = NSTextRange(location: start, end: end) else { return nil }
        var union: NSRect?
        lm.enumerateTextSegments(in: textRange, type: .standard, options: [.rangeNotRequired]) { _, frame, _, _ in
            union = union.map { $0.union(frame) } ?? frame
            return true
        }
        return union
    }

    /// Screen rows as TextKit drew them, newline excluded. The empty fragment
    /// after a final newline is not a row.
    static func drawnRows(_ tv: NSTextView) -> [Range<Int>] {
        guard let lm = tv.textLayoutManager else { return [] }
        lm.ensureLayout(for: lm.documentRange)
        let ns = tv.string as NSString
        let doc = lm.documentRange.location
        var rows: [Range<Int>] = []
        lm.enumerateTextLayoutFragments(from: doc, options: [.ensuresLayout]) { fragment in
            let start = lm.offset(from: doc, to: fragment.rangeInElement.location)
            guard start != NSNotFound else { return true }
            for line in fragment.textLineFragments {
                let range = line.characterRange
                guard range.location != NSNotFound, range.length > 0 else { continue }
                let lower = start + range.location
                var upper = lower + range.length
                while upper > lower, ns.character(at: upper - 1) == 10 {
                    upper -= 1
                }
                rows.append(lower..<upper)
            }
            return true
        }
        return rows
    }

    /// How far past `limit` (text-container x) any visible glyph reaches, or nil.
    /// Trailing spaces may hang at a wrap and are not ink.
    static func widestInk(_ tv: NSTextView, limit: CGFloat) -> CGFloat? {
        guard let lm = tv.textLayoutManager else { return nil }
        let ns = tv.string as NSString
        var worst: CGFloat?
        for row in drawnRows(tv) {
            var upper = row.upperBound
            while upper > row.lowerBound, ns.character(at: upper - 1) == 32 || ns.character(at: upper - 1) == 9 {
                upper -= 1
            }
            guard upper > row.lowerBound,
                  let frame = segmentUnion(lm, range: NSRange(location: row.lowerBound, length: upper - row.lowerBound)) else { continue }
            if frame.maxX > limit + 0.5 {
                worst = max(worst ?? 0, frame.maxX - limit)
            }
        }
        return worst
    }

    /// Which index `NSTextLineFragment.locationForCharacter(at:)` expects on a
    /// continuation row, measured against text segments. The caret and the old
    /// pixel-x `j` / `k` passed a row-relative index here.
    static func probeLineFragmentIndexing(_ tv: NSTextView) -> String {
        guard let lm = tv.textLayoutManager else { return "quill probe line-fragment index: no layout" }
        let doc = lm.documentRange.location
        var report = "quill probe line-fragment index: no wrapped paragraph"
        lm.enumerateTextLayoutFragments(from: doc, options: [.ensuresLayout]) { fragment in
            let lines = fragment.textLineFragments
            guard lines.count > 1 else { return true }
            let row = lines[1]
            let range = row.characterRange
            guard range.length > 3 else { return true }
            let start = lm.offset(from: doc, to: fragment.rangeInElement.location)
            let local = range.location + 2
            guard let truth = segmentUnion(lm, range: NSRange(location: start + local, length: 1)) else { return true }
            let base = fragment.layoutFragmentFrame.minX + row.typographicBounds.minX
            let paragraphX = base + row.locationForCharacter(at: local).x
            let rowX = base + row.locationForCharacter(at: local - range.location).x
            let verdict: String
            if abs(paragraphX - truth.minX) < 1, abs(rowX - truth.minX) >= 1 {
                verdict = "paragraph-relative (a row-relative index is wrong on continuation rows)"
            } else if abs(rowX - truth.minX) < 1, abs(paragraphX - truth.minX) >= 1 {
                verdict = "row-relative"
            } else {
                verdict = "inconclusive"
            }
            report = "quill probe line-fragment index: \(verdict); segment x \(truth.minX), paragraph index \(local) -> \(paragraphX), row index \(local - range.location) -> \(rowX)"
            return false
        }
        return report
    }

    /// A table too wide to align, a small table, a long code line, a long URL,
    /// and a long unbroken word in a narrow window. Nothing draws past the column,
    /// the content is no wider than the viewport, the view never scrolls sideways,
    /// and the caret stays on screen after `$`, every `l` along each long line,
    /// and every `j` / `k` from the top to the bottom and back. A table that fits
    /// only in a wide window aligns there and drops its padding when it narrows.
    static func utf16Length(_ text: String) -> Int {
        (text as NSString).length
    }

    static func motionDiag(engine: Engine, tv: VimTextView, scroll: NSScrollView) -> String {
        let cursor = engine.cursor
        let line = engine.buffer.lineIndex(containing: cursor)
        let column = engine.buffer.position(of: cursor).utf16Column
        let textLines = tv.string.reduce(into: 1) { count, character in
            if character == "\n" { count += 1 }
        }
        let origin = scroll.contentView.bounds.origin.y
        let clip = scroll.contentView.bounds.height
        return "line \(line) col \(column) cursor \(cursor) bufferLines \(engine.buffer.lineCount) textLines \(textLines) visualLines \(tv.layoutAdapter.laidOutLineCount()) doc \(tv.frame.height) clip \(clip) origin \(origin)"
    }

    /// Measures the caret view, not the geometry helper. Height stays within 1.3× of
    /// the font em box and the rect sits in that line's glyph bounds, on the baseline
    /// reported by text segments.
    static func assertCaretGlyph(
        tv: VimTextView,
        index: Int,
        font: NSFont,
        label: String,
        failures: Failures
    ) -> NSRect {
        let length = (tv.string as NSString).length
        let utf16 = min(max(0, index), length)
        tv.engine.moveCursor(to: utf16)
        check(tv.engine.cursor == utf16, "\(label) engine clamped the caret from \(utf16) to \(tv.engine.cursor)", failures: failures)
        tv.setSelectedRange(NSRange(location: utf16, length: 0))
        tv.layoutSubtreeIfNeeded()
        let caret = tv.renderedCaretRect()
        let em = font.ascender - font.descender
        check(
            CaretGeometry.heightFitsEm(caretHeight: Double(caret.height), emHeight: Double(em)),
            "\(label) caret height \(caret.height) is outside 1.3x em \(em)",
            failures: failures
        )
        guard let glyphs = tv.lineGlyphBounds(atUTF16: utf16) else {
            failures.append("\(label) glyph bounds missing at \(utf16)")
            return caret
        }
        let caretBox = CaretBox(
            x: Double(caret.minX),
            y: Double(caret.minY),
            width: Double(caret.width),
            height: Double(caret.height)
        )
        let glyphBox = CaretBox(
            x: Double(glyphs.minX),
            y: Double(glyphs.minY),
            width: Double(glyphs.width),
            height: Double(glyphs.height)
        )
        check(
            CaretGeometry.sitsInGlyphBounds(caret: caretBox, glyph: glyphBox),
            "\(label) caret \(caret) outside glyph bounds \(glyphs)",
            failures: failures
        )
        check(abs(glyphs.height - em) < 1.5, "\(label) glyph bounds height \(glyphs.height) expected em \(em)", failures: failures)
        if let baseline = segmentBaseline(tv, utf16: utf16, font: font) {
            let top = baseline.y - font.ascender
            let bottom = baseline.y - font.descender
            check(
                abs(caret.minY - top) < 2.5 && abs(caret.maxY - bottom) < 2.5,
                "\(label) caret \(caret) missed baseline \(baseline.y) em top \(top) \(baseline.detail)",
                failures: failures
            )
        } else {
            failures.append("\(label) caret baseline missing at \(utf16)")
        }
        check(tv.caretIsVisible, "\(label) caret hidden", failures: failures)
        if let stray = tv.visibleSystemCaretHeight(), stray > em * CaretGeometry.glyphHeightMultiple + 0.75 {
            failures.append("\(label) system caret height \(stray) is outside 1.3x em \(em)")
        }
        return caret
    }

    /// Baseline in text-view coordinates from `enumerateTextSegments`, independent of
    /// the line-fragment math the caret view uses. Past a trailing newline, the last
    /// character's segment is the previous line; the caret belongs on the next one.
    static func segmentBaseline(_ tv: VimTextView, utf16: Int, font: NSFont) -> (y: CGFloat, detail: String)? {
        guard let lm = tv.textLayoutManager else { return nil }
        lm.ensureLayout(for: lm.documentRange)
        let ns = tv.string as NSString
        let length = ns.length
        let index = min(max(0, utf16), length)
        let doc = lm.documentRange.location
        let probe = index < length ? index : max(0, length - 1)
        guard length > 0, let start = lm.location(doc, offsetBy: probe) else { return nil }
        let end = lm.location(start, offsetBy: 1) ?? lm.documentRange.endLocation
        guard let range = NSTextRange(location: start, end: end) else { return nil }
        var frame = CGRect.null
        var position: CGFloat = 0
        var found = false
        lm.enumerateTextSegments(
            in: range,
            type: .standard,
            options: [.rangeNotRequired, .upstreamAffinity]
        ) { _, segmentFrame, baselinePosition, _ in
            frame = segmentFrame
            position = baselinePosition
            found = true
            return false
        }
        guard found else { return nil }
        let origin = tv.textContainerOrigin
        let detail = "segment \(frame) position \(position) origin \(origin)"
        let trailingNewline = index >= length && (ns.character(at: length - 1) == 10 || ns.character(at: length - 1) == 13)
        if trailingNewline {
            let style = (tv.textStorage?.attribute(
                .paragraphStyle,
                at: length - 1,
                effectiveRange: nil
            ) as? NSParagraphStyle) ?? tv.defaultParagraphStyle ?? NSParagraphStyle.default
            let baseline = CaretGeometry.extraLineBaseline(
                previousLineMaxY: Double(frame.maxY),
                ascender: Double(font.ascender),
                descender: Double(font.descender),
                leading: Double(font.leading),
                lineHeightMultiple: Double(style.lineHeightMultiple),
                lineSpacing: Double(style.lineSpacing),
                minimumLineHeight: Double(style.minimumLineHeight),
                maximumLineHeight: Double(style.maximumLineHeight)
            )
            return (origin.y + CGFloat(baseline), detail)
        }
        guard let baseline = CaretGeometry.resolvedBaseline(
            segmentMinY: Double(frame.minY),
            segmentHeight: Double(max(frame.height, 0.1)),
            baselinePosition: Double(position)
        ) else { return nil }
        return (origin.y + CGFloat(baseline), detail)
    }

    static func lineFragmentHeight(_ tv: VimTextView, utf16: Int) -> CGFloat? {
        guard let lm = tv.textLayoutManager else { return nil }
        lm.ensureLayout(for: lm.documentRange)
        guard let location = lm.location(lm.documentRange.location, offsetBy: utf16),
              let fragment = lm.textLayoutFragment(for: location),
              let line = fragment.textLineFragments.first else { return nil }
        return line.typographicBounds.height
    }

    static func foreground(in tv: VimTextView, needle: String) -> NSColor? {
        let ns = tv.string as NSString
        let range = ns.range(of: needle)
        guard range.location != NSNotFound, let storage = tv.textStorage else { return nil }
        return storage.attribute(.foregroundColor, at: range.location, effectiveRange: nil) as? NSColor
    }

    /// Two real window widths. The check must not call `updateInsets` itself:
    /// a resize has to recompute the column, or this fails.
    static func resizeEditor(_ window: NSWindow, scroll: NSScrollView, width: CGFloat, height: CGFloat) {
        let size = NSSize(width: width, height: height)
        window.setContentSize(size)
        scroll.setFrameSize(size)
        scroll.tile()
        scroll.layoutSubtreeIfNeeded()
        scroll.documentView?.layoutSubtreeIfNeeded()
    }

    static func assertWritingColumn(
        _ tv: VimTextView,
        clipWidth: CGFloat,
        label: String,
        failures: Failures
    ) {
        let span = QuillMetrics.columnSpan(width: clipWidth, column: tv.columnWidth)
        let inset = tv.textContainerInset.width
        let column = tv.textContainer?.size.width ?? 0
        check(
            abs(inset - span.inset) < 1,
            "\(label) inset \(inset) expected \(span.inset) clip \(clipWidth)",
            failures: failures
        )
        check(
            abs(column - span.column) < 1,
            "\(label) measure \(column) expected \(span.column) clip \(clipWidth)",
            failures: failures
        )
        let left = tv.textContainerOrigin.x
        let right = tv.bounds.width - left - column
        check(
            abs(left - right) < 3,
            "\(label) not centered left \(left) right \(right) column \(column) view \(tv.bounds.width) clip \(clipWidth)",
            failures: failures
        )
    }

    static func assertDirectoryWidth(_ tv: VimTextView, scroll: NSScrollView, failures: Failures) {
        let clip = scroll.contentView.bounds.width
        let inset = tv.textContainerInset.width
        let column = tv.textContainer?.size.width ?? 0
        let expected = max(1, clip - QuillMetrics.directoryHorizontalInset * 2)
        check(
            abs(inset - QuillMetrics.directoryHorizontalInset) < 0.5,
            "directory resize inset \(inset) clip \(clip)",
            failures: failures
        )
        check(
            abs(column - expected) < 2,
            "directory resize column \(column) expected \(expected) clip \(clip)",
            failures: failures
        )
        check(
            column > tv.columnWidth + 40,
            "directory resize column \(column) still the prose measure \(tv.columnWidth)",
            failures: failures
        )
    }

    static func caretViewportOffset(_ tv: VimTextView, scroll: NSScrollView) -> CGFloat {
        tv.layoutSubtreeIfNeeded()
        let cell = tv.caretCell(suggested: .zero)
        return cell.midY - scroll.contentView.bounds.origin.y
    }

    static func lineFragmentCount(_ textView: NSTextView) -> Int {
        guard let layout = textView.textLayoutManager else { return -1 }
        layout.ensureLayout(for: layout.documentRange)
        var count = 0
        layout.enumerateTextLayoutFragments(from: layout.documentRange.location, options: [.ensuresLayout]) { fragment in
            count += fragment.textLineFragments.filter { $0.characterRange.length > 0 }.count
            return true
        }
        return count
    }

    static func sameColor(_ color: NSColor?, _ expected: NSColor) -> Bool {
        guard let color, let left = color.usingColorSpace(.sRGB), let right = expected.usingColorSpace(.sRGB) else {
            return false
        }
        var lr: CGFloat = 0, lg: CGFloat = 0, lb: CGFloat = 0, la: CGFloat = 0
        var rr: CGFloat = 0, rg: CGFloat = 0, rb: CGFloat = 0, ra: CGFloat = 0
        left.getRed(&lr, green: &lg, blue: &lb, alpha: &la)
        right.getRed(&rr, green: &rg, blue: &rb, alpha: &ra)
        return abs(lr - rr) < 0.02 && abs(lg - rg) < 0.02 && abs(lb - rb) < 0.02 && abs(la - ra) < 0.02
    }

    /// Types into the file picker and live grep, then reads the fields the panel draws.
    static func showPicker(_ window: NSWindow, _ model: AppModel) -> NSHostingView<PickerPanel> {
        let host = NSHostingView(rootView: PickerPanel(model: model))
        host.autoresizingMask = [.width, .height]
        let bounds = window.contentView?.bounds ?? NSRect(x: 0, y: 0, width: 800, height: 640)
        window.contentView = host
        host.frame = bounds
        settle(host, window)
        return host
    }

    static func settle(_ host: NSView, _ window: NSWindow) {
        host.needsLayout = true
        host.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
    }

    static func waitUntil(seconds: TimeInterval, _ ready: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        if ready() { return true }
        while Date() < deadline {
            // `.default` runs the main-actor task that opens the picker.
            // `.common` returns immediately and that task never starts.
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
            if ready() { return true }
        }
        return ready()
    }

    static func queryField(in view: NSView) -> NSTextField? {
        fields("quill.picker.query", in: view).first
    }

    static func modeField(in view: NSView) -> NSTextField? {
        fields("quill.picker.mode", in: view).first
    }

    static func caretView(in view: NSView) -> NSView? {
        findView({ $0.accessibilityIdentifier() == "quill.picker.caret" }, in: view)
    }

    static func resultFields(in view: NSView) -> [NSTextField] {
        fields("quill.picker.result", in: view)
    }

    static func resultTitles(in view: NSView) -> [String] {
        resultFields(in: view).map(\.stringValue)
    }

    static func fields(_ identifier: String, in view: NSView) -> [NSTextField] {
        var found: [NSTextField] = []
        func walk(_ view: NSView) {
            if let field = view as? NSTextField, field.accessibilityIdentifier() == identifier {
                found.append(field)
            }
            for subview in view.subviews { walk(subview) }
        }
        walk(view)
        return found
    }

    static func findView(_ match: @MainActor (NSView) -> Bool, in view: NSView) -> NSView? {
        if match(view) { return view }
        for subview in view.subviews {
            if let found = findView(match, in: subview) { return found }
        }
        return nil
    }

    static func attrChannel(_ field: NSTextField, utf16: Int) -> CGFloat {
        let text = field.attributedStringValue
        guard utf16 >= 0, utf16 < text.length else { return -1 }
        let color = text.attribute(.foregroundColor, at: utf16, effectiveRange: nil) as? NSColor
        guard let color else { return -1 }
        return brightness(color)
    }

    static func viewDump(_ view: NSView) -> String {
        var lines: [String] = []
        func walk(_ view: NSView, depth: Int) {
            guard lines.count < 40 else { return }
            let id = view.accessibilityIdentifier()
            let text = (view as? NSTextField)?.stringValue ?? ""
            let pad = String(repeating: " ", count: depth)
            lines.append("\(pad)\(type(of: view)) id=\(id) text=\(text)")
            for subview in view.subviews { walk(subview, depth: depth + 1) }
        }
        walk(view, depth: 0)
        return lines.joined(separator: " | ")
    }
}

}
