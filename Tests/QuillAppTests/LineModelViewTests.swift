import AppKit
import QuillText
import QuillVim
import XCTest
@testable import Quill

@MainActor
extension Probe {
    static func checkMotionModel(engine: Engine, tv: VimTextView, failures: Failures) {
        let text = motionDocument.joined(separator: "\n")
        guard let window = tv.window, let scroll = tv.enclosingScrollView else {
            failures.append("motion model: text view has no window")
            return
        }
        let original = scroll.frame.size
        defer {
            tv.columnWidth = 640
            resizeEditor(window, scroll: scroll, width: original.width, height: original.height)
            tv.updateInsets()
        }
        // The side gutters cap the column at the window width minus 256pt.
        for (label, column) in [("narrow", CGFloat(160)), ("wide", CGFloat(600))] {
            resizeEditor(window, scroll: scroll, width: column + QuillMetrics.sideGutter * 2 + 80, height: original.height)
            tv.columnWidth = column
            tv.updateInsets()
            let applied = tv.textContainer?.size.width ?? 0
            check(abs(applied - column) < 0.5, "\(label) column is \(applied) not \(column)", failures: failures)
            engine.load(text: text)
            tv.reload()
            tv.layoutSubtreeIfNeeded()
            tv.layoutAdapter.ensureFullLayout()
            let rows = drawnRows(tv)
            if label == "narrow" {
                check(
                    rows.count > motionDocument.count + 3,
                    "narrow column drew \(rows.count) rows for \(motionDocument.count) lines",
                    failures: failures
                )
                fputs(probeLineFragmentIndexing(tv) + "\n", stderr)
            } else {
                check(
                    rows.count == motionDocument.count,
                    "wide column drew \(rows.count) rows for \(motionDocument.count) lines",
                    failures: failures
                )
                checkWideColumnLandings(engine: engine, tv: tv, failures: failures)
            }
            checkVerticalAgainstRows(engine: engine, tv: tv, rows: rows, label: label, failures: failures)
            checkHorizontalWalk(engine: engine, tv: tv, label: label, failures: failures)
        }
    }

    /// Hand-written (line, UTF-16 column) landings for `8l` then `j` down and `k` up
    /// when nothing wraps. Display column 8 stays column 8 across a 32pt heading,
    /// bold, mono table cells, an emoji (two cells), and a tab (four cells).
    static func checkWideColumnLandings(engine: Engine, tv: VimTextView, failures: Failures) {
        let want = [(0, 8), (1, 8), (2, 8), (3, 4), (4, 0), (5, 8), (6, 8), (7, 8), (8, 8), (9, 8), (10, 5), (11, 8)]
        _ = tv.press("gg08l")
        tv.reload()
        expectCaret(engine, want[0], label: "wide start", failures: failures)
        for index in 1..<want.count {
            _ = tv.press("j")
            expectCaret(engine, want[index], label: "wide j\(index)", failures: failures)
        }
        for index in stride(from: want.count - 2, through: 0, by: -1) {
            _ = tv.press("k")
            expectCaret(engine, want[index], label: "wide k\(index)", failures: failures)
        }
        _ = tv.press("5j")
        tv.reload()
        expectCaret(engine, want[5], label: "wide 5j", failures: failures)
        _ = tv.press("$")
        expectCaret(engine, (5, utf16Length(motionDocument[5]) - 1), label: "wide $", failures: failures)
        _ = tv.press("j")
        expectCaret(engine, (6, utf16Length(motionDocument[6]) - 1), label: "wide $j", failures: failures)
        _ = tv.press("2k")
        expectCaret(engine, (4, 0), label: "wide $2k on the empty line", failures: failures)
        _ = tv.press("k")
        expectCaret(engine, (3, 4), label: "wide $k", failures: failures)
    }

