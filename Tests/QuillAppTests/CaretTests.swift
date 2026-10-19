import AppKit
import XCTest
@testable import Quill

@MainActor
extension Probe {
    static func checkCaretGlyphs(failures: Failures) {
        let engine = Engine(text: "")
        let frame = NSRect(x: 0, y: 0, width: 640, height: 400)
        let hosted = VimTextView.host(engine: engine, frame: frame)
        let scroll = hosted.scroll
        let tv = hosted.view
        let window = NSWindow(
            contentRect: frame,
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentView = scroll
        window.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
        window.makeKeyAndOrderFront(nil)
        scroll.frame = window.contentView?.bounds ?? scroll.frame
        tv.layoutSubtreeIfNeeded()

        let body = NSFont.systemFont(ofSize: 20)
        let heading = NSFont.systemFont(ofSize: 32)
        // "iiii\n\nHeading\n" — body, a blank line, a heading, then the extra line at the end.
        let sample = "iiii\n\nHeading\n"
        engine.load(text: sample)
        tv.string = sample
        tv.font = body
        // A non-zero inset makes a caret that forgot textContainerOrigin miss the baseline.
        tv.textContainerInset = NSSize(width: 12, height: 36)
        let style = NSMutableParagraphStyle()
        style.lineHeightMultiple = 1.65
        let ns = sample as NSString
        let full = NSRange(location: 0, length: ns.length)
        tv.textStorage?.addAttribute(.paragraphStyle, value: style, range: full)
        tv.textStorage?.addAttribute(.font, value: body, range: NSRange(location: 0, length: 6))
        let headingAt = 6
        tv.textStorage?.addAttribute(
            .font,
            value: heading,
            range: NSRange(location: headingAt, length: 7)
        )
        tv.textStorage?.addAttribute(.font, value: body, range: NSRange(location: 13, length: 1))
        tv.textLayoutManager?.ensureLayout(for: tv.textLayoutManager!.documentRange)
        tv.layoutSubtreeIfNeeded()
        window.makeFirstResponder(tv)
        engine.mode = .normal

        let block = assertCaretGlyph(
            tv: tv,
            index: 0,
            font: body,
            label: "body",
            failures: failures
        )
        let iAdvance = ceil(("i" as NSString).size(withAttributes: [.font: body]).width)
        let bodyEm = body.ascender - body.descender
        let lineWidth = ("iiii" as NSString).size(withAttributes: [.font: body]).width
        check(abs(block.width - max(1, iAdvance)) < 1.5, "body block width \(block.width) expected \(iAdvance)", failures: failures)
        check(abs(block.height - bodyEm) < 1.5, "body block height \(block.height) expected em \(bodyEm)", failures: failures)
        check(block.width < lineWidth - 1, "body block \(block.width) is wider than one glyph of \(lineWidth)", failures: failures)
        if let fragmentHeight = lineFragmentHeight(tv, utf16: 0), fragmentHeight > bodyEm + 2 {
            check(
                block.height < fragmentHeight - 1,
                "body caret \(block.height) used the line fragment \(fragmentHeight)",
                failures: failures
            )
        }

        let blank = assertCaretGlyph(tv: tv, index: 5, font: body, label: "empty", failures: failures)
        check(abs(blank.height - bodyEm) < 1.5, "empty caret height \(blank.height) expected em \(bodyEm)", failures: failures)
        let space = ceil((" " as NSString).size(withAttributes: [.font: body]).width)
        check(abs(blank.width - max(1, space)) < 1.5, "empty caret width \(blank.width) expected \(space)", failures: failures)

        let head = assertCaretGlyph(tv: tv, index: headingAt, font: heading, label: "heading", failures: failures)
        let hAdvance = ceil(("H" as NSString).size(withAttributes: [.font: heading]).width)
        let headEm = heading.ascender - heading.descender
        check(abs(head.width - max(1, hAdvance)) < 1.5, "heading block width \(head.width) expected \(hAdvance)", failures: failures)
        check(abs(head.height - headEm) < 1.5, "heading block height \(head.height) expected em \(headEm)", failures: failures)
        check(head.height > block.height + 2, "heading caret \(head.height) should be taller than body \(block.height)", failures: failures)

        // The empty line after a final newline only holds an insert-mode caret.
        engine.mode = .insert
        let beam = assertCaretGlyph(tv: tv, index: headingAt, font: heading, label: "insert", failures: failures)
        let beamWidth = CaretGeometry.beamPointWidth(backingScale: Double(window.backingScaleFactor))
        check(abs(Double(beam.width) - beamWidth) < 0.2, "insert beam width \(beam.width) expected \(beamWidth)", failures: failures)
        check(abs(beam.height - headEm) < 1.5, "insert beam height \(beam.height) expected \(headEm)", failures: failures)
        check(tv.caretIsBlinking, "insert blink missing", failures: failures)
        let endBeam = assertCaretGlyph(tv: tv, index: ns.length, font: body, label: "insert end", failures: failures)
        check(
            CaretGeometry.heightFitsEm(caretHeight: Double(endBeam.height), emHeight: Double(bodyEm)),
            "insert end caret height \(endBeam.height) is outside 1.3x em \(bodyEm)",
            failures: failures
        )
        engine.mode = .normal
        _ = assertCaretGlyph(tv: tv, index: 0, font: body, label: "body", failures: failures)
        check(!tv.caretIsBlinking, "normal blink", failures: failures)
        check(tv.caretIsVisible, "mode switch hid the caret", failures: failures)
        window.orderOut(nil)
    }
}

final class CaretTests: QuillAppTestCase {
    @MainActor
    func testCaretGlyph() {
        let failures = Failures()
        Probe.checkCaretGlyphs(failures: failures)
    }
}
