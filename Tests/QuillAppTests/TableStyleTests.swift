import AppKit
import QuillMarkdown
import QuillVim
import XCTest
@testable import Quill

@MainActor
extension Probe {
    static func checkTables(failures: Failures) {
        let ragged = "| A | Q |\n| :- | -: |\n| c | 1 |\n| d | 12 |"
        let block = MarkdownTables.blocks(in: ragged).first
        let short = block?.rows.dropFirst(2).first?.cells.last

        let light = QuillTheme.current(scheme: .light)
        let dark = QuillTheme.current(scheme: .dark)
        check(light.tableBackground.alphaComponent > 0.02, "table background light", failures: failures)
        check(dark.tableBackground.alphaComponent > 0.02, "table background dark", failures: failures)
        check(
            abs(light.tableBackground.alphaComponent - dark.tableBackground.alphaComponent) > 0.001
                || brightness(light.tableBackground) != brightness(dark.tableBackground),
            "table background theme",
            failures: failures
        )
        check(light.tableHeaderRule.alphaComponent > light.tableRowRule.alphaComponent, "table rule weight", failures: failures)

        let storage = NSTextStorage(string: ragged)
        MarkdownStyler.restyle(storage, theme: light, spans: [])
        guard let painted = block, let pipe = painted.rows[0].pipes.first, let header = painted.rows[0].cells.first else {
            failures.append("table detect header")
            return
        }
        let headerFont = storage.attribute(.font, at: header.text.lowerBound, effectiveRange: nil) as? NSFont
        check(headerFont?.isFixedPitch == true, "table header pitch", failures: failures)
        check(fontWeight(headerFont ?? light.bodyFont) >= 0.28, "table header weight", failures: failures)
        let body = painted.rows[2].cells[0]
        let bodyFont = storage.attribute(.font, at: body.text.lowerBound, effectiveRange: nil) as? NSFont
        check(bodyFont?.isFixedPitch == true, "table body pitch", failures: failures)
        check(fontWeight(bodyFont ?? light.bodyFont) < 0.2, "table body weight", failures: failures)
        check(
            sameColor(storage.attribute(.foregroundColor, at: pipe.lowerBound, effectiveRange: nil) as? NSColor, light.syntaxColor),
            "table pipe",
            failures: failures
        )
        check(
            sameColor(storage.attribute(.backgroundColor, at: body.text.lowerBound, effectiveRange: nil) as? NSColor, light.tableBackground),
            "table background",
            failures: failures
        )
        let headerUnderline = storage.attribute(.underlineStyle, at: header.text.lowerBound, effectiveRange: nil) as? NSNumber
        let bodyUnderline = storage.attribute(.underlineStyle, at: body.text.lowerBound, effectiveRange: nil) as? NSNumber
        check(headerUnderline?.intValue == NSUnderlineStyle.single.rawValue, "table rule header", failures: failures)
        check(bodyUnderline?.intValue == NSUnderlineStyle.single.rawValue, "table rule row", failures: failures)
        let para = storage.attribute(.paragraphStyle, at: body.text.lowerBound, effectiveRange: nil) as? NSParagraphStyle
        check(para?.lineBreakMode == .byWordWrapping, "table rows wrap", failures: failures)
        if let pipeIndex = short?.precedingPipe {
            let kern = (storage.attribute(.kern, at: pipeIndex, effectiveRange: nil) as? NSNumber)?.doubleValue ?? 0
            check(kern > 0.5, "table align kern \(kern)", failures: failures)
        } else {
            failures.append("table align kern")
        }

        let wide = String(repeating: "b", count: 80)
        let sample = "| A | \(wide) |\n| - | - |\n| c | d |"
        let measured = (sample as NSString).size(withAttributes: [.font: light.monoFont]).width
        check(measured > 140, "table wrap sample \(measured)", failures: failures)
        let tv = NSTextView(usingTextLayoutManager: true)
        tv.isHorizontallyResizable = false
        tv.isVerticallyResizable = true
        tv.textContainerInset = .zero
        tv.textContainer?.lineFragmentPadding = 0
        tv.textContainer?.widthTracksTextView = false
        tv.textContainer?.heightTracksTextView = false
        tv.textContainer?.size = NSSize(width: 80, height: 10_000)
        tv.frame = NSRect(x: 0, y: 0, width: 80, height: 240)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 80, height: 240),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = tv
        tv.frame = window.contentView?.bounds ?? tv.frame
        tv.textContainer?.size = NSSize(width: 80, height: 10_000)
        tv.string = sample
        if let textStorage = tv.textStorage {
            MarkdownStyler.restyle(textStorage, theme: light, spans: [])
        }
        tv.layoutSubtreeIfNeeded()
        let fragments = lineFragmentCount(tv)
        check(fragments > 3, "wide table row did not wrap: \(fragments) fragments", failures: failures)
        if let overflow = widestInk(tv, limit: 80) {
            failures.append("table row ink reaches \(overflow) past the 80pt column")
        }