    static func checkVerticalAgainstRows(
        engine: Engine,
        tv: VimTextView,
        rows: [Range<Int>],
        label: String,
        failures: Failures
    ) {
        let ns = tv.string as NSString
        let lines = LineIndex(tv.string)
        guard !rows.isEmpty else {
            failures.append("\(label) no rows")
            return
        }
        func rowIndex(of offset: Int) -> Int? {
            rows.firstIndex { $0.contains(offset) } ?? rows.lastIndex { $0.upperBound == offset }
        }
        func cells(_ index: Int) -> [OracleCell] {
            oracleCells(ns, row: rows[index], lineStart: lines.bufferLine(containing: rows[index].lowerBound).start)
        }
        func landing(_ index: Int, want: Int?) -> Int {
            let row = cells(index)
            guard let last = row.last else { return rows[index].lowerBound }
            guard let want else { return last.offset }
            return row.first { want < $0.end }?.offset ?? last.offset
        }
        func describe(_ offset: Int) -> String {
            let position = lines.position(of: offset)
            return "\(position.line),\(position.utf16Column) (\(offset))"
        }
        func walk(_ key: Character, from start: Int, want: Int?, tag: String) -> Int? {
            var current = start
            while true {
                let result = tv.press(String(key))
                let edge = key == "j" ? rows.count - 1 : 0
                if current == edge {
                    check(result.beep, "\(label) \(tag) \(key) past row \(edge) moved to \(describe(engine.cursor))", failures: failures)
                    return current
                }
                current += key == "j" ? 1 : -1
                let expected = landing(current, want: want)
                if engine.cursor != expected {
                    failures.append(
                        "\(label) \(tag) \(key) onto row \(current) \(rows[current]) landed \(describe(engine.cursor)) want \(describe(expected)) for column \(want.map(String.init) ?? "end")"
                    )
                    return nil
                }
            }
        }

        _ = tv.press("gg08l")
        tv.reload()
        guard let start = rowIndex(of: engine.cursor),
              let want = cells(start).first(where: { $0.offset == engine.cursor })?.start else {
            failures.append("\(label) start \(describe(engine.cursor)) is on no drawn row")
            return
        }
        guard let bottom = walk("j", from: start, want: want, tag: "column \(want)"),
              walk("k", from: bottom, want: want, tag: "column \(want)") != nil else { return }

        _ = tv.press("$")
        tv.reload()
        check(engine.cursor == landing(0, want: nil), "\(label) $ landed \(describe(engine.cursor))", failures: failures)
        guard let end = walk("j", from: 0, want: nil, tag: "$"), walk("k", from: end, want: nil, tag: "$") != nil else { return }

        _ = tv.press("0")
        let counted = min(rows.count - 1, 5)
        _ = tv.press("5j")
        tv.reload()
        check(engine.cursor == landing(counted, want: 0), "\(label) 5j landed \(describe(engine.cursor)) want \(describe(landing(counted, want: 0)))", failures: failures)
        _ = tv.press("0")
        check(engine.cursor == rows[counted].lowerBound, "\(label) 0 landed \(describe(engine.cursor)) want row start \(rows[counted].lowerBound)", failures: failures)
    }

    static func checkHorizontalWalk(engine: Engine, tv: VimTextView, label: String, failures: Failures) {
        let ns = tv.string as NSString
        let lines = LineIndex(tv.string)
        for index in [0, 1, 5, 8, 9, 10] {
            let line = lines.line(index)
            var expected: [Int] = []
            var at = line.start
            for character in ns.substring(with: NSRange(location: line.start, length: line.content.count)) {
                expected.append(at)
                at += character.utf16.count
            }
            engine.moveCursor(to: line.start)
            tv.reload()
            var previous: NSRect?
            var broke = false
            for (step, offset) in expected.enumerated() {
                if step > 0 {
                    let result = tv.press("l")
                    if result.beep || engine.cursor != offset {
                        failures.append("\(label) line \(index) l step \(step) went to \(engine.cursor) want \(offset)")
                        broke = true
                        break
                    }
                }
                let caret = tv.renderedCaretRect()
                guard let glyph = segmentFrame(tv, utf16: offset) else {
                    failures.append("\(label) line \(index) no text segment at \(offset)")
                    broke = true
                    break
                }
                if abs(caret.minX - glyph.minX) > 1 || caret.midY < glyph.minY - 2 || caret.midY > glyph.maxY + 2 {
                    failures.append("\(label) line \(index) offset \(offset) caret \(caret) is not on its glyph \(glyph)")
                    broke = true
                    break
                }
                if let previous, abs(previous.midY - caret.midY) < 1, caret.minX <= previous.minX {
                    failures.append("\(label) line \(index) offset \(offset) caret x \(caret.minX) did not advance from \(previous.minX)")
                    broke = true
                    break
                }
                previous = caret
            }
            if broke { continue }
            let past = tv.press("l")
            check(past.beep && engine.cursor == expected.last, "\(label) line \(index) l crossed the line end to \(engine.cursor)", failures: failures)
            for offset in expected.reversed().dropFirst() {
                _ = tv.press("h")
                if engine.cursor != offset {
                    failures.append("\(label) line \(index) h went to \(engine.cursor) want \(offset)")
                    break
                }
            }
            let before = tv.press("h")
            check(before.beep && engine.cursor == line.start, "\(label) line \(index) h crossed the line start to \(engine.cursor)", failures: failures)
        }
    }

    /// Text-view rect of the grapheme at `utf16`, from TextKit's text segments.
}

final class LineModelViewTests: QuillAppTestCase {
    @MainActor
    func testMotionModel() {
        let failures = Failures()
        let text = Probe.motionDocument.joined(separator: "\n")
        let engine = Engine(text: text)
        let frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        let hosted = VimTextView.host(engine: engine, frame: frame)
        let window = NSWindow(
            contentRect: frame,
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        window.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
        window.contentView = hosted.scroll
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        hosted.view.layoutSubtreeIfNeeded()
        Probe.checkMotionModel(engine: engine, tv: hosted.view, failures: failures)
    }
}
