import AppKit
import Foundation
import QuillVim

/// In-process check for the behaviors Linux tests cannot see: caret cell size,
/// real scrolling, and oil-style directory buffers wired through `AppModel`.
/// Run with `QUILL_SMOKE=1`. Exits the process.
enum AppSmoke {
    @MainActor private static var started = false

    @MainActor
    static func runIfRequested(model: AppModel) {
        guard !started else { return }
        guard ProcessInfo.processInfo.environment["QUILL_SMOKE"] == "1" else { return }
        started = true
        _ = model
        var failures: [String] = []
        checkDefaultType(failures: &failures)
        checkCaretAndScroll(failures: &failures)
        checkDirectory(failures: &failures)
        if failures.isEmpty {
            fputs("quill smoke passed\n", stderr)
            exit(0)
        }
        for failure in failures {
            fputs("FAIL \(failure)\n", stderr)
        }
        exit(1)
    }

    @MainActor
    private static func check(_ condition: Bool, _ message: String, failures: inout [String]) {
        if !condition { failures.append(message) }
    }

    @MainActor
    private static func checkDefaultType(failures: inout [String]) {
        let theme = QuillTheme.current()
        let body = theme.bodyFont.pointSize
        check(abs(body - QuillMetrics.defaultFontSize) < 0.2, "default body font \(body)", failures: &failures)
        check(
            theme.headingFonts.count == QuillMetrics.headingScale.count,
            "heading scale count \(theme.headingFonts.count)",
            failures: &failures
        )
        for (font, scale) in zip(theme.headingFonts, QuillMetrics.headingScale) {
            let expected = CGFloat(QuillMetrics.defaultFontSize) * scale
            check(
                abs(font.pointSize - expected) < 0.6,
                "heading scale \(font.pointSize) expected \(expected)",
                failures: &failures
            )
        }
        check(abs(theme.lineHeight - 1.5) < 0.01, "line height \(theme.lineHeight)", failures: &failures)
        check(QuillConfig.default.fontSize == 16, "default body font config \(QuillConfig.default.fontSize)", failures: &failures)
        check(QuillConfig.default.columnWidth == 70, "column default \(QuillConfig.default.columnWidth)", failures: &failures)
        check(QuillMetrics.fontSize(nil) == 16, "default body font missing", failures: &failures)
        check(QuillMetrics.fontSize(9) == 16, "default body font low", failures: &failures)
        check(QuillMetrics.fontSize(33) == 16, "default body font high", failures: &failures)
        check(QuillMetrics.fontSize(18) == 18, "font size 18", failures: &failures)
        check(QuillMetrics.sideGutter >= 120, "side gutter \(QuillMetrics.sideGutter)", failures: &failures)
        check(QuillMetrics.verticalInset >= 120, "vertical inset \(QuillMetrics.verticalInset)", failures: &failures)
        let tight = QuillMetrics.columnSpan(width: 700, column: 560)
        check(tight.inset >= QuillMetrics.sideGutter, "side gutter \(tight.inset)", failures: &failures)
        check(
            tight.inset * 2 + tight.column <= 700.5,
            "side gutter overflow \(tight.inset) \(tight.column)",
            failures: &failures
        )
    }

