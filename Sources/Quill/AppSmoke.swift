import AppKit
import Foundation
import SwiftUI
import QuillFS
import QuillMarkdown
import QuillVim

/// In-process check for the behaviors Linux tests cannot see: caret cell size,
/// real scrolling, oil-style directory buffers, and the picker query field.
/// Run with `QUILL_SMOKE=1`. Exits the process.
///
/// The checks start from `applicationDidFinishLaunching`. They must not wait
/// for the SwiftUI window: a binary launched from a background shell is never
/// activated, `onAppear` never runs, and the main thread sits in the run loop
/// with no output. A watchdog armed at `applicationWillFinishLaunching` prints
/// a snapshot and exits 2 if that still has not finished after 20 seconds.
enum AppSmoke {
    @MainActor private static var started = false
    @MainActor private static let trace = SmokeTraceStore()

    /// Call from `applicationWillFinishLaunching`, before any window wait.
    @MainActor
    static func prepareIfRequested() {
        guard ProcessInfo.processInfo.environment["QUILL_SMOKE"] == "1" else { return }
        trace.arm(seconds: 20)
        fputs("quill smoke: watchdog armed (20s)\n", stderr)
        fflush(stderr)
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        app.activate()
        noteAppKit(probe: false)
    }

    @MainActor
    static func noteAttachedModel() {
        trace.update {
            $0.modelAttached = true
            if $0.modelSource == "none" { $0.modelSource = "swiftui" }
        }
    }

    @MainActor
    static func noteWindowAppeared() {
        trace.update { $0.windowAppeared = true }
        noteAppKit(probe: false)
    }

    /// Start smoke once launch has finished. The SwiftUI model is used when
    /// `onAppear` already attached it; otherwise a standalone model is built
    /// so the checks do not wait for a key window.
    @MainActor
    static func launchDidFinish(model: AppModel?) {
        trace.update { $0.launchFinished = true }
        guard ProcessInfo.processInfo.environment["QUILL_SMOKE"] == "1" else { return }
        let resolved: AppModel
        if let model {
            trace.update {
                $0.modelAttached = true
                if $0.modelSource == "none" { $0.modelSource = "swiftui" }
            }
            resolved = model
        } else {
            resolved = AppModel()
            trace.update {
                $0.modelAttached = true
                if $0.modelSource == "none" { $0.modelSource = "synthesized" }
            }
        }
        runIfRequested(model: resolved)
    }

    @MainActor
    static func runIfRequested(model: AppModel) {
        guard !started else { return }
        guard ProcessInfo.processInfo.environment["QUILL_SMOKE"] == "1" else { return }
        started = true
        trace.update { $0.smokeStarted = true }
        fputs("quill smoke started\n", stderr)
        fflush(stderr)
        _ = model
        var failures: [String] = []
        checkDefaultType(failures: &failures)
        checkTheme(failures: &failures)
        checkTables(failures: &failures)
        checkTableViewport(failures: &failures)
        checkCaretAndScroll(failures: &failures)
        checkLongNote(failures: &failures)
        checkColumnFollowsResize(failures: &failures)
        checkDirectory(failures: &failures)
        checkPicker(failures: &failures)
        if failures.isEmpty {
            fputs("quill smoke passed\n", stderr)
            fflush(stderr)
            trace.cancel()
            exit(0)
        }
        for failure in failures {
            fputs("FAIL \(failure)\n", stderr)
        }
        fflush(stderr)
        trace.cancel()
        exit(1)
    }

    @MainActor
    static func recordProbeSnapshot() {
        noteAppKit(probe: true)
    }

    @MainActor
    private static func noteAppKit(probe: Bool) {
        let app = NSApplication.shared
        let policy: String
        switch app.activationPolicy() {
        case .regular: policy = "regular"
        case .accessory: policy = "accessory"
        case .prohibited: policy = "prohibited"
        @unknown default: policy = "unknown"
        }
        trace.update {
            $0.activationPolicy = policy
            $0.windowCount = app.windows.count
            if probe { $0.probeAnswered = true }
        }
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
        check(QuillConfig.default.font.isEmpty, "default body font family set", failures: &failures)
        let system = NSFont.systemFont(ofSize: CGFloat(QuillMetrics.defaultFontSize))
        check(
            theme.bodyFont.familyName == system.familyName,
            "default body font family \(theme.bodyFont.familyName ?? "")",
            failures: &failures
        )
        for font in theme.headingFonts {
            let weight = fontWeight(font)
            check(weight >= 0.28, "heading weight \(weight)", failures: &failures)
            check(
                font.familyName == system.familyName,
                "heading family \(font.familyName ?? "")",
                failures: &failures
            )
        }
        let monoFamily = theme.monoFont.familyName ?? ""
        let systemMono = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular).familyName ?? ""
        check(theme.monoFont.isFixedPitch, "mono font \(monoFamily)", failures: &failures)
        check(
            monoFamily == "SF Mono" || monoFamily == systemMono,
            "mono font \(monoFamily)",
            failures: &failures
        )
        let missing = QuillTheme.current(fontFamily: "Not A Real Font")
        check(
            missing.bodyFont.familyName == system.familyName,
            "font fallback \(missing.bodyFont.familyName ?? "")",
            failures: &failures
        )
        let helvetica = QuillTheme.current(fontFamily: "Helvetica")
        check(helvetica.bodyFont.familyName == "Helvetica", "font family \(helvetica.bodyFont.familyName ?? "")", failures: &failures)
        if let decoded = try? QuillConfig.decode(Data("font = \" Helvetica \"\n".utf8)) {
            check(decoded.font == "Helvetica", "font config \(decoded.font)", failures: &failures)
        } else {
            failures.append("font config decode")
        }
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
    private static func fontWeight(_ font: NSFont) -> CGFloat {
        let traits = font.fontDescriptor.object(forKey: .traits) as? [NSFontDescriptor.TraitKey: Any]
        if let number = traits?[.weight] as? NSNumber {
            return CGFloat(truncating: number)
        }
        return 0
    }

    @MainActor
    private static func checkTheme(failures: inout [String]) {
        let dark = QuillTheme.current(scheme: .dark)
        let light = QuillTheme.current(scheme: .light)
        check(brightness(dark.backgroundColor) < brightness(light.backgroundColor), "theme dark", failures: &failures)
        let engine = Engine(text: "hello")
        check(engine.type(":theme dark<CR>").actions == [.setTheme(.dark)], "theme command", failures: &failures)
        check(engine.type(":theme<CR>").actions == [.toggleTheme], "theme toggle", failures: &failures)
        let bad = engine.type(":theme blue<CR>")
        check(bad.beep && bad.actions.isEmpty, "theme name", failures: &failures)
        check(Engine(text: "hello").type(" tt").actions == [.toggleTheme], "leader tt", failures: &failures)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("quill-theme-\(UUID().uuidString)", isDirectory: true)
        let url = directory.appendingPathComponent("state.toml")
        do {
            try ThemeMemory.save(.dark, to: url)
            check(ThemeMemory.load(from: url) == .dark, "theme memory", failures: &failures)
        } catch {
            failures.append("theme memory \(error.localizedDescription)")
        }
        try? FileManager.default.removeItem(at: directory)
        check(QuillConfig.default.theme == .system, "theme config default", failures: &failures)
        if let decoded = try? QuillConfig.decode(Data("theme = \"dark\"\n".utf8)) {
            check(decoded.theme == .dark, "theme config \(decoded.theme.rawValue)", failures: &failures)
        } else {
            failures.append("theme config")
        }
        check((try? QuillConfig.decode(Data("theme = \"blue\"\n".utf8))) == nil, "theme config name", failures: &failures)
    }

