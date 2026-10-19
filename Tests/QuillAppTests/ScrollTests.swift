import AppKit
import QuillVim
import XCTest
@testable import Quill

@MainActor
extension Probe {
    static func checkScrolling(failures: Failures) {
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

        tv.textContainerInset = NSSize(width: 0, height: 0)
        tv.layoutSubtreeIfNeeded()

        let lines = (0..<80).map { "line \($0) abcdefghij" }.joined(separator: "\n")
        engine.load(text: lines)
        tv.reload()
        tv.layoutSubtreeIfNeeded()
        tv.noteContentSizeChanged()
        let clipHeight = scroll.contentView.bounds.height
        check(
            tv.frame.height > clipHeight + 20,
            "document height \(tv.frame.height) is not taller than the clip \(clipHeight)",
            failures: failures
        )
        let origin = scroll.contentView.bounds.origin.y
        tv.consumeScroll(deltaY: -240, precise: true)
        let scrolled = scroll.contentView.bounds.origin.y
        check(scrolled > origin + 50, "trackpad scroll \(origin) -> \(scrolled)", failures: failures)

        _ = tv.press("gg")
        tv.reload()
        for _ in 0..<40 {
            _ = tv.press("j")
        }
        let line = engine.buffer.lineIndex(containing: engine.cursor)
        let column = engine.buffer.position(of: engine.cursor).utf16Column
        let afterJ = motionDiag(engine: engine, tv: tv, scroll: scroll)
        check(line == 40, "j stopped on line \(line) (\(afterJ))", failures: failures)
        check(column == 0, "j column drifted to \(column) (\(afterJ))", failures: failures)
        check(
            scroll.contentView.bounds.origin.y > 20,
            "j did not scroll the viewport (\(afterJ))",
            failures: failures
        )

        _ = tv.press("G")
        tv.reload()
        let atEnd = scroll.contentView.bounds.origin.y
        check(
            atEnd > tv.frame.height * 0.3,
            "G left the viewport at \(atEnd) of \(tv.frame.height) (\(motionDiag(engine: engine, tv: tv, scroll: scroll)))",
            failures: failures
        )
        _ = tv.press("gg")
        tv.reload()
        // The first line sits below the top margin, so the origin rests just above that line.
        let top = max(40, tv.textContainerInset.height + 8)
        check(
            scroll.contentView.bounds.origin.y < top,
            "gg left the viewport (\(motionDiag(engine: engine, tv: tv, scroll: scroll)))",
            failures: failures
        )

        engine.scrollLineCount = tv.halfPageLines()
        let before = engine.buffer.lineIndex(containing: engine.cursor)
        _ = tv.press("<C-d>")
        tv.reload()
        let after = engine.buffer.lineIndex(containing: engine.cursor)
        check(
            after >= before + engine.scrollLineCount,
            "Ctrl-d moved \(before) -> \(after) scroll \(engine.scrollLineCount) (\(motionDiag(engine: engine, tv: tv, scroll: scroll)))",
            failures: failures
        )
        _ = tv.press("<C-u>")
        tv.reload()
        let back = engine.buffer.lineIndex(containing: engine.cursor)
        check(
            back <= before + 1,
            "Ctrl-u moved to \(back) from \(after) (\(motionDiag(engine: engine, tv: tv, scroll: scroll)))",
            failures: failures
        )
        window.orderOut(nil)
    }

    /// A 10k-line note stays one buffer in the text view: `G` scrolls to the
    /// end, search lands on a late line, and select-all covers the file.
    static func checkLongNote(failures: Failures) {
        let lineCount = 10_000
        let markerLine = 9_000
        let text = (0..<lineCount).map { line -> String in
            if line == markerLine {
                return "Line \(line) MARKER-9000 end\n"
            }
            return "Line \(line) plain\n"
        }.joined()
        let engine = Engine(text: text)
        let frame = NSRect(x: 0, y: 0, width: 800, height: 600)
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
        tv.reload()
        tv.layoutSubtreeIfNeeded()

        let viewLength = (tv.string as NSString).length
        check(
            tv.string == text && viewLength == engine.buffer.count,
            "long note view holds \(viewLength) of \(engine.buffer.count)",
            failures: failures
        )
        let clip = scroll.contentView.bounds.height
        check(
            tv.frame.height > clip * 20,
            "long note height \(tv.frame.height) is not the whole file",
            failures: failures
        )
        tv.selectAll(nil as Any?)
        let selected = tv.selectedRange()
        let copied = selected.length == viewLength && selected.location == 0
            ? (tv.string as NSString).substring(with: selected)
            : ""
        check(
            copied == text,
            "select all copied \(selected.location)+\(selected.length) of \(viewLength)",
            failures: failures
        )

        _ = tv.press("gg")
        tv.reload()
        _ = tv.press("G")
        tv.reload()
        let endLine = engine.buffer.lineIndex(containing: engine.cursor)
        let maxY = max(0, tv.frame.height - clip)
        let atEnd = scroll.contentView.bounds.origin.y
        check(endLine == lineCount - 1, "G stopped on line \(endLine)", failures: failures)
        check(
            atEnd > maxY - clip,
            "G scroll \(atEnd) did not reach \(maxY) (\(motionDiag(engine: engine, tv: tv, scroll: scroll)))",
            failures: failures
        )

        _ = tv.press("gg")
        tv.reload()
        _ = tv.press("/MARKER-9000<CR>")
        tv.reload()
        let found = engine.buffer.lineIndex(containing: engine.cursor)
        check(found == markerLine, "search landed on line \(found)", failures: failures)
        let row = tv.frame.height / CGFloat(max(engine.buffer.lineCount, 1))
        let lineY = CGFloat(markerLine) * row
        let origin = scroll.contentView.bounds.origin.y
        check(
            lineY >= origin - row * 2 && lineY <= origin + clip + row * 2,
            "search scroll \(origin) does not show line \(markerLine) at \(lineY)",
            failures: failures
        )
        window.orderOut(nil)
    }

    /// Headings, bold, a list, short and empty lines, a table with a long row,
    /// wide characters, and a tab. Prose lines are long enough to wrap in the
    /// narrow column; in the wide one every buffer line is one screen line.
}

final class ScrollTests: QuillAppTestCase {
    @MainActor
    func testScrolling() {
        let failures = Failures()
        Probe.checkScrolling(failures: failures)
    }

    @MainActor
    func testLongNote() {
        let failures = Failures()
        Probe.checkLongNote(failures: failures)
    }
}