    @MainActor
    private static func checkCaretAndScroll(failures: inout [String]) {
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 640, height: 400))
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        let tv = VimTextView(usingTextLayoutManager: true)
        tv.commonInit()
        let engine = Engine(text: "")
        tv.engine = engine
        engine.layout = tv.layoutAdapter
        scroll.documentView = tv
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 400),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentView = scroll
        window.makeKeyAndOrderFront(nil)
        scroll.frame = window.contentView?.bounds ?? scroll.frame
        tv.layoutSubtreeIfNeeded()

        let body = NSFont.systemFont(ofSize: 20)
        let heading = NSFont.systemFont(ofSize: 32)
        let sample = "iiii\nHeading"
        engine.load(text: sample)
        tv.string = sample
        tv.font = body
        let style = NSMutableParagraphStyle()
        style.lineHeightMultiple = 1.65
        let ns = sample as NSString
        let full = NSRange(location: 0, length: ns.length)
        tv.textStorage?.addAttribute(.paragraphStyle, value: style, range: full)
        tv.textStorage?.addAttribute(.font, value: body, range: NSRange(location: 0, length: 4))
        let headingAt = 5
        tv.textStorage?.addAttribute(
            .font,
            value: heading,
            range: NSRange(location: headingAt, length: ns.length - headingAt)
        )
        tv.textLayoutManager?.ensureLayout(for: tv.textLayoutManager!.documentRange)
        tv.setSelectedRange(NSRange(location: 0, length: 0))
        engine.mode = .normal

        let block = tv.caretCell(suggested: .zero)
        let iAdvance = ceil(("i" as NSString).size(withAttributes: [.font: body]).width)
        let bodyEm = body.ascender - body.descender
        let lineWidth = ("iiii" as NSString).size(withAttributes: [.font: body]).width
        check(abs(block.width - max(1, iAdvance)) < 1.5, "body block width \(block.width) expected \(iAdvance)", failures: &failures)
        check(abs(block.height - bodyEm) < 1.5, "body block height \(block.height) expected em \(bodyEm)", failures: &failures)
        check(block.width < lineWidth - 1, "body block \(block.width) is wider than one glyph of \(lineWidth)", failures: &failures)
        if let fragmentHeight = lineFragmentHeight(tv, utf16: 0), fragmentHeight > bodyEm + 2 {
            check(
                block.height < fragmentHeight - 1,
                "body caret \(block.height) used the line fragment \(fragmentHeight)",
                failures: &failures
            )
        }

        tv.setSelectedRange(NSRange(location: headingAt, length: 0))
        let head = tv.caretCell(suggested: .zero)
        let hAdvance = ceil(("H" as NSString).size(withAttributes: [.font: heading]).width)
        let headEm = heading.ascender - heading.descender
        check(abs(head.width - max(1, hAdvance)) < 1.5, "heading block width \(head.width) expected \(hAdvance)", failures: &failures)
        check(abs(head.height - headEm) < 1.5, "heading block height \(head.height) expected em \(headEm)", failures: &failures)
        check(head.height > block.height + 2, "heading caret \(head.height) should be taller than body \(block.height)", failures: &failures)

        engine.mode = .insert
        let beam = tv.caretCell(suggested: .zero)
        check(beam.width == 1, "insert beam width \(beam.width)", failures: &failures)
        check(abs(beam.height - headEm) < 1.5, "insert beam height \(beam.height) expected \(headEm)", failures: &failures)
        engine.mode = .normal

        let lines = (0..<80).map { "line \($0) abcdefghij" }.joined(separator: "\n")
        engine.load(text: lines)
        tv.syncFromEngine()
        tv.layoutSubtreeIfNeeded()
        tv.noteContentSizeChanged()
        let clipHeight = scroll.contentView.bounds.height
        check(
            tv.frame.height > clipHeight + 20,
            "document height \(tv.frame.height) is not taller than the clip \(clipHeight)",
            failures: &failures
        )
        let origin = scroll.contentView.bounds.origin.y
        tv.consumeScroll(deltaY: -240, precise: true)
        let scrolled = scroll.contentView.bounds.origin.y
        check(scrolled > origin + 50, "trackpad scroll \(origin) -> \(scrolled)", failures: &failures)

        _ = engine.type("gg")
        tv.syncFromEngine()
        for _ in 0..<40 {
            let result = engine.handle(KeyEvent(.character("j")))
            tv.applyResult(result)
        }
        let line = engine.buffer.lineIndex(containing: engine.cursor)
        let afterJ = motionDiag(engine: engine, tv: tv, scroll: scroll)
        check(line == 40, "j stopped on line \(line) (\(afterJ))", failures: &failures)
        check(
            scroll.contentView.bounds.origin.y > 20,
            "j did not scroll the viewport (\(afterJ))",
            failures: &failures
        )

        _ = engine.type("G")
        tv.syncFromEngine()
        let atEnd = scroll.contentView.bounds.origin.y
        check(
            atEnd > tv.frame.height * 0.3,
            "G left the viewport at \(atEnd) of \(tv.frame.height) (\(motionDiag(engine: engine, tv: tv, scroll: scroll)))",
            failures: &failures
        )
        _ = engine.type("gg")
        tv.syncFromEngine()
        check(
            scroll.contentView.bounds.origin.y < 40,
            "gg left the viewport (\(motionDiag(engine: engine, tv: tv, scroll: scroll)))",
            failures: &failures
        )

        engine.scrollLineCount = tv.halfPageLines()
        let before = engine.buffer.lineIndex(containing: engine.cursor)
        _ = engine.type("<C-d>")
        tv.syncFromEngine()
        let after = engine.buffer.lineIndex(containing: engine.cursor)
        check(
            after >= before + engine.scrollLineCount,
            "Ctrl-d moved \(before) -> \(after) scroll \(engine.scrollLineCount) (\(motionDiag(engine: engine, tv: tv, scroll: scroll)))",
            failures: &failures
        )
        _ = engine.type("<C-u>")
        tv.syncFromEngine()
        let back = engine.buffer.lineIndex(containing: engine.cursor)
        check(
            back <= before + 1,
            "Ctrl-u moved to \(back) from \(after) (\(motionDiag(engine: engine, tv: tv, scroll: scroll)))",
            failures: &failures
        )
    }

    @MainActor
    private static func motionDiag(engine: Engine, tv: VimTextView, scroll: NSScrollView) -> String {
        let cursor = engine.cursor
        let line = engine.buffer.lineIndex(containing: cursor)
        let column = engine.buffer.column(of: cursor)
        let textLines = tv.string.reduce(into: 1) { count, character in
            if character == "\n" { count += 1 }
        }
        let origin = scroll.contentView.bounds.origin.y
        let clip = scroll.contentView.bounds.height
        return "line \(line) col \(column) cursor \(cursor) bufferLines \(engine.buffer.lineCount) textLines \(textLines) visualLines \(tv.layoutAdapter.laidOutLineCount()) doc \(tv.frame.height) clip \(clip) origin \(origin)"
    }

    @MainActor
    private static func lineFragmentHeight(_ tv: VimTextView, utf16: Int) -> CGFloat? {
        guard let lm = tv.textLayoutManager else { return nil }
        lm.ensureLayout(for: lm.documentRange)
        guard let location = lm.location(lm.documentRange.location, offsetBy: utf16),
              let fragment = lm.textLayoutFragment(for: location),
              let line = fragment.textLineFragments.first else { return nil }
        return line.typographicBounds.height
    }

    @MainActor
    private static func checkDirectory(failures: inout [String]) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("quill-smoke-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: root.appendingPathComponent("sub"), withIntermediateDirectories: true)
            try Data("hello notes\n".utf8).write(to: root.appendingPathComponent("notes.md"))
        } catch {
            failures.append("fixture: \(error.localizedDescription)")
            return
        }
        defer { try? FileManager.default.removeItem(at: root) }

        let model = AppModel()
        model.open(url: root)
        check(model.isDirectory, "quill . did not open a directory buffer (\(model.message))", failures: &failures)
        check(model.engine.openOnEnter, "directory buffer did not arm Enter", failures: &failures)
        check(model.engine.text.contains("notes.md"), "listing missing notes.md: \(model.engine.text)", failures: &failures)
        check(model.engine.text.contains("sub/"), "listing missing sub/: \(model.engine.text)", failures: &failures)

        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 640, height: 400))
        let tv = VimTextView(usingTextLayoutManager: true)
        tv.commonInit()
        tv.engine = model.engine
        model.engine.layout = tv.layoutAdapter
        scroll.documentView = tv
        tv.syncFromEngine()
        check(tv.string.contains("notes.md"), "text view did not show the directory listing", failures: &failures)

        var guardSteps = 0
        while !model.engine.lineTextUnderCursor().hasPrefix("notes.md"), guardSteps < 10 {
            let step = model.engine.handle(KeyEvent(.character("j")))
            model.handleEngineResult(step)
            guardSteps += 1
            if step.beep { break }
        }
        let opened = model.engine.handle(KeyEvent(.enter))
        check(opened.actions.contains(.openUnderCursor), "Enter did not open the entry: \(opened.actions)", failures: &failures)
        model.handleEngineResult(opened)
        let deadline = Date().addingTimeInterval(3)
        while model.isDirectory, Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        check(model.engine.text.contains("hello notes"), "Enter did not load notes.md: \(model.engine.text)", failures: &failures)
        tv.syncFromEngine()
        check(tv.string.contains("hello notes"), "text view stayed on the directory after Enter", failures: &failures)

        let parent = model.engine.handle(KeyEvent(.character("-")))
        check(parent.actions == [.openParentDirectory], "minus actions \(parent.actions)", failures: &failures)
        model.handleEngineResult(parent)
        check(model.isDirectory, "minus did not return to the directory (\(model.message))", failures: &failures)
        check(model.engine.text.contains("notes.md"), "parent listing lost notes.md", failures: &failures)

        guardSteps = 0
        while !model.engine.lineTextUnderCursor().hasPrefix("notes.md"), guardSteps < 10 {
            _ = model.engine.handle(KeyEvent(.character("j")))
            guardSteps += 1
        }
        _ = model.engine.type("0c$renamed.md<Esc>")
        check(
            model.engine.lineTextUnderCursor().hasPrefix("renamed.md"),
            "rename left \(model.engine.lineTextUnderCursor())",
            failures: &failures
        )
        model.save()
        check(model.showConfirm, " :w did not ask to apply filesystem changes (\(model.message))", failures: &failures)
        let renamed = model.pendingOps.contains { op in
            if case .rename = op { return true }
            return false
        }
        check(renamed, "save planned \(model.pendingOps.map(\.summary)) instead of a rename", failures: &failures)
    }
}
