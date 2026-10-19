import AppKit
import QuillMarkdown
import QuillVim
import XCTest
@testable import Quill

/// Wrapped list rows line up with the text after the marker. The source stays
/// the characters that were typed.
@MainActor
final class ListStyleTests: QuillAppTestCase {
    func testWrappedListHangsAtTheMarker() {
        let body = Array(repeating: "alpha", count: 24).joined(separator: " ")
        let markers: [(label: String, marker: String)] = [
            (label: "dash", marker: "- "),
            (label: "star", marker: "* "),
            (label: "plus", marker: "+ "),
            (label: "ordered", marker: "1. "),
            (label: "ordered-two", marker: "12. "),
            (label: "task-open", marker: "- [ ] "),
            (label: "task-done", marker: "- [x] "),
            (label: "task-upper", marker: "- [X] "),
            (label: "nested", marker: "  - "),
            (label: "nested-deeper", marker: "    * "),
            (label: "prose", marker: "plain "),
        ]
        var lines = markers.map { $0.marker + body }
        lines.append("```")
        lines.append("- " + body)
        lines.append("```")
        let source = lines.joined(separator: "\n")
        var starts: [Int] = []
        var cursor = 0
        for (index, line) in lines.enumerated() {
            starts.append(cursor)
            cursor += (line as NSString).length
            if index + 1 < lines.count { cursor += 1 }
        }

        let width: CGFloat = 200
        let tv = NSTextView(usingTextLayoutManager: true)
        tv.isHorizontallyResizable = false
        tv.isVerticallyResizable = true
        tv.textContainerInset = .zero
        tv.textContainer?.lineFragmentPadding = 0
        tv.textContainer?.widthTracksTextView = false
        tv.textContainer?.heightTracksTextView = false
        tv.textContainer?.size = NSSize(width: width, height: 20_000)
        tv.frame = NSRect(x: 0, y: 0, width: width, height: 4_000)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: 4_000),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
        window.contentView = tv
        tv.frame = window.contentView?.bounds ?? tv.frame
        tv.textContainer?.size = NSSize(width: width, height: 20_000)
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }

        let theme = QuillTheme.current()
        tv.string = source
        let doc = MarkdownTokenizer(text: source)
        guard let storage = tv.textStorage else {
            XCTFail("list hang storage")
            return
        }
        MarkdownStyler.restyle(storage, theme: theme, spans: doc.spans, tableColumnWidth: width)
        XCTAssertEqual(storage.string, source, "list hang rewrote the buffer")
        tv.layoutSubtreeIfNeeded()
        let drawn = Probe.drawnRows(tv)
        guard let lm = tv.textLayoutManager else {
            XCTFail("list hang layout")
            return
        }

        func rows(at index: Int) -> [Range<Int>] {
            let start = starts[index]
            let end = start + (lines[index] as NSString).length
            return drawn.filter { $0.lowerBound >= start && $0.lowerBound < end }
        }

        func minX(_ utf16: Int) -> CGFloat? {
            Probe.segmentUnion(lm, range: NSRange(location: utf16, length: 1))?.minX
        }

        var textColumns: [String: CGFloat] = [:]
        for (index, entry) in markers.enumerated() {
            let label = entry.label
            let line = lines[index]
            let start = starts[index]
            let wrapped = rows(at: index)
            guard wrapped.count > 1 else {
                XCTFail("list hang \(label) did not wrap (\(wrapped.count) rows)")
                continue
            }
            let isList = label != "prose"
            let prefix = MarkdownTokenizer.listHangPrefixUTF16(line)
            let style = storage.attribute(.paragraphStyle, at: start, effectiveRange: nil) as? NSParagraphStyle
            XCTAssertEqual(style?.firstLineHeadIndent ?? -1, 0, accuracy: 0.01, "list hang \(label) first line")
            if isList {
                guard let prefix else {
                    XCTFail("list hang \(label) prefix")
                    continue
                }
                XCTAssertGreaterThan(style?.headIndent ?? 0, 1, "list hang \(label) indent")
                guard let textX = minX(start + prefix), let wrapX = minX(wrapped[1].lowerBound) else {
                    XCTFail("list hang \(label) position")
                    continue
                }
                let second = (storage.string as NSString).substring(
                    with: NSRange(location: wrapped[1].lowerBound, length: 1)
                )
                XCTAssertEqual(
                    wrapX,
                    textX,
                    accuracy: 1.5,
                    "list hang \(label) wrap \(wrapX) text \(textX) second \(second.debugDescription) indent \(style?.headIndent ?? -1)"
                )
                XCTAssertGreaterThanOrEqual(wrapped[1].lowerBound, start + prefix, "list hang \(label) marker wrapped")
                textColumns[label] = textX
            } else {
                XCTAssertEqual(style?.headIndent ?? -1, 0, accuracy: 0.01, "list hang prose indent")
                guard let firstX = minX(start), let wrapX = minX(wrapped[1].lowerBound) else {
                    XCTFail("list hang prose position")
                    continue
                }
                XCTAssertEqual(wrapX, firstX, accuracy: 1.5, "list hang prose wrap \(wrapX) first \(firstX)")
            }
        }

        if let dash = textColumns["dash"], let nested = textColumns["nested"], let deeper = textColumns["nested-deeper"] {
            XCTAssertGreaterThan(nested, dash + 2, "list hang nested \(nested) dash \(dash)")
            XCTAssertGreaterThan(deeper, nested + 2, "list hang deeper \(deeper) nested \(nested)")
        } else {
            XCTFail("list hang nested columns")
        }
        if let one = textColumns["ordered"], let two = textColumns["ordered-two"] {
            XCTAssertGreaterThan(two, one + 2, "list hang ordered \(one) \(two)")
        } else {
            XCTFail("list hang ordered columns")
        }
        if let dash = textColumns["dash"], let task = textColumns["task-open"] {
            XCTAssertGreaterThan(task, dash + 6, "list hang task \(task) dash \(dash)")
        } else {
            XCTFail("list hang task columns")
        }

        let fenceIndex = markers.count + 1
        let fenceRows = rows(at: fenceIndex)
        guard fenceRows.count > 1 else {
            XCTFail("list hang fence did not wrap")
            return
        }
        let fenceStart = starts[fenceIndex]
        let fenceLine = lines[fenceIndex]
        let fencePrefix = MarkdownTokenizer.listHangPrefixUTF16(fenceLine) ?? 0
        let fenceStyle = storage.attribute(.paragraphStyle, at: fenceStart, effectiveRange: nil) as? NSParagraphStyle
        XCTAssertEqual(fenceStyle?.headIndent ?? -1, 0, accuracy: 0.01, "list hang fence indent")
        guard let bulletX = minX(fenceStart),
              let textX = minX(fenceStart + fencePrefix),
              let wrapX = minX(fenceRows[1].lowerBound) else {
            XCTFail("list hang fence position")
            return
        }
        XCTAssertEqual(wrapX, bulletX, accuracy: 1.5, "list hang fence wrap \(wrapX) bullet \(bulletX)")
        XCTAssertGreaterThan(abs(wrapX - textX), 4, "list hang fence aligned with the text \(wrapX) \(textX)")
    }

    func testWrappedListMotionsStayOnScreenLines() {
        let words = Array(repeating: "alpha", count: 30).joined(separator: " ")
        let source = "- " + words
        let column: CGFloat = 220
        let harness = EditorHarness(
            text: source,
            size: NSSize(width: column + QuillMetrics.sideGutter * 2, height: 640),
            column: column
        )
        defer { harness.close() }
        let tv = harness.view
        tv.layoutSubtreeIfNeeded()
        tv.layoutAdapter.ensureFullLayout()
        let applied = tv.textContainer?.size.width ?? 0
        XCTAssertEqual(applied, column, accuracy: 0.5, "list motion column \(applied)")
        XCTAssertEqual(tv.string, source, "list motion rewrote the buffer")

        let screen = harness.engine.screen.screenLines(of: 0).filter { !$0.isGap }
        XCTAssertGreaterThan(screen.count, 1, "list motion did not wrap")
        guard screen.count > 1 else { return }
        let continuation = screen[1].range.lowerBound
        XCTAssertGreaterThan(continuation, MarkdownTokenizer.listHangPrefixUTF16(source) ?? 0)

        guard let storage = tv.textStorage,
              let style = storage.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle,
              let lm = tv.textLayoutManager,
              let prefix = MarkdownTokenizer.listHangPrefixUTF16(source),
              let textX = Probe.segmentUnion(lm, range: NSRange(location: prefix, length: 1))?.minX,
              let wrapX = Probe.segmentUnion(lm, range: NSRange(location: continuation, length: 1))?.minX
        else {
            XCTFail("list motion position")
            return
        }
        XCTAssertGreaterThan(style.headIndent, 1, "list motion indent")
        XCTAssertEqual(style.firstLineHeadIndent, 0, accuracy: 0.01, "list motion first line")
        XCTAssertEqual(wrapX, textX, accuracy: 1.5, "list motion wrap \(wrapX) text \(textX)")

        _ = tv.press("j")
        XCTAssertEqual(harness.engine.cursor, continuation, "list motion j")
        _ = tv.press("l")
        XCTAssertGreaterThan(harness.engine.cursor, continuation, "list motion l")
        _ = tv.press("0")
        XCTAssertEqual(harness.engine.cursor, continuation, "list motion 0")
        _ = tv.press("g0")
        XCTAssertEqual(harness.engine.cursor, 0, "list motion g0")
        _ = tv.press("k")
        XCTAssertEqual(harness.engine.cursor, 0, "list motion k")
        XCTAssertEqual(harness.engine.text, source, "list motion rewrote the buffer")

        _ = tv.press("r*")
        XCTAssertTrue(harness.engine.text.hasPrefix("* "), "list motion replace \(harness.engine.text.prefix(8))")
        tv.layoutSubtreeIfNeeded()
        tv.layoutAdapter.ensureFullLayout()
        let replaced = harness.engine.screen.screenLines(of: 0).filter { !$0.isGap }
        XCTAssertGreaterThan(replaced.count, 1, "list motion replace wrap")
        guard replaced.count > 1,
              let replacedPrefix = MarkdownTokenizer.listHangPrefixUTF16(harness.engine.text),
              let layout = tv.textLayoutManager,
              let replacedTextX = Probe.segmentUnion(layout, range: NSRange(location: replacedPrefix, length: 1))?.minX,
              let replacedWrapX = Probe.segmentUnion(layout, range: NSRange(location: replaced[1].range.lowerBound, length: 1))?.minX
        else {
            XCTFail("list motion replace position")
            return
        }
        XCTAssertEqual(replacedWrapX, replacedTextX, accuracy: 1.5, "list motion replace wrap \(replacedWrapX) text \(replacedTextX)")
        XCTAssertEqual(harness.engine.text.dropFirst(2), source.dropFirst(2), "list motion replace rewrote the item")
    }
}
