import AppKit
import QuillVim
import XCTest
@testable import Quill

@MainActor
extension Probe {
    /// `j` from the last line that fits scrolls before the caret is halfway off.
    /// The caret's screen line, plus one more line, stays inside the clip. The
    /// same holds for a wrapped row and for the gap under an image preview.
    static func checkScrollMargin(failures: Failures) {
        var lines: [String] = []
        for index in 0..<36 {
            if index == 4 {
                lines.append("# Heading scroll margin")
            } else if index == 14 {
                lines.append("![gap](no-such-preview.png)")
            } else {
                lines.append("line \(index) abc")
            }
        }
        let harness = EditorHarness(
            text: lines.joined(separator: "\n"),
            size: NSSize(width: 780, height: 460)
        )
        defer { harness.close() }
        let tv = harness.view
        let engine = harness.engine
        let scroll = harness.scroll
        tv.setImageContext(enabled: true, filePath: "/tmp/quill-scroll-margin.md")
        tv.reload()
        tv.layoutSubtreeIfNeeded()
        tv.flushImagePreviews()
        check(
            tv.textContainerInset.height > 40,
            "scroll margin inset \(tv.textContainerInset.height)",
            failures: failures
        )
        let bang = (tv.string as NSString).range(of: "![gap]")
        guard bang.location != NSNotFound else {
            failures.append("scroll margin image line missing")
            return
        }
        let imageLine = engine.buffer.lineIndex(containing: bang.location)
        let imageUTF16 = engine.buffer.line(imageLine).start
        let imageSpacing = paragraphSpacing(tv, utf16: imageUTF16)
        check(
            imageSpacing > 40,
            "scroll margin image spacing \(imageSpacing)",
            failures: failures
        )

        _ = tv.press("gg")
        var didScroll = false
        var sawImage = false
        for _ in 0..<40 {
            let before = scroll.contentView.bounds.origin.y
            let result = tv.press("j")
            if result.beep { break }
            if scroll.contentView.bounds.origin.y > before + 0.5 { didScroll = true }
            if engine.buffer.lineIndex(containing: engine.cursor) == imageLine {
                sawImage = true
                let spacing = paragraphSpacing(tv, utf16: engine.cursor)
                check(spacing > 40, "scroll margin image spacing dropped to \(spacing)", failures: failures)
            }
            let beforeFailures = failures.messages.count
            assertScrollMargin(tv, scroll: scroll, label: "j", failures: failures)
            if failures.messages.count > beforeFailures { break }
        }
        check(didScroll, "scroll margin: j never left the first screen", failures: failures)
        check(sawImage, "scroll margin: j missed the image line", failures: failures)
        for _ in 0..<40 {
            let result = tv.press("k")
            if result.beep { break }
            assertScrollMargin(tv, scroll: scroll, label: "k", failures: failures)
        }

        let paragraph = Array(repeating: "wrap", count: 80).joined(separator: " ")
        engine.load(text: paragraph + "\n")
        tv.reload()
        harness.resize(to: NSSize(width: 340, height: 460))
        tv.layoutSubtreeIfNeeded()
        _ = tv.press("gg")
        var wrapped = 0
        for _ in 0..<40 {
            let before = engine.cursor
            let result = tv.press("j")
            if result.beep || engine.cursor == before { break }
            wrapped += 1
            assertScrollMargin(tv, scroll: scroll, label: "wrap j", failures: failures)
        }
        check(wrapped > 4, "scroll margin: wrapped paragraph did not break (\(wrapped))", failures: failures)
        for _ in 0..<wrapped {
            let result = tv.press("k")
            if result.beep { break }
            assertScrollMargin(tv, scroll: scroll, label: "wrap k", failures: failures)
        }
    }

