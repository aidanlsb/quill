import AppKit
import Foundation
import QuillFS
import QuillVim

/// In-process check for the behaviors Linux tests cannot see: caret cell size,
/// real scrolling, and oil-style directory buffers wired through `AppModel`.
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
        checkCaretAndScroll(failures: &failures)
        checkDirectory(failures: &failures)
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

        checkWrappedVertical(engine: engine, tv: tv, failures: &failures)
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
        let proseView = VimTextView(usingTextLayoutManager: true)
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
        let tv = VimTextView(usingTextLayoutManager: true)
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