        check(QuillConfig.default.loadNotice == nil, "table format config", failures: failures)
        if let decoded = try? QuillConfig.decode(Data("formatTablesOnInsertLeave = true\n".utf8)) {
            check(
                decoded.loadNotice == "formatTablesOnInsertLeave is ignored; use :TableFormat",
                "table format config on",
                failures: failures
            )
        } else {
            failures.append("table format config on")
        }
        check(
            (try? QuillConfig.decode(Data("formatTablesOnInsertLeave = \"yes\"\n".utf8))) == nil,
            "table format config name",
            failures: failures
        )
    }

    /// A table below the first screen is unstyled until the clip scrolls onto it.
    /// Editing a cell then updates kern on the other visible rows.
    static func checkTableViewport(failures: Failures) {
        let prose = (0..<100).map { "Line \($0) plain words here.\n" }.joined()
        // The edited cell has to be the widest in its column. A wider header
        // or rule keeps the short cell's pad the same after one extra character.
        let table = "| N | Q |\n| - | -: |\n| c | 1 |\n| d | 12 |\n"
        let text = prose + table
        let engine = Engine(text: text)
        let frame = NSRect(x: 0, y: 0, width: 640, height: 280)
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
        defer { window.orderOut(nil) }
        tv.reload()
        tv.layoutSubtreeIfNeeded()

        guard let header = text.range(of: "| N |"), let storage = tv.textStorage else {
            failures.append("table viewport missing")
            return
        }
        let pipe = text.utf16.distance(from: text.startIndex, to: header.lowerBound)
        let theme = tv.theme
        check(
            !sameColor(storage.attribute(.foregroundColor, at: pipe, effectiveRange: nil) as? NSColor, theme.syntaxColor),
            "table viewport styled early",
            failures: failures
        )

        let caretFont = tv.font ?? theme.bodyFont
        let row = max(1, (caretFont.ascender - caretFont.descender) * theme.lineHeight)
        let line = engine.buffer.lineIndex(containing: pipe)
        let originY = tv.textContainerOrigin.y + CGFloat(line) * row - 24
        let clip = scroll.contentView
        clip.setBoundsOrigin(NSPoint(x: 0, y: max(0, originY)))
        scroll.reflectScrolledClipView(clip)
        tv.layoutSubtreeIfNeeded()

        check(
            sameColor(storage.attribute(.foregroundColor, at: pipe, effectiveRange: nil) as? NSColor, theme.syntaxColor),
            "table viewport pipe",
            failures: failures
        )
        guard let painted = MarkdownTables.blocks(in: text).first,
              let name = painted.rows.first?.cells.first?.text.lowerBound,
              let shortPipe = painted.rows.dropFirst(2).first?.cells.last?.precedingPipe,
              let wide = painted.rows.last?.cells.last?.text.upperBound
        else {
            failures.append("table viewport detect")
            return
        }
        let headerFont = storage.attribute(.font, at: name, effectiveRange: nil) as? NSFont
        check(headerFont?.isFixedPitch == true, "table viewport header pitch", failures: failures)
        check(fontWeight(headerFont ?? theme.bodyFont) >= 0.28, "table viewport header", failures: failures)
        let kern = (storage.attribute(.kern, at: shortPipe, effectiveRange: nil) as? NSNumber)?.doubleValue ?? 0
        check(kern > 0.5, "table viewport kern \(kern)", failures: failures)
        let beforePad = painted.rows.dropFirst(2).first?.cells.last?.leadingPad ?? -1

        engine.moveCursor(to: wide)
        engine.mode = .insert
        _ = tv.press("3")
        let afterPad = MarkdownTables.blocks(in: engine.text).first?.rows.dropFirst(2).first?.cells.last?.leadingPad ?? -1
        check(afterPad > beforePad, "table edit pad \(beforePad) \(afterPad)", failures: failures)
        let kernAfter = (storage.attribute(.kern, at: shortPipe, effectiveRange: nil) as? NSNumber)?.doubleValue ?? 0
        check(kernAfter > kern + 0.4, "table edit kern \(kern) \(kernAfter) pad \(beforePad) \(afterPad)", failures: failures)
    }

    static func checkNoHorizontalOverflow(failures: Failures) {
        let lines = [
            "# A heading that is long enough to wrap in a narrow column",
            "",
            "| a | b |",
            "| - | -: |",
            "| x | 1 |",
            "| y | 123 |",
            "",
            "| Name | Description | Qty |",
            "| :--- | :--- | ---: |",
            "| key | " + String(repeating: "b", count: 90) + " | 1 |",
            "| k | short | " + String(repeating: "9", count: 30) + " |",
            "",
            "| Mid | Notes |",
            "| --- | --- |",
            "| a | " + String(repeating: "n", count: 40) + " |",
            "| bb | c |",
            "",
            "```",
            "let url = \"https://example.com/" + String(repeating: "a", count: 70) + "\"",
            "```",
            "",
            "https://example.com/" + String(repeating: "p", count: 80),
            "",
            String(repeating: "word", count: 30),
            "",
            "last line",
        ]
        let text = lines.joined(separator: "\n")
        let engine = Engine(text: text)
        let frame = NSRect(x: 0, y: 0, width: 360, height: 300)
        let hosted = VimTextView.host(engine: engine, frame: frame)
        let scroll = hosted.scroll
        let tv = hosted.view
        tv.columnWidth = 640
        let window = NSWindow(
            contentRect: frame,
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentView = scroll
        window.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        tv.applyTheme(QuillTheme.current(), focus: false)
        tv.reload()
        tv.layoutSubtreeIfNeeded()
        tv.layoutAdapter.ensureFullLayout()
        let column = tv.textContainer?.size.width ?? 0
        let clip = scroll.contentView
        check(column > 50 && column < clip.bounds.width, "overflow column \(column) clip \(clip.bounds.width)", failures: failures)

        var caretFailures = 0
        func caretOnScreen(_ label: String) {
            let caret = tv.renderedCaretRect()
            let visible = clip.documentVisibleRect.insetBy(dx: -0.5, dy: -0.5)
            let edge = tv.textContainerOrigin.x + (tv.textContainer?.size.width ?? 0)
            var problem: String?
            if !visible.contains(caret) {
                problem = "outside the visible \(clip.documentVisibleRect)"
            } else if caret.maxX > edge + 1 {
                problem = "past the column edge \(edge)"
            } else if abs(clip.bounds.origin.x) > 0.5 {
                problem = "with the clip scrolled sideways to \(clip.bounds.origin.x)"
            }
            guard let problem else { return }
            caretFailures += 1
            if caretFailures <= 6 {
                let position = engine.buffer.position(of: engine.cursor)
                failures.append(
                    "overflow: caret \(caret) after \(label) at \(position.line):\(position.utf16Column) is \(problem); "
                        + "view \(tv.frame.size) column \(tv.textContainer?.size.width ?? 0)"
                )
            }
        }

        for (index, line) in lines.enumerated() where line.count > 30 {
            _ = tv.press(":\(index + 1)<CR>")
            tv.reload()
            for keys in ["$", "g$", "0"] {
                _ = tv.press(keys)
                caretOnScreen(":\(index + 1) \(keys)")
            }
            var steps = 0
            while steps < 400 {
                let before = engine.cursor
                _ = tv.press("l")
                if engine.cursor == before { break }
                steps += 1
                caretOnScreen(":\(index + 1) l×\(steps)")
            }
        }

        _ = tv.press("gg")
        tv.reload()
        var rows = 0
        for direction in ["j", "k"] {
            var steps = 0
            while steps < 600 {
                let before = engine.cursor
                _ = tv.press(direction)
                if engine.cursor == before { break }
                steps += 1
                caretOnScreen("\(direction)×\(steps)")
            }
            if direction == "j" { rows = steps }
        }
        check(rows > lines.count + 10, "overflow: j visited \(rows) rows; long lines did not wrap", failures: failures)
        check(engine.cursor == 0, "overflow: k did not return to the top (cursor \(engine.cursor))", failures: failures)
        if caretFailures > 6 {
            failures.append("overflow: \(caretFailures - 6) more caret positions off screen")
        }

        _ = tv.press("G")
        tv.reload()
        caretOnScreen("G")

        tv.layoutAdapter.ensureFullLayout()
        if let overflow = widestInk(tv, limit: column) {
            failures.append("overflow: ink reaches \(overflow)pt past the \(column)pt column")
        }
        let used = tv.textLayoutManager?.usageBoundsForTextContainer ?? .zero
        check(used.maxX <= column + 0.5, "overflow: laid-out width \(used.maxX) is wider than the \(column)pt column", failures: failures)
        check(tv.frame.width <= clip.bounds.width + 0.5, "overflow: view \(tv.frame.width) wider than clip \(clip.bounds.width)", failures: failures)
        check(abs(clip.bounds.origin.x) < 0.5, "overflow: clip scrolled sideways to \(clip.bounds.origin.x)", failures: failures)

        guard let storage = tv.textStorage else { return }
        let tables = MarkdownTables.blocks(in: text)
        guard tables.count == 3 else {
            failures.append("overflow: found \(tables.count) tables")
            return
        }
        func widestKern(_ range: Range<Int>) -> CGFloat {
            var widest: CGFloat = 0
            let span = NSRange(location: range.lowerBound, length: range.count)
            storage.enumerateAttribute(.kern, in: span, options: []) { value, _, _ in
                widest = max(widest, CGFloat((value as? NSNumber)?.doubleValue ?? 0))
            }
            return widest
        }
        check(widestKern(tables[0].range) > 0.5, "overflow: the small table lost its alignment", failures: failures)
        check(
            widestKern(tables[1].range) < 0.5,
            "overflow: the wide table is still padded (kern \(widestKern(tables[1].range))); it cannot align within \(column)pt",
            failures: failures
        )
        check(widestKern(0..<storage.length) < column, "overflow: a kern is wider than the column", failures: failures)

        let mid = tables[2]
        let advance = MarkdownStyler.monoAdvance(tv.theme.monoFont)
        func midAlignment(_ label: String, expectPadded: Bool) {
            let width = tv.textContainer?.size.width ?? 0
            let fits = mid.alignsWithin(columns: MarkdownStyler.fitColumns(width: width, advance: advance))
            check(
                fits == expectPadded,
                "overflow \(label): a \(mid.alignedColumns)-cell table at \(width)pt; pick a width where it \(expectPadded ? "fits" : "does not fit")",
                failures: failures
            )
            let padded = widestKern(mid.range) > 0.5
            check(padded == expectPadded, "overflow \(label): mid table padded \(padded) at \(width)pt", failures: failures)
            if let overflow = widestInk(tv, limit: width) {
                failures.append("overflow \(label): ink reaches \(overflow)pt past the \(width)pt column")
            }
            caretOnScreen(label)
        }
        midAlignment("narrow", expectPadded: false)
        let midLine = engine.buffer.lineIndex(containing: mid.range.lowerBound)
        _ = tv.press(":\(midLine + 1)<CR>")
        tv.reload()
        caretOnScreen(":\(midLine + 1)")
        resizeEditor(window, scroll: scroll, width: 900, height: 300)
        midAlignment("widened", expectPadded: true)
        tv.viewDidEndLiveResize()
        caretOnScreen("widened, live resize ended")
        resizeEditor(window, scroll: scroll, width: 360, height: 300)
        midAlignment("narrowed", expectPadded: false)
        tv.viewDidEndLiveResize()
        caretOnScreen("narrowed, live resize ended")
    }

}

final class TableStyleTests: QuillAppTestCase {
    @MainActor
    func testTableStyle() {
        let failures = Failures()
        Probe.checkTables(failures: failures)
    }

    @MainActor
    func testTableViewport() {
        let failures = Failures()
        Probe.checkTableViewport(failures: failures)
    }

    @MainActor
    func testNoHorizontalOverflow() {
        let failures = Failures()
        Probe.checkNoHorizontalOverflow(failures: failures)
    }
}