    /// The caret's screen line, and one body row past it, inside the clip.
    /// A line taller than the window (a large preview) keeps the caret cell.
    private static func assertScrollMargin(
        _ tv: VimTextView,
        scroll: NSScrollView,
        label: String,
        failures: Failures
    ) {
        guard let box = scrollLineBox(tv) else {
            failures.append("scroll margin: \(label) line box missing")
            return
        }
        let caret = tv.renderedCaretRect()
        let visible = scroll.contentView.bounds
        let pad = tv.bodyRowHeight()
        let target: NSRect
        let margin: CGFloat
        if box.height + 0.5 < visible.height {
            target = box
            margin = min(pad, max(0, (visible.height - box.height) / 2))
        } else {
            target = caret
            margin = min(pad, max(0, (visible.height - caret.height) / 2))
        }
        let maxScroll = max(0, tv.frame.height - visible.height)
        let atTop = visible.origin.y <= 0.5
        let atBottom = visible.origin.y >= maxScroll - 0.5
        check(
            target.minY >= visible.minY - 1 && target.maxY <= visible.maxY + 1,
            "scroll margin: \(label) line \(target) outside \(visible)",
            failures: failures
        )
        if !atTop {
            check(
                target.minY >= visible.minY + margin - 2,
                "scroll margin: \(label) top \(target.minY) visible \(visible.minY) margin \(margin)",
                failures: failures
            )
        }
        if !atBottom {
            check(
                target.maxY <= visible.maxY - margin + 2,
                "scroll margin: \(label) bottom \(target.maxY) visible \(visible.maxY) margin \(margin)",
                failures: failures
            )
        }
    }

    /// Full screen line around the caret, in text-view coordinates. The em box
    /// hangs from the bottom of the line. Paragraph spacing on a single-row
    /// line is the image preview under it.
    private static func scrollLineBox(_ tv: VimTextView) -> NSRect? {
        let caret = tv.renderedCaretRect()
        guard caret.height > 0.5 else { return nil }
        let storage = tv.textStorage
        let length = storage?.length ?? 0
        let index = min(max(0, tv.engine.cursor), max(0, length - 1))
        let font: NSFont
        let style: NSParagraphStyle
        if length > 0, let storage {
            font = (storage.attribute(.font, at: index, effectiveRange: nil) as? NSFont)
                ?? tv.font
                ?? QuillTheme.current().bodyFont
            style = (storage.attribute(.paragraphStyle, at: index, effectiveRange: nil) as? NSParagraphStyle)
                ?? tv.defaultParagraphStyle
                ?? NSParagraphStyle.default
        } else {
            font = tv.font ?? QuillTheme.current().bodyFont
            style = tv.defaultParagraphStyle ?? NSParagraphStyle.default
        }
        let lineHeight = CGFloat(CaretGeometry.lineFragmentHeight(
            ascender: Double(font.ascender),
            descender: Double(font.descender),
            leading: Double(font.leading),
            lineHeightMultiple: Double(style.lineHeightMultiple),
            lineSpacing: Double(style.lineSpacing),
            minimumLineHeight: Double(style.minimumLineHeight),
            maximumLineHeight: Double(style.maximumLineHeight)
        ))
        let height = max(lineHeight, caret.height)
        var top = min(caret.minY, caret.maxY - height)
        var bottom = max(caret.maxY, top + height)
        if style.paragraphSpacing > 0.5 {
            bottom += style.paragraphSpacing
        }
        if style.paragraphSpacingBefore > 0.5 {
            top -= style.paragraphSpacingBefore
        }
        guard bottom > top + 0.5 else { return nil }
        return NSRect(x: caret.minX, y: top, width: max(caret.width, 1), height: bottom - top)
    }

    private static func paragraphSpacing(_ tv: VimTextView, utf16: Int) -> CGFloat {
        guard let storage = tv.textStorage, storage.length > 0 else { return 0 }
        let index = min(max(0, utf16), storage.length - 1)
        let style = storage.attribute(.paragraphStyle, at: index, effectiveRange: nil) as? NSParagraphStyle
        return style?.paragraphSpacing ?? 0
    }
}

final class ScrollMarginTests: QuillAppTestCase {
    @MainActor
    func testScrollMargin() {
        let failures = Failures()
        Probe.checkScrollMargin(failures: failures)
    }
}
