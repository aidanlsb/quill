import AppKit
import QuillVim
import XCTest
@testable import Quill

@MainActor
extension Probe {
    static func checkColumnFollowsResize(failures: Failures) {
        let measure: CGFloat = 420
        let height: CGFloat = 520
        let line = String(repeating: "alpha bravo ", count: 12)
        let lines = (0..<40).map { "\($0) \(line)" }.joined(separator: "\n")
        let engine = Engine(text: lines)
        let frame = NSRect(x: 0, y: 0, width: 960, height: height)
        let hosted = VimTextView.host(engine: engine, frame: frame)
        let scroll = hosted.scroll
        // The column check measures the clip. A vertical scroller changes it.
        scroll.hasVerticalScroller = false
        scroll.autoresizingMask = [.width, .height]
        let tv = hosted.view
        tv.isDirectoryBuffer = false
        tv.columnWidth = measure
        let window = NSWindow(
            contentRect: frame,
            styleMask: [.titled, .resizable, .closable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = scroll
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(tv)
        defer {
            window.orderOut(nil)
            window.close()
        }
        tv.applyTheme(QuillTheme.current(), focus: false)
        tv.reload()

        resizeEditor(window, scroll: scroll, width: 640, height: height)
        let narrowClip = scroll.contentView.bounds.width
        assertWritingColumn(tv, clipWidth: narrowClip, label: "column narrow", failures: failures)
        let narrowSpan = QuillMetrics.columnSpan(width: narrowClip, column: measure)
        check(
            abs(narrowSpan.inset - QuillMetrics.sideGutter) < 1,
            "column clip \(narrowClip) inset \(narrowSpan.inset) is not the minimum gutter",
            failures: failures
        )
        check(
            narrowSpan.column < measure - 10,
            "column clip \(narrowClip) measure \(narrowSpan.column) did not shrink",
            failures: failures
        )
        tv.viewDidEndLiveResize()
        assertWritingColumn(tv, clipWidth: scroll.contentView.bounds.width, label: "column narrow", failures: failures)

        for _ in 0..<24 {
            _ = tv.press("j")
        }
        let originBefore = scroll.contentView.bounds.origin.y
        let caretBefore = caretViewportOffset(tv, scroll: scroll)
        let cursor = engine.cursor
        check(originBefore > 20, "column caret origin \(originBefore) did not scroll", failures: failures)
        check(caretBefore > 8, "column caret \(caretBefore) was not in view", failures: failures)

        resizeEditor(window, scroll: scroll, width: 1280, height: height)
        let wideClip = scroll.contentView.bounds.width
        assertWritingColumn(tv, clipWidth: wideClip, label: "column wide", failures: failures)
        let wideSpan = QuillMetrics.columnSpan(width: wideClip, column: measure)
        check(
            abs(wideSpan.column - measure) < 1,
            "column clip \(wideClip) measure \(wideSpan.column) is not the max",
            failures: failures
        )
        check(
            tv.textContainerInset.width > narrowSpan.inset + 30,
            "column inset did not grow \(tv.textContainerInset.width) from \(narrowSpan.inset) clips \(narrowClip) \(wideClip)",
            failures: failures
        )
        check(wideClip > narrowClip + 200, "column clip did not widen \(narrowClip) -> \(wideClip)", failures: failures)
        let caretLive = caretViewportOffset(tv, scroll: scroll)
        check(engine.cursor == cursor, "column caret cursor moved to \(engine.cursor)", failures: failures)
        check(
            abs(caretLive - caretBefore) < 20,
            "column caret \(caretBefore) -> \(caretLive) origin \(originBefore) -> \(scroll.contentView.bounds.origin.y)",
            failures: failures
        )
        tv.viewDidEndLiveResize()
        assertWritingColumn(tv, clipWidth: scroll.contentView.bounds.width, label: "column wide", failures: failures)
        let caretSettled = caretViewportOffset(tv, scroll: scroll)
        check(
            abs(caretSettled - caretBefore) < 20,
            "column caret \(caretBefore) -> \(caretSettled) after live resize origin \(scroll.contentView.bounds.origin.y)",
            failures: failures
        )

        tv.isDirectoryBuffer = true
        resizeEditor(window, scroll: scroll, width: 760, height: height)
        assertDirectoryWidth(tv, scroll: scroll, failures: failures)
        let directoryNarrow = tv.textContainer?.size.width ?? 0
        resizeEditor(window, scroll: scroll, width: 1180, height: height)
        tv.viewDidEndLiveResize()
        assertDirectoryWidth(tv, scroll: scroll, failures: failures)
        let directoryWide = tv.textContainer?.size.width ?? 0
        check(
            directoryWide > directoryNarrow + 150,
            "directory resize column did not grow \(directoryNarrow) -> \(directoryWide)",
            failures: failures
        )
    }

}

final class ColumnTests: QuillAppTestCase {
    @MainActor
    func testColumnFollowsResize() {
        let failures = Failures()
        Probe.checkColumnFollowsResize(failures: failures)
    }
}
