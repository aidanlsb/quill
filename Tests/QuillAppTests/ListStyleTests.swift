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
            if isList {
                guard let prefix else {
                    XCTFail("list hang \(label) prefix")
                    continue
                }
                XCTAssertEqual(
                    style?.firstLineHeadIndent ?? -1,
                    theme.listIndent,
                    accuracy: 0.01,
                    "list hang \(label) first line"
                )
                XCTAssertGreaterThan(style?.headIndent ?? 0, theme.listIndent + 1, "list hang \(label) indent")
                XCTAssertGreaterThan(
                    (style?.headIndent ?? 0) - (style?.firstLineHeadIndent ?? 0),
                    1,
                    "list hang \(label) hang"
                )
                XCTAssertGreaterThan(style?.paragraphSpacing ?? 0, 2, "list hang \(label) spacing")
                guard let markerX = minX(start),
                      let textX = minX(start + prefix),
                      let wrapX = minX(wrapped[1].lowerBound)
                else {
                    XCTFail("list hang \(label) position")
                    continue
                }
                XCTAssertEqual(markerX, theme.listIndent, accuracy: 1.5, "list hang \(label) gutter \(markerX)")
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
                XCTAssertEqual(style?.firstLineHeadIndent ?? -1, 0, accuracy: 0.01, "list hang prose first line")
                XCTAssertEqual(style?.headIndent ?? -1, 0, accuracy: 0.01, "list hang prose indent")
                XCTAssertEqual(style?.paragraphSpacing ?? -1, 0, accuracy: 0.01, "list hang prose spacing")
                guard let firstX = minX(start), let wrapX = minX(wrapped[1].lowerBound) else {
                    XCTFail("list hang prose position")
                    continue
                }
                XCTAssertEqual(wrapX, firstX, accuracy: 1.5, "list hang prose wrap \(wrapX) first \(firstX)")
                XCTAssertEqual(firstX, 0, accuracy: 1.5, "list hang prose gutter \(firstX)")
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
        XCTAssertEqual(fenceStyle?.firstLineHeadIndent ?? -1, 0, accuracy: 0.01, "list hang fence first line")
        XCTAssertEqual(fenceStyle?.headIndent ?? -1, 0, accuracy: 0.01, "list hang fence indent")
        XCTAssertEqual(fenceStyle?.paragraphSpacing ?? -1, 0, accuracy: 0.01, "list hang fence spacing")
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
        XCTAssertGreaterThan(style.headIndent, tv.theme.listIndent + 1, "list motion indent")
        XCTAssertEqual(style.firstLineHeadIndent, tv.theme.listIndent, accuracy: 0.01, "list motion first line")
        XCTAssertGreaterThan(style.paragraphSpacing, 2, "list motion spacing")
        XCTAssertEqual(wrapX, textX, accuracy: 1.5, "list motion wrap \(wrapX) text \(textX)")

        _ = tv.press("j")
        XCTAssertEqual(harness.engine.cursor, continuation, "list motion j")
        _ = tv.press("l")
        XCTAssertGreaterThan(harness.engine.cursor, continuation, "list motion l")
        _ = tv.press("0")
        XCTAssertEqual(harness.engine.cursor, continuation, "list motion 0")
        _ = tv.press("g0")
        XCTAssertEqual(harness.engine.cursor, 0, "list motion g0")
        _ = tv.press("l")
        XCTAssertEqual(harness.engine.cursor, 1, "list motion l marker")
        _ = tv.press("h")
        XCTAssertEqual(harness.engine.cursor, 0, "list motion h marker")
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

    func testListItemsAreVisuallyDistinctFromProse() {
        let source = [
            "plain paragraph sits flush",
            "- dash item",
            "* star item",
            "+ plus item",
            "1. numbered",
            "12. two-digit",
            "- [ ] open task",
            "- [x] done task",
            "  - nested",
            "    * deeper",
            "```",
            "- fenced bullet",
            "```",
        ].joined(separator: "\n")
        let light = QuillTheme.current(scheme: .light)
        let dark = QuillTheme.current(scheme: .dark)
        XCTAssertGreaterThan(Probe.colorDistance(light.listMarkerColor, light.textColor), 0.15, "list marker light")
        XCTAssertGreaterThan(Probe.colorDistance(dark.listMarkerColor, dark.textColor), 0.15, "list marker dark")
        XCTAssertGreaterThan(Probe.colorDistance(light.listMarkerColor, dark.listMarkerColor), 0.2, "list marker theme")
        XCTAssertGreaterThan(Probe.fontWeight(light.listMarkerFont), Probe.fontWeight(light.bodyFont) + 0.04, "list marker weight")
        XCTAssertGreaterThan(light.listIndent, 12, "list indent \(light.listIndent)")
        XCTAssertGreaterThan(light.listItemSpacing, 3, "list spacing \(light.listItemSpacing)")
        XCTAssertEqual(light.listIndent, CGFloat(QuillMetrics.defaultFontSize) * QuillMetrics.listIndentEm, accuracy: 0.01, "list indent em")

        let width: CGFloat = 280
        let tv = NSTextView(usingTextLayoutManager: true)
        tv.isHorizontallyResizable = false
        tv.isVerticallyResizable = true
        tv.textContainerInset = .zero
        tv.textContainer?.lineFragmentPadding = 0
        tv.textContainer?.widthTracksTextView = false
        tv.textContainer?.heightTracksTextView = false
        tv.textContainer?.size = NSSize(width: width, height: 8_000)
        tv.frame = NSRect(x: 0, y: 0, width: width, height: 2_000)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: 2_000),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
        window.contentView = tv
        tv.frame = window.contentView?.bounds ?? tv.frame
        tv.textContainer?.size = NSSize(width: width, height: 8_000)
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }

        tv.string = source
        let doc = MarkdownTokenizer(text: source)
        guard let storage = tv.textStorage else {
            XCTFail("list style storage")
            return
        }
        MarkdownStyler.restyle(storage, theme: light, spans: doc.spans, tableColumnWidth: width)
        XCTAssertEqual(storage.string, source, "list style rewrote the buffer")
        tv.layoutSubtreeIfNeeded()
        guard let lm = tv.textLayoutManager else {
            XCTFail("list style layout")
            return
        }
        lm.ensureLayout(for: lm.documentRange)

        func minX(_ utf16: Int) -> CGFloat? {
            Probe.segmentUnion(lm, range: NSRange(location: utf16, length: 1))?.minX
        }

        func markerIndex(_ line: String, at start: Int) -> Int {
            var offset = 0
            for ch in line {
                if ch == " " || ch == "\t" {
                    offset += String(ch).utf16.count
                    continue
                }
                return start + offset
            }
            return start
        }

        let ns = source as NSString
        var cursor = 0
        var proseX: CGFloat?
        var dashX: CGFloat?
        var nestedX: CGFloat?
        var deeperX: CGFloat?
        while cursor < ns.length {
            let line = ns.lineRange(for: NSRange(location: cursor, length: 0))
            let content = NSRange(
                location: line.location,
                length: max(0, line.length - (ns.substring(with: line).hasSuffix("\n") ? 1 : 0))
            )
            let text = ns.substring(with: content)
            let start = content.location
            let style = storage.attribute(.paragraphStyle, at: start, effectiveRange: nil) as? NSParagraphStyle
            let isFence = text.hasPrefix("```") || text.hasPrefix("- fenced")
            let isList = MarkdownTokenizer.listHangPrefixUTF16(text) != nil && !isFence
            if text.hasPrefix("plain") {
                XCTAssertEqual(style?.firstLineHeadIndent ?? -1, 0, accuracy: 0.01, "list style prose first line")
                XCTAssertEqual(style?.headIndent ?? -1, 0, accuracy: 0.01, "list style prose indent")
                XCTAssertEqual(style?.paragraphSpacing ?? -1, 0, accuracy: 0.01, "list style prose spacing")
                proseX = minX(start)
                let color = storage.attribute(.foregroundColor, at: start, effectiveRange: nil) as? NSColor
                XCTAssertTrue(Probe.sameColor(color, light.textColor), "list style prose color")
            } else if isList {
                XCTAssertEqual(style?.firstLineHeadIndent ?? -1, light.listIndent, accuracy: 0.01, "list style \(text) first line")
                XCTAssertGreaterThan(style?.headIndent ?? 0, light.listIndent + 1, "list style \(text) hang")
                XCTAssertEqual(style?.paragraphSpacing ?? 0, light.listItemSpacing, accuracy: 0.2, "list style \(text) spacing")
                let glyph = markerIndex(text, at: start)
                let color = storage.attribute(.foregroundColor, at: glyph, effectiveRange: nil) as? NSColor
                let font = storage.attribute(.font, at: glyph, effectiveRange: nil) as? NSFont
                XCTAssertTrue(Probe.sameColor(color, light.listMarkerColor), "list style \(text) marker color")
                XCTAssertGreaterThan(
                    Probe.fontWeight(font ?? light.bodyFont),
                    Probe.fontWeight(light.bodyFont) + 0.04,
                    "list style \(text) marker weight"
                )
                let bodyAt = start + (MarkdownTokenizer.listHangPrefixUTF16(text) ?? 0)
                if bodyAt < NSMaxRange(content) {
                    let bodyColor = storage.attribute(.foregroundColor, at: bodyAt, effectiveRange: nil) as? NSColor
                    let bodyFont = storage.attribute(.font, at: bodyAt, effectiveRange: nil) as? NSFont
                    XCTAssertTrue(Probe.sameColor(bodyColor, light.textColor), "list style \(text) body color")
                    XCTAssertEqual(bodyFont?.pointSize, light.bodyFont.pointSize, accuracy: 0.2, "list style \(text) body size")
                }
                guard let x = minX(start) else {
                    XCTFail("list style \(text) position")
                    cursor = NSMaxRange(line)
                    continue
                }
                XCTAssertEqual(x, light.listIndent, accuracy: 1.5, "list style \(text) gutter \(x)")
                if text.hasPrefix("- dash") { dashX = minX(glyph) }
                if text.hasPrefix("  - ") { nestedX = minX(glyph) }
                if text.hasPrefix("    * ") { deeperX = minX(glyph) }
            } else if text.hasPrefix("- fenced") {
                XCTAssertEqual(style?.firstLineHeadIndent ?? -1, 0, accuracy: 0.01, "list style fence first line")
                XCTAssertEqual(style?.headIndent ?? -1, 0, accuracy: 0.01, "list style fence indent")
                let color = storage.attribute(.foregroundColor, at: start, effectiveRange: nil) as? NSColor
                XCTAssertFalse(Probe.sameColor(color, light.listMarkerColor), "list style fence marker")
            }
            cursor = NSMaxRange(line)
        }

        guard let proseX, let dashX, let nestedX, let deeperX else {
            XCTFail("list style columns prose \(String(describing: proseX)) dash \(String(describing: dashX)) nested \(String(describing: nestedX)) deeper \(String(describing: deeperX))")
            return
        }
        XCTAssertEqual(proseX, 0, accuracy: 1.5, "list style prose gutter \(proseX)")
        XCTAssertGreaterThan(dashX, proseX + 8, "list style dash \(dashX) prose \(proseX)")
        XCTAssertGreaterThan(nestedX, dashX + 2, "list style nested \(nestedX) dash \(dashX)")
        XCTAssertGreaterThan(deeperX, nestedX + 2, "list style deeper \(deeperX) nested \(nestedX)")

        MarkdownStyler.restyle(storage, theme: dark, spans: doc.spans, tableColumnWidth: width)
        XCTAssertEqual(storage.string, source, "list style dark rewrote the buffer")
        let dash = (source as NSString).range(of: "- dash")
        XCTAssertNotEqual(dash.location, NSNotFound)
        let darkColor = storage.attribute(.foregroundColor, at: dash.location, effectiveRange: nil) as? NSColor
        XCTAssertTrue(Probe.sameColor(darkColor, dark.listMarkerColor), "list style dark marker")
        let darkStyle = storage.attribute(.paragraphStyle, at: dash.location, effectiveRange: nil) as? NSParagraphStyle
        XCTAssertEqual(darkStyle?.firstLineHeadIndent ?? -1, dark.listIndent, accuracy: 0.01, "list style dark first line")
        XCTAssertGreaterThan(darkStyle?.paragraphSpacing ?? 0, 2, "list style dark spacing")
    }
}