    @MainActor
    private static func brightness(_ color: NSColor) -> CGFloat {
        let rgb = color.usingColorSpace(.sRGB) ?? color
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        rgb.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return red
    }

    @MainActor
    private static func colorDistance(_ lhs: NSColor, _ rhs: NSColor) -> CGFloat {
        let a = lhs.usingColorSpace(.sRGB) ?? lhs
        let b = rhs.usingColorSpace(.sRGB) ?? rhs
        var ar: CGFloat = 0, ag: CGFloat = 0, ab: CGFloat = 0, aa: CGFloat = 0
        var br: CGFloat = 0, bg: CGFloat = 0, bb: CGFloat = 0, ba: CGFloat = 0
        a.getRed(&ar, green: &ag, blue: &ab, alpha: &aa)
        b.getRed(&br, green: &bg, blue: &bb, alpha: &ba)
        return abs(ar - br) + abs(ag - bg) + abs(ab - bb)
    }

    @MainActor
    private static func checkCaretAndScroll(failures: inout [String]) {
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 640, height: 400))
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        let tv = VimTextView.make()
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
            failures: &failures
        )
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

        let blank = assertCaretGlyph(tv: tv, index: 5, font: body, label: "empty", failures: &failures)
        check(abs(blank.height - bodyEm) < 1.5, "empty caret height \(blank.height) expected em \(bodyEm)", failures: &failures)
        let space = ceil((" " as NSString).size(withAttributes: [.font: body]).width)
        check(abs(blank.width - max(1, space)) < 1.5, "empty caret width \(blank.width) expected \(space)", failures: &failures)

        let head = assertCaretGlyph(tv: tv, index: headingAt, font: heading, label: "heading", failures: &failures)
        let hAdvance = ceil(("H" as NSString).size(withAttributes: [.font: heading]).width)
        let headEm = heading.ascender - heading.descender
        check(abs(head.width - max(1, hAdvance)) < 1.5, "heading block width \(head.width) expected \(hAdvance)", failures: &failures)
        check(abs(head.height - headEm) < 1.5, "heading block height \(head.height) expected em \(headEm)", failures: &failures)
        check(head.height > block.height + 2, "heading caret \(head.height) should be taller than body \(block.height)", failures: &failures)

        let endCaret = assertCaretGlyph(tv: tv, index: ns.length, font: body, label: "end", failures: &failures)
        check(abs(endCaret.height - bodyEm) < 1.5, "end caret height \(endCaret.height) expected em \(bodyEm)", failures: &failures)

        engine.mode = .insert
        let beam = assertCaretGlyph(tv: tv, index: headingAt, font: heading, label: "insert", failures: &failures)
        let beamWidth = CaretGeometry.beamPointWidth(backingScale: Double(window.backingScaleFactor))
        check(abs(Double(beam.width) - beamWidth) < 0.2, "insert beam width \(beam.width) expected \(beamWidth)", failures: &failures)
        check(abs(beam.height - headEm) < 1.5, "insert beam height \(beam.height) expected \(headEm)", failures: &failures)
        check(tv.caretIsBlinking, "insert blink missing", failures: &failures)
        let endBeam = assertCaretGlyph(tv: tv, index: ns.length, font: body, label: "insert end", failures: &failures)
        check(
            CaretGeometry.heightFitsEm(caretHeight: Double(endBeam.height), emHeight: Double(bodyEm)),
            "insert end caret height \(endBeam.height) is outside 1.3x em \(bodyEm)",
            failures: &failures
        )
        engine.mode = .normal
        _ = assertCaretGlyph(tv: tv, index: 0, font: body, label: "body", failures: &failures)
        check(!tv.caretIsBlinking, "normal blink", failures: &failures)
        check(tv.caretIsVisible, "mode switch hid the caret", failures: &failures)

        tv.textContainerInset = NSSize(width: 0, height: 0)
        tv.layoutSubtreeIfNeeded()

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
        // The first line sits below the top margin, so the origin rests just above that line.
        let top = max(40, tv.textContainerInset.height + 8)
        check(
            scroll.contentView.bounds.origin.y < top,
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

        checkWrappedVertical(engine: engine, tv: tv, failures: &failures)
    }

    /// A 10k-line note stays one buffer in the text view: `G` scrolls to the
    /// end, search lands on a late line, and select-all covers the file.
    @MainActor
    private static func checkLongNote(failures: inout [String]) {
        let lineCount = 10_000
        let markerLine = 9_000
        let text = (0..<lineCount).map { line -> String in
            if line == markerLine {
                return "Line \(line) MARKER-9000 end\n"
            }
            return "Line \(line) plain\n"
        }.joined()
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        scroll.hasVerticalScroller = true
        let tv = VimTextView.make()
        tv.commonInit()
        let engine = Engine(text: text)
        tv.engine = engine
        engine.layout = tv.layoutAdapter
        scroll.documentView = tv
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentView = scroll
        window.makeKeyAndOrderFront(nil)
        tv.syncFromEngine()
        tv.layoutSubtreeIfNeeded()

        let viewLength = (tv.string as NSString).length
        check(
            tv.string == text && viewLength == engine.buffer.count,
            "long note view holds \(viewLength) of \(engine.buffer.count)",
            failures: &failures
        )
        let clip = scroll.contentView.bounds.height
        check(
            tv.frame.height > clip * 20,
            "long note height \(tv.frame.height) is not the whole file",
            failures: &failures
        )
        tv.selectAll(nil)
        let selected = tv.selectedRange()
        let copied = selected.length == viewLength && selected.location == 0
            ? (tv.string as NSString).substring(with: selected)
            : ""
        check(
            copied == text,
            "select all copied \(selected.location)+\(selected.length) of \(viewLength)",
            failures: &failures
        )

        _ = engine.type("gg")
        tv.syncFromEngine()
        _ = engine.type("G")
        tv.syncFromEngine()
        let endLine = engine.buffer.lineIndex(containing: engine.cursor)
        let maxY = max(0, tv.frame.height - clip)
        let atEnd = scroll.contentView.bounds.origin.y
        check(endLine == lineCount - 1, "G stopped on line \(endLine)", failures: &failures)
        check(
            atEnd > maxY - clip,
            "G scroll \(atEnd) did not reach \(maxY) (\(motionDiag(engine: engine, tv: tv, scroll: scroll)))",
            failures: &failures
        )

        _ = engine.type("gg")
        tv.syncFromEngine()
        _ = engine.type("/MARKER-9000<CR>")
        tv.syncFromEngine()
        let found = engine.buffer.lineIndex(containing: engine.cursor)
        check(found == markerLine, "search landed on line \(found)", failures: &failures)
        let row = tv.frame.height / CGFloat(max(engine.buffer.lineCount, 1))
        let lineY = CGFloat(markerLine) * row
        let origin = scroll.contentView.bounds.origin.y
        check(
            lineY >= origin - row * 2 && lineY <= origin + clip + row * 2,
            "search scroll \(origin) does not show line \(markerLine) at \(lineY)",
            failures: &failures
        )
        window.orderOut(nil)
    }

    /// A long paragraph in a narrow column. `j` must step one screen row and
    /// stay on that paragraph, not jump to its last character.
    @MainActor
    private static func checkWrappedVertical(engine: Engine, tv: VimTextView, failures: inout [String]) {
        tv.columnWidth = 160
        tv.updateInsets()
        let paragraph = String(repeating: "abcdefghi ", count: 30)
        engine.load(text: paragraph + "\nZ")
        tv.syncFromEngine()
        tv.layoutSubtreeIfNeeded()
        tv.layoutAdapter.ensureFullLayout()
        let visual = tv.layoutAdapter.laidOutLineCount()
        check(visual >= 3, "wrapped paragraph laid out \(visual) visual lines", failures: &failures)

        _ = engine.type("0")
        let start = engine.cursor
        let first = engine.handle(KeyEvent(.character("j")))
        tv.applyResult(first)
        let afterFirst = engine.cursor
        check(
            engine.buffer.lineIndex(containing: afterFirst) == 0,
            "j left the paragraph at \(afterFirst)",
            failures: &failures
        )
        check(afterFirst > start, "j did not advance from \(start)", failures: &failures)
        let paragraphEnd = paragraph.utf16.count - 1
        check(
            afterFirst < paragraphEnd - 20,
            "j jumped to \(afterFirst) near \(paragraphEnd)",
            failures: &failures
        )

        let second = engine.handle(KeyEvent(.character("j")))
        tv.applyResult(second)
        check(
            engine.buffer.lineIndex(containing: engine.cursor) == 0,
            "j left the paragraph at \(engine.cursor)",
            failures: &failures
        )
        check(engine.cursor > afterFirst, "j did not advance from \(afterFirst)", failures: &failures)
        check(
            engine.cursor < paragraphEnd - 20,
            "j jumped to \(engine.cursor) near \(paragraphEnd)",
            failures: &failures
        )

        _ = engine.type("gg")
        let back = engine.handle(KeyEvent(.character("k")))
        check(back.beep, "k returned by moving at the top", failures: &failures)

        _ = engine.type("j")
        let row = engine.cursor
        _ = engine.type("k")
        check(
            engine.cursor == start,
            "k returned to \(engine.cursor) instead of \(start) from \(row)",
            failures: &failures
        )

        _ = engine.type("$")
        let screenEnd = engine.cursor
        check(
            screenEnd > start && screenEnd < 80,
            "screen $ landed at \(screenEnd)",
            failures: &failures
        )
        _ = engine.type("g$")
        check(
            engine.cursor > 200,
            "g$ landed at \(engine.cursor)",
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

    /// Measures the caret view, not the geometry helper. Height stays within 1.3× of
    /// the font em box and the rect sits in that line's glyph bounds, on the baseline
    /// reported by text segments.
    @MainActor
    private static func assertCaretGlyph(
        tv: VimTextView,
        index: Int,
        font: NSFont,
        label: String,
        failures: inout [String]
    ) -> NSRect {
        let length = (tv.string as NSString).length
        let utf16 = min(max(0, index), length)
        tv.setSelectedRange(NSRange(location: utf16, length: 0))
        tv.layoutSubtreeIfNeeded()
        let caret = tv.renderedCaretRect()
        let em = font.ascender - font.descender
        check(
            CaretGeometry.heightFitsEm(caretHeight: Double(caret.height), emHeight: Double(em)),
            "\(label) caret height \(caret.height) is outside 1.3x em \(em)",
            failures: &failures
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
            failures: &failures
        )
        check(abs(glyphs.height - em) < 1.5, "\(label) glyph bounds height \(glyphs.height) expected em \(em)", failures: &failures)
        if let baseline = segmentBaseline(tv, utf16: utf16, font: font) {
            let top = baseline.y - font.ascender
            let bottom = baseline.y - font.descender
            check(
                abs(caret.minY - top) < 2.5 && abs(caret.maxY - bottom) < 2.5,
                "\(label) caret \(caret) missed baseline \(baseline.y) em top \(top) \(baseline.detail)",
                failures: &failures
            )
        } else {
            failures.append("\(label) caret baseline missing at \(utf16)")
        }
        check(tv.caretIsVisible, "\(label) caret hidden", failures: &failures)
        if let stray = tv.visibleSystemCaretHeight(), stray > em * CaretGeometry.glyphHeightMultiple + 0.75 {
            failures.append("\(label) system caret height \(stray) is outside 1.3x em \(em)")
        }
        return caret
    }

    /// Baseline in text-view coordinates from `enumerateTextSegments`, independent of
    /// the line-fragment math the caret view uses. Past a trailing newline, the last
    /// character's segment is the previous line; the caret belongs on the next one.
    @MainActor
    private static func segmentBaseline(_ tv: VimTextView, utf16: Int, font: NSFont) -> (y: CGFloat, detail: String)? {
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
    private static func checkDirectoryChrome(
        model: AppModel,
        tv: VimTextView,
        scroll: NSScrollView,
        root: URL,
        failures: inout [String]
    ) {
        let width = scroll.contentView.bounds.width
        let prose = QuillMetrics.columnSpan(width: width, column: tv.columnWidth)
        let column = tv.textContainer?.size.width ?? 0
        let font = tv.textStorage.flatMap { storage -> NSFont? in
            guard storage.length > 0 else { return nil }
            return storage.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        }
        check(font?.isFixedPitch == true, "directory font pitch \(font?.fontName ?? "missing")", failures: &failures)
        check(
            font?.familyName == model.theme.directoryFont.familyName,
            "directory font family \(font?.familyName ?? "")",
            failures: &failures
        )
        check(
            abs((font?.pointSize ?? 0) - model.theme.directoryFont.pointSize) < 0.25,
            "directory font size \(font?.pointSize ?? 0)",
            failures: &failures
        )
        check(
            (font?.pointSize ?? 0) <= model.theme.bodyFont.pointSize - 2,
            "directory font \(font?.pointSize ?? 0) is not compact next to \(model.theme.bodyFont.pointSize)",
            failures: &failures
        )
        check(model.theme.directoryFont.isFixedPitch, "directory font mono", failures: &failures)
        check(
            abs(tv.textContainerInset.width - QuillMetrics.directoryHorizontalInset) < 0.5,
            "directory inset \(tv.textContainerInset.width)",
            failures: &failures
        )
        check(
            tv.textContainerInset.width + 40 < prose.inset,
            "directory inset \(tv.textContainerInset.width) still tracks the prose column \(prose.inset) at width \(width)",
            failures: &failures
        )
        check(
            column > prose.column + 40,
            "directory column \(column) is not wider than the prose column \(prose.column)",
            failures: &failures
        )
        let headerInset = QuillMetrics.directoryHeaderHeight + QuillMetrics.directoryHeaderGap
        check(
            abs(tv.textContainerInset.height - headerInset) < 0.5,
            "directory header inset \(tv.textContainerInset.height)",
            failures: &failures
        )
        check(
            colorDistance(tv.backgroundColor, model.theme.directoryBackgroundColor) < 0.02,
            "directory background view",
            failures: &failures
        )
        let dark = QuillTheme.current(scheme: .dark)
        let light = QuillTheme.current(scheme: .light)
        check(
            colorDistance(dark.directoryBackgroundColor, dark.backgroundColor) > 0.04,
            "directory background dark",
            failures: &failures
        )
        check(
            colorDistance(light.directoryBackgroundColor, light.backgroundColor) > 0.04,
            "directory background light",
            failures: &failures
        )
        let header = DirectoryStyleBuilder.abbreviatedDirectory(
            path: root.path,
            home: FileManager.default.homeDirectoryForCurrentUser.path
        )
        check(tv.directoryHeaderText == header, "directory header \(tv.directoryHeaderText)", failures: &failures)
        check(
            DirectoryStyleBuilder.abbreviatedDirectory(path: "/Users/quill/notes", home: "/Users/quill") == "~/notes/",
            "directory header home",
            failures: &failures
        )
        check(
            DirectoryStyleBuilder.abbreviatedDirectory(path: "/Users/quill", home: "/Users/quill") == "~/",
            "directory header root",
            failures: &failures
        )
        check(
            DirectoryStyleBuilder.abbreviatedDirectory(path: "/Users/quill2/notes", home: "/Users/quill") == "/Users/quill2/notes/",
            "directory header boundary",
            failures: &failures
        )
        if let dot = foreground(in: tv, needle: ".hidden") {
            check(colorDistance(dot, model.theme.dimColor) < 0.08, "directory dim \(dot)", failures: &failures)
        } else {
            failures.append("directory dim missing")
        }
        if let folder = foreground(in: tv, needle: "sub/") {
            check(
                colorDistance(folder, model.theme.directoryAccentColor) < 0.08,
                "directory accent \(folder)",
                failures: &failures
            )
        } else {
            failures.append("directory accent missing")
        }
        let parent = URL(fileURLWithPath: "/notes")
        let original = [
            DirEntry(originalURL: parent.appendingPathComponent("keep.md"), name: "keep.md", isDirectory: false, entryID: 1),
            DirEntry(originalURL: parent.appendingPathComponent("gone.md"), name: "gone.md", isDirectory: false, entryID: 2),
        ]
        let edited = [
            DirectoryBufferLine(text: "keep.md", anchorID: 1, sourcePath: "/notes/keep.md", sourceIsDirectory: false, transfer: .identity),
            DirectoryBufferLine(text: "fresh.md", anchorID: nil, sourcePath: nil, sourceIsDirectory: false, transfer: nil),
        ]
        let preview = DirectoryStyleBuilder.style(
            directoryPath: "/notes",
            homePath: "/Users/quill",
            lines: edited,
            original: original
        )
        let created = preview.lines.contains { $0.mark == .created && $0.name == "fresh.md" }
        let removed = preview.deleted.contains { $0.name == "gone.md" }
        check(created, "new was not marked", failures: &failures)
        check(removed, "delete was not marked", failures: &failures)

        let proseScroll = NSScrollView(frame: scroll.frame)
        proseScroll.hasVerticalScroller = false
        let proseView = VimTextView.make()
        proseView.commonInit()
        proseView.engine = Engine(text: "Hello\n")
        proseView.isDirectoryBuffer = false
        proseView.columnWidth = model.theme.columnWidth
        proseScroll.documentView = proseView
        proseView.applyTheme(model.theme, focus: false)
        proseScroll.layoutSubtreeIfNeeded()
        proseView.layoutSubtreeIfNeeded()
        proseView.updateInsets()
        let proseWidth = proseScroll.contentView.bounds.width
        let proseSpan = QuillMetrics.columnSpan(width: proseWidth, column: proseView.columnWidth)
        check(
            abs(proseView.textContainerInset.width - proseSpan.inset) < 1,
            "prose inset \(proseView.textContainerInset.width) expected \(proseSpan.inset)",
            failures: &failures
        )
    }

    @MainActor
    private static func foreground(in tv: VimTextView, needle: String) -> NSColor? {
        let ns = tv.string as NSString
        let range = ns.range(of: needle)
        guard range.location != NSNotFound, let storage = tv.textStorage else { return nil }
        return storage.attribute(.foregroundColor, at: range.location, effectiveRange: nil) as? NSColor
    }

    /// Two real window widths. The check must not call `updateInsets` itself:
    /// a resize has to recompute the column, or this fails.
    @MainActor
    private static func checkColumnFollowsResize(failures: inout [String]) {
        let measure: CGFloat = 420
        let height: CGFloat = 520
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 960, height: height))
        scroll.hasVerticalScroller = false
        scroll.hasHorizontalScroller = false
        scroll.autoresizingMask = [.width, .height]
        let tv = VimTextView(usingTextLayoutManager: true)
        tv.commonInit()
        let line = String(repeating: "alpha bravo ", count: 12)
        let lines = (0..<40).map { "\($0) \(line)" }.joined(separator: "\n")
        let engine = Engine(text: lines)
        tv.engine = engine
        engine.layout = tv.layoutAdapter
        tv.isDirectoryBuffer = false
        tv.columnWidth = measure
        scroll.documentView = tv
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 960, height: height),
            styleMask: [.titled, .resizable, .closable],
            backing: .buffered,
            defer: false
        )
        window.contentView = scroll
        window.makeKeyAndOrderFront(nil)
        defer {
            window.orderOut(nil)
            window.close()
        }
        tv.applyTheme(QuillTheme.current(), focus: false)
        tv.syncFromEngine()

        resizeEditor(window, scroll: scroll, width: 640, height: height)
        let narrowClip = scroll.contentView.bounds.width
        assertWritingColumn(tv, clipWidth: narrowClip, label: "column narrow", failures: &failures)
        let narrowSpan = QuillMetrics.columnSpan(width: narrowClip, column: measure)
        check(
            abs(narrowSpan.inset - QuillMetrics.sideGutter) < 1,
            "column clip \(narrowClip) inset \(narrowSpan.inset) is not the minimum gutter",
            failures: &failures
        )
        check(
            narrowSpan.column < measure - 10,
            "column clip \(narrowClip) measure \(narrowSpan.column) did not shrink",
            failures: &failures
        )
        tv.viewDidEndLiveResize()
        assertWritingColumn(tv, clipWidth: scroll.contentView.bounds.width, label: "column narrow", failures: &failures)

        for _ in 0..<24 {
            let step = engine.handle(KeyEvent(.character("j")))
            tv.applyResult(step)
        }
        let originBefore = scroll.contentView.bounds.origin.y
        let caretBefore = caretViewportOffset(tv, scroll: scroll)
        let cursor = engine.cursor
        check(originBefore > 20, "column caret origin \(originBefore) did not scroll", failures: &failures)
        check(caretBefore > 8, "column caret \(caretBefore) was not in view", failures: &failures)

        resizeEditor(window, scroll: scroll, width: 1280, height: height)
        let wideClip = scroll.contentView.bounds.width
        assertWritingColumn(tv, clipWidth: wideClip, label: "column wide", failures: &failures)
        let wideSpan = QuillMetrics.columnSpan(width: wideClip, column: measure)
        check(
            abs(wideSpan.column - measure) < 1,
            "column clip \(wideClip) measure \(wideSpan.column) is not the max",
            failures: &failures
        )
        check(
            tv.textContainerInset.width > narrowSpan.inset + 30,
            "column inset did not grow \(tv.textContainerInset.width) from \(narrowSpan.inset) clips \(narrowClip) \(wideClip)",
            failures: &failures
        )
        check(wideClip > narrowClip + 200, "column clip did not widen \(narrowClip) -> \(wideClip)", failures: &failures)
        let caretLive = caretViewportOffset(tv, scroll: scroll)
        check(engine.cursor == cursor, "column caret cursor moved to \(engine.cursor)", failures: &failures)
        check(
            abs(caretLive - caretBefore) < 20,
            "column caret \(caretBefore) -> \(caretLive) origin \(originBefore) -> \(scroll.contentView.bounds.origin.y)",
            failures: &failures
        )
        tv.viewDidEndLiveResize()
        assertWritingColumn(tv, clipWidth: scroll.contentView.bounds.width, label: "column wide", failures: &failures)
        let caretSettled = caretViewportOffset(tv, scroll: scroll)
        check(
            abs(caretSettled - caretBefore) < 20,
            "column caret \(caretBefore) -> \(caretSettled) after live resize origin \(scroll.contentView.bounds.origin.y)",
            failures: &failures
        )

        tv.isDirectoryBuffer = true
        resizeEditor(window, scroll: scroll, width: 760, height: height)
        assertDirectoryWidth(tv, scroll: scroll, failures: &failures)
        let directoryNarrow = tv.textContainer?.size.width ?? 0
        resizeEditor(window, scroll: scroll, width: 1180, height: height)
        tv.viewDidEndLiveResize()
        assertDirectoryWidth(tv, scroll: scroll, failures: &failures)
        let directoryWide = tv.textContainer?.size.width ?? 0
        check(
            directoryWide > directoryNarrow + 150,
            "directory resize column did not grow \(directoryNarrow) -> \(directoryWide)",
            failures: &failures
        )
    }

    @MainActor
    private static func resizeEditor(_ window: NSWindow, scroll: NSScrollView, width: CGFloat, height: CGFloat) {
        let size = NSSize(width: width, height: height)
        window.setContentSize(size)
        scroll.setFrameSize(size)
        scroll.tile()
        scroll.layoutSubtreeIfNeeded()
        scroll.documentView?.layoutSubtreeIfNeeded()
    }

    @MainActor
    private static func assertWritingColumn(
        _ tv: VimTextView,
        clipWidth: CGFloat,
        label: String,
        failures: inout [String]
    ) {
        let span = QuillMetrics.columnSpan(width: clipWidth, column: tv.columnWidth)
        let inset = tv.textContainerInset.width
        let column = tv.textContainer?.size.width ?? 0
        check(
            abs(inset - span.inset) < 1,
            "\(label) inset \(inset) expected \(span.inset) clip \(clipWidth)",
            failures: &failures
        )
        check(
            abs(column - span.column) < 1,
            "\(label) measure \(column) expected \(span.column) clip \(clipWidth)",
            failures: &failures
        )
        let left = tv.textContainerOrigin.x
        let right = tv.bounds.width - left - column
        check(
            abs(left - right) < 3,
            "\(label) not centered left \(left) right \(right) column \(column) view \(tv.bounds.width) clip \(clipWidth)",
            failures: &failures
        )
    }

    @MainActor
    private static func assertDirectoryWidth(_ tv: VimTextView, scroll: NSScrollView, failures: inout [String]) {
        let clip = scroll.contentView.bounds.width
        let inset = tv.textContainerInset.width
        let column = tv.textContainer?.size.width ?? 0
        let expected = max(1, clip - QuillMetrics.directoryHorizontalInset * 2)
        check(
            abs(inset - QuillMetrics.directoryHorizontalInset) < 0.5,
            "directory resize inset \(inset) clip \(clip)",
            failures: &failures
        )
        check(
            abs(column - expected) < 2,
            "directory resize column \(column) expected \(expected) clip \(clip)",
            failures: &failures
        )
        check(
            column > tv.columnWidth + 40,
            "directory resize column \(column) still the prose measure \(tv.columnWidth)",
            failures: &failures
        )
    }

    @MainActor
    private static func caretViewportOffset(_ tv: VimTextView, scroll: NSScrollView) -> CGFloat {
        tv.layoutSubtreeIfNeeded()
        let cell = tv.caretCell(suggested: .zero)
        return cell.midY - scroll.contentView.bounds.origin.y
    }

    @MainActor
    private static func checkDirectory(failures: inout [String]) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("quill-smoke-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: root.appendingPathComponent("sub"), withIntermediateDirectories: true)
            try Data("hello notes\n".utf8).write(to: root.appendingPathComponent("notes.md"))
            try Data("hidden\n".utf8).write(to: root.appendingPathComponent(".hidden"))
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

        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 800, height: 480))
        scroll.hasVerticalScroller = false
        let tv = VimTextView.make()
        tv.commonInit()
        tv.engine = model.engine
        model.engine.layout = tv.layoutAdapter
        scroll.documentView = tv
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 480),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentView = scroll
        scroll.frame = window.contentView?.bounds ?? scroll.frame
        scroll.layoutSubtreeIfNeeded()
        tv.isDirectoryBuffer = true
        tv.directoryURL = root
        tv.directoryEntries = model.directorySnapshot?.entries ?? []
        tv.columnWidth = model.theme.columnWidth
        tv.applyTheme(model.theme, focus: false)
        tv.syncFromEngine()
        tv.layoutSubtreeIfNeeded()
        tv.updateInsets()
        tv.queueRestyle()
        check(tv.string.contains("notes.md"), "text view did not show the directory listing", failures: &failures)
        checkDirectoryChrome(model: model, tv: tv, scroll: scroll, root: root, failures: &failures)

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
        let pending = DirectoryStyleBuilder.style(
            directoryPath: model.fileURL?.path ?? "",
            homePath: FileManager.default.homeDirectoryForCurrentUser.path,
            lines: DirectoryStyleBuilder.lines(from: model.engine.buffer),
            original: model.directorySnapshot?.entries ?? []
        )
        let marked = pending.lines.contains { line in
            if case .renamed(let from) = line.mark {
                return line.name == "renamed.md" && from == "notes.md"
            }
            return false
        }
        check(marked, "rename was not marked \(pending.lines.map { "\($0.name) \($0.mark)" })", failures: &failures)
        model.save()
        check(model.showConfirm, " :w did not ask to apply filesystem changes (\(model.message))", failures: &failures)
        let renamed = model.pendingOps.contains { op in
            if case .rename = op { return true }
            return false
        }
        check(renamed, "save planned \(model.pendingOps.map(\.summary)) instead of a rename", failures: &failures)
    }

    @MainActor
    private static func checkTables(failures: inout [String]) {
        let fenced = """
        | Keep | Me |
        | :--- | -: |
        | Ada | 1 |

        ```
        | Skip | Me |
        | --- | --- |
        | x | y |
        ```
        """
        let blocks = MarkdownTables.blocks(in: fenced)
        check(blocks.count == 1, "table detect \(blocks.count)", failures: &failures)
        check(blocks.first?.columns.map(\.align) == [.left, .right], "table align", failures: &failures)
        check(blocks.first?.rows.map(\.role) == [.header, .separator, .body], "table detect roles", failures: &failures)

        let ragged = "| A | Q |\n| :- | -: |\n| c | 1 |\n| d | 12 |"
        let block = MarkdownTables.blocks(in: ragged).first
        let short = block?.rows.dropFirst(2).first?.cells.last
        check(short?.leadingPad ?? 0 > 0, "table align pad \(short?.leadingPad ?? -1)", failures: &failures)

        let light = QuillTheme.current(scheme: .light)
        let dark = QuillTheme.current(scheme: .dark)
        check(light.tableBackground.alphaComponent > 0.02, "table background light", failures: &failures)
        check(dark.tableBackground.alphaComponent > 0.02, "table background dark", failures: &failures)
        check(
            abs(light.tableBackground.alphaComponent - dark.tableBackground.alphaComponent) > 0.001
                || brightness(light.tableBackground) != brightness(dark.tableBackground),
            "table background theme",
            failures: &failures
        )
        check(light.tableHeaderRule.alphaComponent > light.tableRowRule.alphaComponent, "table rule weight", failures: &failures)

        let storage = NSTextStorage(string: ragged)
        MarkdownStyler.restyle(storage, theme: light, spans: [])
        guard let painted = block, let pipe = painted.rows[0].pipes.first, let header = painted.rows[0].cells.first else {
            failures.append("table detect header")
            return
        }
        let headerFont = storage.attribute(.font, at: header.text.lowerBound, effectiveRange: nil) as? NSFont
        check(headerFont?.isFixedPitch == true, "table header pitch", failures: &failures)
        check(fontWeight(headerFont ?? light.bodyFont) >= 0.28, "table header weight", failures: &failures)
        let body = painted.rows[2].cells[0]
        let bodyFont = storage.attribute(.font, at: body.text.lowerBound, effectiveRange: nil) as? NSFont
        check(bodyFont?.isFixedPitch == true, "table body pitch", failures: &failures)
        check(fontWeight(bodyFont ?? light.bodyFont) < 0.2, "table body weight", failures: &failures)
        check(
            sameColor(storage.attribute(.foregroundColor, at: pipe.lowerBound, effectiveRange: nil) as? NSColor, light.syntaxColor),
            "table pipe",
            failures: &failures
        )
        check(
            sameColor(storage.attribute(.backgroundColor, at: body.text.lowerBound, effectiveRange: nil) as? NSColor, light.tableBackground),
            "table background",
            failures: &failures
        )
        let headerUnderline = storage.attribute(.underlineStyle, at: header.text.lowerBound, effectiveRange: nil) as? NSNumber
        let bodyUnderline = storage.attribute(.underlineStyle, at: body.text.lowerBound, effectiveRange: nil) as? NSNumber
        check(headerUnderline?.intValue == NSUnderlineStyle.single.rawValue, "table rule header", failures: &failures)
        check(bodyUnderline?.intValue == NSUnderlineStyle.single.rawValue, "table rule row", failures: &failures)
        let para = storage.attribute(.paragraphStyle, at: body.text.lowerBound, effectiveRange: nil) as? NSParagraphStyle
        check(para?.lineBreakMode == .byClipping, "table nowrap", failures: &failures)
        if let pipeIndex = short?.precedingPipe {
            let kern = (storage.attribute(.kern, at: pipeIndex, effectiveRange: nil) as? NSNumber)?.doubleValue ?? 0
            check(kern > 0.5, "table align kern \(kern)", failures: &failures)
        } else {
            failures.append("table align kern")
        }

        let wide = String(repeating: "b", count: 80)
        let sample = "| A | \(wide) |\n| - | - |\n| c | d |"
        let measured = (sample as NSString).size(withAttributes: [.font: light.monoFont]).width
        check(measured > 140, "table nowrap sample \(measured)", failures: &failures)
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
        check(fragments == 3, "table nowrap \(fragments)", failures: &failures)

        let command = Engine(text: ragged).type(":TableFormat<CR>")
        check(
            command.actions == [.formatTables(startLine: nil, endLine: nil, quiet: false)],
            "table command \(command.actions)",
            failures: &failures
        )
        check(QuillConfig.default.formatTablesOnInsertLeave == false, "table format config", failures: &failures)
        if let decoded = try? QuillConfig.decode(Data("formatTablesOnInsertLeave = true\n".utf8)) {
            check(decoded.formatTablesOnInsertLeave, "table format config on", failures: &failures)
        } else {
            failures.append("table format config on")
        }
        check(
            (try? QuillConfig.decode(Data("formatTablesOnInsertLeave = \"yes\"\n".utf8))) == nil,
            "table format config name",
            failures: &failures
        )
    }

    /// A table below the first screen is unstyled until the clip scrolls onto it.
    /// Editing a cell then updates kern on the other visible rows.
    @MainActor
    private static func checkTableViewport(failures: inout [String]) {
        let prose = (0..<100).map { "Line \($0) plain words here.\n" }.joined()
        let table = "| Name | Qty |\n| :--- | --: |\n| Ada | 1 |\n| Linus | 12 |\n"
        let text = prose + table
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 640, height: 280))
        scroll.hasVerticalScroller = true
        let tv = VimTextView.make()
        tv.commonInit()
        let engine = Engine(text: text)
        tv.engine = engine
        engine.layout = tv.layoutAdapter
        scroll.documentView = tv
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 280),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentView = scroll
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        tv.syncFromEngine()
        tv.layoutSubtreeIfNeeded()

        guard let header = text.range(of: "| Name |"), let storage = tv.textStorage else {
            failures.append("table viewport missing")
            return
        }
        let pipe = text.utf16.distance(from: text.startIndex, to: header.lowerBound)
        let theme = tv.theme
        check(
            !sameColor(storage.attribute(.foregroundColor, at: pipe, effectiveRange: nil) as? NSColor, theme.syntaxColor),
            "table viewport styled early",
            failures: &failures
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
            failures: &failures
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
        check(headerFont?.isFixedPitch == true, "table viewport header pitch", failures: &failures)
        check(fontWeight(headerFont ?? theme.bodyFont) >= 0.28, "table viewport header", failures: &failures)
        let kern = (storage.attribute(.kern, at: shortPipe, effectiveRange: nil) as? NSNumber)?.doubleValue ?? 0
        check(kern > 0.5, "table viewport kern \(kern)", failures: &failures)

        engine.moveCursor(to: wide)
        engine.mode = .insert
        let typed = engine.handle(KeyEvent(.character("3")))
        tv.applyResult(typed)
        let kernAfter = (storage.attribute(.kern, at: shortPipe, effectiveRange: nil) as? NSNumber)?.doubleValue ?? 0
        check(kernAfter > kern + 0.4, "table edit kern \(kern) \(kernAfter)", failures: &failures)
    }

    @MainActor
    private static func lineFragmentCount(_ textView: NSTextView) -> Int {
        guard let layout = textView.textLayoutManager else { return -1 }
        layout.ensureLayout(for: layout.documentRange)
        var count = 0
        layout.enumerateTextLayoutFragments(from: layout.documentRange.location, options: [.ensuresLayout]) { fragment in
            count += fragment.textLineFragments.filter { $0.characterRange.length > 0 }.count
            return true
        }
        return count
    }

    @MainActor
    private static func sameColor(_ color: NSColor?, _ expected: NSColor) -> Bool {
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
    @MainActor
    private static func checkPicker(failures: inout [String]) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("quill-picker-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try Data("alpha notes\n".utf8).write(to: root.appendingPathComponent("notes.md"))
            try Data("beta ideas\n".utf8).write(to: root.appendingPathComponent("ideas.md"))
        } catch {
            failures.append("picker fixture: \(error.localizedDescription)")
            return
        }
        defer { try? FileManager.default.removeItem(at: root) }

        let model = AppModel()
        model.open(url: root)
        model.presentFilePicker()
        // The index finishes on a task. NSHostingView does not redraw when that
        // task assigns `picker`, so the panel is hosted only after it is open
        // and replaced again after each edit.
        let indexed = waitUntil(seconds: 2) { model.picker != nil }
        guard indexed else {
            failures.append("picker did not open (\(model.message))")
            return
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 640),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        // A new hosting view each time. Assigning rootView on the same
        // NSHostingView leaves the previous caret in the hierarchy.
        var host = showPicker(window, model)
        let opened = waitUntil(seconds: 0.8) {
            settle(host, window)
            let hint = queryField(in: host)?.placeholderAttributedString?.string ?? ""
            return hint == "File name"
                && modeField(in: host)?.stringValue == "INSERT"
                && (caretView(in: host)?.bounds.height ?? 0) >= 8
        }
        guard opened, let field = queryField(in: host) else {
            failures.append("picker query field missing \(viewDump(host))")
            return
        }
        let placeholder = field.placeholderAttributedString?.string ?? field.placeholderString ?? ""
        check(field.stringValue.isEmpty, "picker query was \(field.stringValue) before typing", failures: &failures)
        check(placeholder == "File name", "picker placeholder \(placeholder)", failures: &failures)
        if let painted = field.textColor {
            let drift = abs(brightness(painted) - brightness(model.theme.textColor))
            let contrast = abs(brightness(painted) - brightness(model.theme.backgroundColor))
            check(drift < 0.08, "picker query color drift \(drift)", failures: &failures)
            check(contrast > 0.45, "picker query contrast \(contrast)", failures: &failures)
        } else {
            failures.append("picker query color missing")
        }
        check(field.font?.isFixedPitch == true, "picker query font \(field.font?.fontName ?? "")", failures: &failures)
        let mode = modeField(in: host)?.stringValue ?? ""
        check(mode == "INSERT", "picker mode \(mode)", failures: &failures)
        guard let caretBefore = caretView(in: host) else {
            failures.append("picker caret missing \(viewDump(host))")
            return
        }
        check(caretBefore.bounds.height >= 8, "picker caret height \(caretBefore.bounds.height)", failures: &failures)
        check(caretBefore.bounds.width <= 2, "picker caret width \(caretBefore.bounds.width)", failures: &failures)
        let caretXBefore = caretBefore.convert(caretBefore.bounds, to: nil).minX

        model.handlePicker(.character("n"))
        model.handlePicker(.character("o"))
        host = showPicker(window, model)
        let filtered = waitUntil(seconds: 0.6) {
            settle(host, window)
            let titles = resultTitles(in: host)
            return queryField(in: host)?.stringValue == "no"
                && titles.contains { $0.contains("notes.md") }
                && !titles.contains { $0.contains("ideas.md") }
        }
        let shown = queryField(in: host)?.stringValue ?? ""
        let titles = resultTitles(in: host)
        check(filtered && shown == "no", "picker query showed \(shown) results \(titles)", failures: &failures)
        check(titles.contains { $0.contains("notes.md") }, "picker filter missing notes \(titles)", failures: &failures)
        check(!titles.contains { $0.contains("ideas.md") }, "picker filter kept ideas \(titles)", failures: &failures)
        if let notes = resultFields(in: host).first(where: { $0.stringValue.contains("notes.md") }) {
            let matched = attrChannel(notes, utf16: 0)
            let rest = attrChannel(notes, utf16: 2)
            check(abs(matched - rest) > 0.12, "picker highlight \(matched) vs \(rest)", failures: &failures)
        } else {
            failures.append("picker highlight missing notes row \(titles)")
        }
        if let caretAfter = caretView(in: host) {
            let caretXAfter = caretAfter.convert(caretAfter.bounds, to: nil).minX
            check(caretXAfter > caretXBefore + 2, "picker caret stayed at \(caretXBefore) -> \(caretXAfter)", failures: &failures)
        } else {
            failures.append("picker caret disappeared while typing")
        }

        model.handlePicker(.escape)
        host = showPicker(window, model)
        let leftInsert = waitUntil(seconds: 0.4) {
            settle(host, window)
            return modeField(in: host)?.stringValue == "NORMAL" && caretView(in: host) == nil
        }
        let normal = modeField(in: host)?.stringValue ?? ""
        check(leftInsert && normal == "NORMAL", "picker mode \(normal)", failures: &failures)
        check(queryField(in: host)?.stringValue == "no", "picker query cleared in normal mode", failures: &failures)
        check(caretView(in: host) == nil, "picker caret still drawn in normal mode", failures: &failures)

        model.handlePicker(.character("q"))
        model.presentGrepPicker()
        host = showPicker(window, model)
        let grepOpen = waitUntil(seconds: 0.4) {
            settle(host, window)
            let hint = queryField(in: host)?.placeholderAttributedString?.string ?? ""
            return hint == "Pattern" && queryField(in: host)?.stringValue.isEmpty == true
        }
        check(grepOpen, "grep query field \(queryField(in: host)?.stringValue ?? "missing")", failures: &failures)
        for character in "alpha" {
            model.handlePicker(.character(character))
        }
        var seenGrepTick = model.pickerTick
        host = showPicker(window, model)
        let grepped = waitUntil(seconds: 1.5) {
            if model.pickerTick != seenGrepTick {
                seenGrepTick = model.pickerTick
                host = showPicker(window, model)
            } else {
                settle(host, window)
            }
            let hits = resultTitles(in: host)
            return queryField(in: host)?.stringValue == "alpha"
                && hits.contains { $0.contains("notes.md") }
                && !hits.contains { $0.contains("ideas.md") }
        }
        let grepShown = queryField(in: host)?.stringValue ?? ""
        let hits = resultTitles(in: host)
        check(grepped && grepShown == "alpha", "grep query showed \(grepShown) results \(hits)", failures: &failures)
        check(hits.contains { $0.contains("notes.md") }, "grep results missing notes \(hits)", failures: &failures)
        check(!hits.contains { $0.contains("ideas.md") }, "grep results kept ideas \(hits)", failures: &failures)
        if let snippet = fields("quill.picker.snippet", in: host).first(where: { $0.stringValue.localizedCaseInsensitiveContains("alpha") }) {
            let matched = attrChannel(snippet, utf16: 0)
            let restIndex = (snippet.stringValue as NSString).length > 6 ? 6 : 1
            let rest = attrChannel(snippet, utf16: restIndex)
            check(abs(matched - rest) > 0.12, "grep highlight \(matched) vs \(rest) in \(snippet.stringValue)", failures: &failures)
        } else {
            failures.append("grep highlight missing snippet \(hits)")
        }
    }

    /// A fresh hosting view shows the picker's current query, caret, and rows.
    /// Reusing one view left the previous insert-mode caret in the tree.
    @MainActor
    private static func showPicker(_ window: NSWindow, _ model: AppModel) -> NSHostingView<PickerPanel> {
        let host = NSHostingView(rootView: PickerPanel(model: model))
        host.autoresizingMask = [.width, .height]
        let bounds = window.contentView?.bounds ?? NSRect(x: 0, y: 0, width: 800, height: 640)
        window.contentView = host
        host.frame = bounds
        settle(host, window)
        return host
    }

    @MainActor
    private static func settle(_ host: NSView, _ window: NSWindow) {
        host.needsLayout = true
        host.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
    }

    @MainActor
    private static func waitUntil(seconds: TimeInterval, _ ready: () -> Bool) -> Bool {
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

    @MainActor
    private static func queryField(in view: NSView) -> NSTextField? {
        fields("quill.picker.query", in: view).first
    }

    @MainActor
    private static func modeField(in view: NSView) -> NSTextField? {
        fields("quill.picker.mode", in: view).first
    }

    @MainActor
    private static func caretView(in view: NSView) -> NSView? {
        findView({ $0.accessibilityIdentifier() == "quill.picker.caret" }, in: view)
    }

    @MainActor
    private static func resultFields(in view: NSView) -> [NSTextField] {
        fields("quill.picker.result", in: view)
    }

    @MainActor
    private static func resultTitles(in view: NSView) -> [String] {
        resultFields(in: view).map(\.stringValue)
    }

    @MainActor
    private static func fields(_ identifier: String, in view: NSView) -> [NSTextField] {
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

    @MainActor
    private static func findView(_ match: @MainActor (NSView) -> Bool, in view: NSView) -> NSView? {
        if match(view) { return view }
        for subview in view.subviews {
            if let found = findView(match, in: subview) { return found }
        }
        return nil
    }

    @MainActor
    private static func attrChannel(_ field: NSTextField, utf16: Int) -> CGFloat {
        let text = field.attributedStringValue
        guard utf16 >= 0, utf16 < text.length else { return -1 }
        let color = text.attribute(.foregroundColor, at: utf16, effectiveRange: nil) as? NSColor
        guard let color else { return -1 }
        return brightness(color)
    }

    @MainActor
    private static func viewDump(_ view: NSView) -> String {
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

private struct SmokeTrace: Sendable {
    var launchFinished = false
    var modelAttached = false
    var modelSource = "none"
    var windowAppeared = false
    var smokeStarted = false
    var activationPolicy = "unset"
    var windowCount = -1
    var probeAnswered = false
}

// quill-concurrency: NSLock guards the snapshot the watchdog thread reads while the main actor writes it.
private final class SmokeTraceStore: @unchecked Sendable {
    private let lock = NSLock()
    private var trace = SmokeTrace()
    private var armed = false
    private var cancelled = false

    func update(_ body: (inout SmokeTrace) -> Void) {
        lock.lock()
        body(&trace)
        lock.unlock()
    }

    func copy() -> SmokeTrace {
        lock.lock()
        defer { lock.unlock() }
        return trace
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    func arm(seconds: Double) {
        lock.lock()
        if armed {
            lock.unlock()
            return
        }
        armed = true
        lock.unlock()
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + seconds) { [self] in
            guard !self.isCancelled() else { return }
            let ready = DispatchSemaphore(value: 0)
            DispatchQueue.main.async {
                // quill-concurrency: The main queue is the main thread; assumeIsolated hops without capturing a non-Sendable self.
                MainActor.assumeIsolated {
                    AppSmoke.recordProbeSnapshot()
                }
                ready.signal()
            }
            _ = ready.wait(timeout: .now() + 1)
            guard !self.isCancelled() else { return }
            let shot = self.copy()
            // write(2) rather than stderr: the FILE* global is not concurrency-safe,
            // and this thread must report even when the main actor never runs again.
            Self.writeStderr(Self.diagnostic(shot, seconds: seconds))
            guard !self.isCancelled() else { return }
            exit(2)
        }
    }

    private func isCancelled() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    private static func diagnostic(_ trace: SmokeTrace, seconds: Double) -> String {
        let waited = Int(seconds.rounded())
        return """
        quill smoke watchdog: exiting 2 after \(waited)s
        launchFinished=\(trace.launchFinished) modelAttached=\(trace.modelAttached) modelSource=\(trace.modelSource) windowAppeared=\(trace.windowAppeared) smokeStarted=\(trace.smokeStarted)
        windows=\(trace.windowCount) activationPolicy=\(trace.activationPolicy) probeAnswered=\(trace.probeAnswered)

        """
    }

    private static func writeStderr(_ text: String) {
        let bytes = Array(text.utf8)
        bytes.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            _ = write(STDERR_FILENO, base, buffer.count)
        }
    }
}
