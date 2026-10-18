import AppKit
import SwiftUI
import QuillMarkdown
import QuillVim

/// TextKit 2 display-line layout. The vim engine only invokes this from the
/// app's main-actor event loop (keyDown / sync).
// quill-concurrency: TextLayout is nonisolated and the main-actor key loop is the only caller.
@MainActor
final class TextKit2Layout: TextLayout, @unchecked Sendable {
    weak var textView: NSTextView?
    private var stickyColumn = -1
    private var stickyX: CGFloat = 0

    nonisolated func displayColumn(of offset: Int, in buffer: TextBuffer) -> Int {
        LogicalLineLayout.shared.displayColumn(of: offset, in: buffer)
    }

    nonisolated func position(
        from offset: Int,
        displayLines delta: Int,
        preferredColumn: Int,
        in buffer: TextBuffer
    ) -> Int {
        guard delta != 0 else {
            return LogicalLineLayout.shared.position(
                from: offset,
                displayLines: delta,
                preferredColumn: preferredColumn,
                in: buffer
            )
        }
        // quill-concurrency: TextBuffer is not Sendable; the engine calls this synchronously on the main thread.
        nonisolated(unsafe) let buffer = buffer
        return MainActor.assumeIsolated {
            positionUsingTextKit(
                from: offset,
                displayLines: delta,
                preferredColumn: preferredColumn,
                in: buffer
            )
        }
    }

    private func positionUsingTextKit(
        from offset: Int,
        displayLines delta: Int,
        preferredColumn: Int,
        in buffer: TextBuffer
    ) -> Int {
        guard let tv = textView, let lm = tv.textLayoutManager else {
            return LogicalLineLayout.shared.position(
                from: offset,
                displayLines: delta,
                preferredColumn: preferredColumn,
                in: buffer
            )
        }
        let utf16 = min(max(0, offset), (tv.string as NSString).length)
        let lines = enumerateVisualLines(layout: lm)
        guard visualLinesAreUsable(lines, buffer: buffer) else {
            // Viewport-only or non-monotonic layout cannot be trusted. A bad
            // index here is what pinned `j` on line 1.
            stickyColumn = -1
            return LogicalLineLayout.shared.position(
                from: offset, displayLines: delta, preferredColumn: preferredColumn, in: buffer
            )
        }
        var index = lines.lastIndex { line in
            utf16 >= line.start && utf16 < line.start + line.length
        } ?? lines.count - 1
        if preferredColumn != stickyColumn {
            stickyColumn = preferredColumn
            let local = min(max(0, utf16 - lines[index].start), lines[index].length)
            stickyX = lines[index].line.locationForCharacter(at: local).x
        }
        index = min(max(0, index + delta), lines.count - 1)
        let line = lines[index]
        let rawHit = line.line.characterIndex(for: CGPoint(x: stickyX, y: line.line.typographicBounds.midY))
        // `characterIndex(for:)` is either 0-based in the line or absolute in the
        // fragment. Stay on this visual line either way — landing on `length`
        // would be the first character of the next line.
        let relative: Int
        if line.localLocation > 0, rawHit >= line.localLocation {
            relative = rawHit - line.localLocation
        } else {
            relative = rawHit
        }
        let hit = min(max(0, relative), max(0, line.length - 1))
        return buffer.clampedCursor(line.start + hit, normalMode: true)
    }

    private struct VisualLine {
        var line: NSTextLineFragment
        /// Document UTF-16 offset of the first character on this visual line.
        var start: Int
        var length: Int
        /// `characterRange.location` inside the fragment. Zero for a paragraph's first visual line.
        var localLocation: Int
    }

    /// How many visual lines TextKit actually produced. Smoke prints this
    /// when `j` does not land where the buffer says it should.
    func laidOutLineCount() -> Int {
        guard let lm = textView?.textLayoutManager else { return 0 }
        return enumerateVisualLines(layout: lm).count
    }

    func ensureFullLayout() {
        guard let lm = textView?.textLayoutManager else { return }
        _ = enumerateVisualLines(layout: lm)
    }

    /// `characterRange` is relative to its layout fragment, not the document.
    /// Comparing those local ranges to a document offset only matches the
    /// first line, so every later `j` retargets line 1. `.ensuresLayout`
    /// forces fragments past the viewport; without it TextKit 2 only
    /// materializes what is on screen.
    private func enumerateVisualLines(layout lm: NSTextLayoutManager) -> [VisualLine] {
        var lines: [VisualLine] = []
        lm.enumerateTextLayoutFragments(
            from: lm.documentRange.location,
            options: [.ensuresLayout]
        ) { fragment in
            let fragmentStart = lm.offset(from: lm.documentRange.location, to: fragment.rangeInElement.location)
            if fragmentStart == NSNotFound { return true }
            for line in fragment.textLineFragments {
                let range = line.characterRange
                if range.location == NSNotFound || range.length == 0 { continue }
                lines.append(VisualLine(
                    line: line,
                    start: fragmentStart + range.location,
                    length: range.length,
                    localLocation: range.location
                ))
            }
            return true
        }
        return lines
    }

    private func visualLinesAreUsable(_ lines: [VisualLine], buffer: TextBuffer) -> Bool {
        guard let first = lines.first, first.start == 0 else { return false }
        // Wrapping may produce more visual lines than buffer lines. Fewer
        // means the layout is still a partial viewport.
        if lines.count < buffer.lineCount { return false }
        var previousStart = -1
        var coveredThrough = 0
        for line in lines {
            if line.start <= previousStart { return false }
            if line.start < coveredThrough { return false }
            previousStart = line.start
            coveredThrough = line.start + line.length
        }
        return true
    }
}

@MainActor
protocol VimTextViewDelegate: AnyObject {
    func vimTextView(_ view: VimTextView, didHandle result: EngineResult)
    func vimTextViewDidClick(_ view: VimTextView, characterOffset: Int, commandClick: Bool)
}

final class VimTextView: NSTextView {
    var engine: Engine!
    var layoutAdapter = TextKit2Layout()
    weak var vimDelegate: VimTextViewDelegate?
    var isDirectoryBuffer = false
    var focusMode = false
    var columnWidth: CGFloat = 640
    var theme = QuillTheme.current()
    var diagnosticRanges: [(NSRange, Int)] = []
    private var restyleQueued = false
    private var sizing = false
    private var tokenizer = MarkdownTokenizer(text: "")
    /// Read by `EditorView` in this file. `private` would hide them from that type.
    fileprivate var appliedThemeID = -1
    fileprivate var appliedFocus = false
    private var mouseAnchor: Int?
    private let caretChrome = CaretChrome(frame: .zero)
    private var placingCaret = false
    private var orderingCaret = false

    override func awakeFromNib() {
        super.awakeFromNib()
        commonInit()
    }

    func commonInit() {
        layoutAdapter.textView = self
        usesFontPanel = false
        usesFindPanel = false
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isAutomaticTextReplacementEnabled = false
        isAutomaticSpellingCorrectionEnabled = false
        isRichText = false
        insertionPointColor = .clear
        allowsUndo = false
        isIncrementalSearchingEnabled = false
        textContainer?.widthTracksTextView = false
        textContainer?.heightTracksTextView = false
        textContainer?.lineFragmentPadding = 0
        minSize = NSSize(width: 0, height: 0)
        maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        isVerticallyResizable = true
        isHorizontallyResizable = false
        autoresizingMask = [.width]
    }

    func applyTheme(_ theme: QuillTheme, focus: Bool) {
        self.theme = theme
        self.focusMode = focus
        backgroundColor = theme.backgroundColor
        // TextKit 2 draws NSTextInsertionIndicator from this color. Keep it clear;
        // CaretChrome is the cursor, tinted to match the selection.
        insertionPointColor = .clear
        let accent = CaretInk.accent(for: theme.backgroundColor)
        selectedTextAttributes = [
            .backgroundColor: accent.withAlphaComponent(0.22),
            .foregroundColor: theme.textColor,
        ]
        defaultParagraphStyle = {
            let p = NSMutableParagraphStyle()
            p.lineHeightMultiple = theme.lineHeight
            return p
        }()
        font = theme.bodyFont
        textColor = theme.textColor
        updateInsets()
        queueRestyle()
        placeCaret()
    }

    func updateInsets() {
        guard let clip = enclosingScrollView?.contentView else { return }
        let width = clip.bounds.width
        let vertical = focusMode ? QuillMetrics.focusVerticalInset : QuillMetrics.verticalInset
        let span = QuillMetrics.columnSpan(width: width, column: columnWidth)
        textContainerInset = NSSize(width: span.inset, height: vertical)
        textContainer?.size = NSSize(width: span.column, height: CGFloat.greatestFiniteMagnitude)
    }

    func syncFromEngine() {
        let text = engine.text
        if string != text {
            string = text
            tokenizer = MarkdownTokenizer(text: text)
        }
        setSelectedRange(NSRange(location: clampUTF16(engine.cursor), length: 0))
        if let sel = engine.visualSelection, engine.mode.isVisual {
            let loc = clampUTF16(sel.lowerBound)
            let end = clampUTF16(sel.upperBound)
            setSelectedRange(NSRange(location: loc, length: max(0, end - loc)))
        }
        queueRestyle(dirty: nil)
        noteContentSizeChanged()
        revealCaret()
    }

    func applyResult(_ result: EngineResult) {
        if result.didChangeText {
            if result.edits.isEmpty {
                string = engine.text
                tokenizer = MarkdownTokenizer(text: string)
            } else if let storage = textStorage {
                for edit in result.edits {
                    let nsRange = nsRange(edit.range)
                    if nsRange.location != NSNotFound, NSMaxRange(nsRange) <= storage.length {
                        storage.replaceCharacters(in: nsRange, with: edit.replacement)
                    } else {
                        string = engine.text
                        break
                    }
                }
            }
        }
        let dirty = result.edits.first?.range.lowerBound
        setSelectedRange(NSRange(location: clampUTF16(engine.cursor), length: 0))
        if let sel = engine.visualSelection, engine.mode.isVisual {
            let loc = clampUTF16(sel.lowerBound)
            let end = clampUTF16(sel.upperBound)
            setSelectedRange(NSRange(location: loc, length: max(0, end - loc)))
        }
        queueRestyle(dirty: dirty)
        noteContentSizeChanged()
        revealCaret()
        vimDelegate?.vimTextView(self, didHandle: result)
    }

    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command) {
            super.keyDown(with: event)
            return
        }
        if hasMarkedText() || event.characters?.isEmpty != false {
            super.keyDown(with: event)
            return
        }
        guard let key = KeyEvent(nsEvent: event) else {
            super.keyDown(with: event)
            return
        }
        engine.scrollLineCount = halfPageLines()
        let result = engine.handle(key)
        applyResult(result)
        if result.beep {
            NSSound.beep()
        }
    }

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        let offset = clampUTF16(selectedRange().location)
        mouseAnchor = offset
        engine.moveCursor(to: offset)
        vimDelegate?.vimTextViewDidClick(self, characterOffset: offset, commandClick: event.modifierFlags.contains(.command))
    }

    override func mouseDragged(with event: NSEvent) {
        super.mouseDragged(with: event)
        let offset = clampUTF16(selectedRange().location)
        if let anchor = mouseAnchor, selectedRange().length > 0 {
            engine.beginMouseSelection(anchor: anchor, caret: offset + selectedRange().length)
        }
    }

    /// TextKit 2 does not call this (`FB9713415`). The system indicator is the line
    /// fragment; `CaretChrome` draws the em box instead.
    override var shouldDrawInsertionPoint: Bool { false }

    override func drawInsertionPoint(in rect: NSRect, color: NSColor, turnedOn flag: Bool) {}

    override func updateInsertionPointStateAndRestartTimer(_ restartFlag: Bool) {
        super.updateInsertionPointStateAndRestartTimer(restartFlag)
        silenceSystemCarets()
    }

    override func didAddSubview(_ subview: NSView) {
        super.didAddSubview(subview)
        silenceSystemCarets()
        guard subview !== caretChrome, caretChrome.superview === self, !orderingCaret else { return }
        orderingCaret = true
        addSubview(caretChrome)
        orderingCaret = false
    }

    override func layout() {
        super.layout()
        silenceSystemCarets()
        placeCaret(forcingLayout: false)
    }

    override func setSelectedRange(
        _ charRange: NSRange,
        affinity: NSSelectionAffinity,
        stillSelecting stillSelectingFlag: Bool
    ) {
        super.setSelectedRange(charRange, affinity: affinity, stillSelecting: stillSelectingFlag)
        placeCaret()
    }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        placeCaret()
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        placeCaret()
        return resigned
    }

    override func setFrameSize(_ newSize: NSSize) {
        guard !sizing else {
            super.setFrameSize(newSize)
            return
        }
        sizing = true
        var size = newSize
        size.height = max(size.height, fittedContentHeight())
        if let scroll = enclosingScrollView {
            size.width = max(size.width, scroll.contentSize.width)
        }
        super.setFrameSize(size)
        sizing = false
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        guard let clip = enclosingScrollView?.contentView else { return }
        clip.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(clipViewBoundsChanged(_:)),
            name: NSView.boundsDidChangeNotification,
            object: clip
        )
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
        noteContentSizeChanged()
    }

    override func scrollWheel(with event: NSEvent) {
        consumeScroll(deltaY: event.scrollingDeltaY, precise: event.hasPreciseScrollingDeltas)
    }

    /// `deltaY` matches `NSEvent.scrollingDeltaY`: positive moves toward the start of the buffer.
    func consumeScroll(deltaY: CGFloat, precise: Bool) {
        guard let scroll = enclosingScrollView else { return }
        noteContentSizeChanged()
        let clip = scroll.contentView
        let points: CGFloat
        if precise {
            points = deltaY
        } else {
            points = deltaY * rowHeight()
        }
        var origin = clip.bounds.origin
        origin.y -= points
        let maxY = max(0, bounds.height - clip.bounds.height)
        origin.y = min(max(0, origin.y), maxY)
        guard origin != clip.bounds.origin else { return }
        clip.setBoundsOrigin(origin)
        scroll.reflectScrolledClipView(clip)
    }

    override func insertText(_ insertString: Any, replacementRange: NSRange) {
        let raw: String
        if let text = insertString as? String {
            raw = text
        } else if let text = insertString as? NSAttributedString {
            raw = text.string
        } else {
            return
        }
        guard !raw.isEmpty else { return }
        let result = engine.handle(KeyEvent(.text(raw)))
        applyResult(result)
    }

    func queueRestyle(dirty: Int? = nil) {
        guard !restyleQueued else { return }
        restyleQueued = true
        let dirty = dirty
        Task { @MainActor [weak self] in
            guard let self, let storage = self.textStorage else { return }
            self.restyleQueued = false
            self.tokenizer.replace(text: storage.string, dirtyUTF16: dirty ?? 0)
            MarkdownStyler.restyle(
                storage,
                theme: self.theme,
                spans: self.tokenizer.spans,
                dirtyUTF16: dirty,
                focus: self.focusMode,
                caret: self.engine.cursor,
                diagnostics: self.diagnosticRanges
            )
            self.noteContentSizeChanged()
        }
    }

    /// The caret view's frame after placing it. Smoke reads this, not a parallel rect
    /// that `drawInsertionPoint` might never paint.
    func renderedCaretRect() -> NSRect {
        placeCaret()
        return caretChrome.frame
    }

    var caretIsBlinking: Bool { caretChrome.isBlinking }
    var caretIsVisible: Bool { caretChrome.superview === self && !caretChrome.isHidden }

    /// Height of a system insertion indicator that is still being shown.
    func visibleSystemCaretHeight() -> CGFloat? {
        var tallest: CGFloat?
        func walk(_ view: NSView) {
            if let indicator = view as? NSTextInsertionIndicator {
                let shown = indicator.displayMode != .hidden && !indicator.isHidden && indicator.alphaValue > 0.05
                if shown {
                    tallest = max(tallest ?? 0, indicator.frame.height)
                }
            }
            for child in view.subviews where child !== caretChrome {
                walk(child)
            }
        }
        walk(self)
        return tallest
    }

    /// Em box of the font on this line, in text-view coordinates, wide enough for
    /// the end-of-line cell. This is not the line fragment.
    func lineGlyphBounds(atUTF16 index: Int) -> NSRect? {
        guard let line = lineMetrics(atUTF16: index, forcingLayout: true) else { return nil }
        let caretFont = font(atUTF16: index)
        let em = caretFont.ascender - caretFont.descender
        let space = (" " as NSString).size(withAttributes: [.font: caretFont]).width
        return NSRect(
            x: line.lineMinX,
            y: line.baselineY - caretFont.ascender,
            width: max(line.lineWidth + space, 1),
            height: max(1, em)
        )
    }

    /// One character cell: the advance of the glyph under the cursor, and the em box
    /// of the font on that glyph. Line-fragment height is not used.
    func caretCell(suggested rect: NSRect) -> NSRect {
        if let cell = caretRect(forcingLayout: true) {
            return cell
        }
        let caretFont = font ?? theme.bodyFont
        let em = max(1, caretFont.ascender - caretFont.descender)
        return NSRect(x: rect.minX, y: rect.midY - caretFont.ascender, width: 1, height: em)
    }

    private func placeCaret(forcingLayout: Bool = true) {
        guard engine != nil, !placingCaret else { return }
        placingCaret = true
        defer { placingCaret = false }
        silenceSystemCarets()
        let index = caretUTF16()
        guard let cell = caretRect(forcingLayout: forcingLayout) else { return }
        let show = window == nil || window?.firstResponder === self || window?.firstResponder == nil
        if caretChrome.superview === self,
           caretChrome.isHidden == !show,
           placedCaretMatches(cell, index: index) {
            return
        }
        if caretChrome.superview !== self {
            orderingCaret = true
            addSubview(caretChrome)
            orderingCaret = false
        }
        caretChrome.frame = cell
        let accent = CaretInk.accent(for: theme.backgroundColor)
        caretChrome.accent = accent
        caretChrome.blockAlpha = CGFloat(CaretGeometry.blockFillAlpha)
        let shapeIsBeam = engine.mode == .insert
        caretChrome.kind = shapeIsBeam ? .beam : .block
        if shapeIsBeam {
            caretChrome.glyph = nil
        } else if let redraw = CaretInk.glyphRedraw(text: theme.textColor, accent: accent, background: theme.backgroundColor),
                  let glyph = caretGlyph(atUTF16: index) {
            caretChrome.blockAlpha = 0.86
            caretChrome.glyph = glyph
            caretChrome.glyphFont = font(atUTF16: index)
            caretChrome.glyphColor = redraw
        } else {
            caretChrome.glyph = nil
        }
        caretChrome.needsDisplay = true
        caretChrome.isHidden = !show
        caretChrome.setBlinking(shapeIsBeam && show)
        placedMode = engine.mode
        placedIndex = index
    }

    private var placedMode: Mode?
    private var placedIndex = -1

    private func placedCaretMatches(_ cell: NSRect, index: Int) -> Bool {
        guard placedMode == engine.mode, placedIndex == index else { return false }
        let frame = caretChrome.frame
        return abs(frame.minX - cell.minX) < 0.4
            && abs(frame.minY - cell.minY) < 0.4
            && abs(frame.width - cell.width) < 0.4
            && abs(frame.height - cell.height) < 0.4
    }

    private func caretRect(forcingLayout: Bool) -> NSRect? {
        let index = caretUTF16()
        let caretFont = font(atUTF16: index)
        guard let metrics = caretBaseline(atUTF16: index, forcingLayout: forcingLayout) else {
            return nil
        }
        let shape: CaretShape = engine.mode == .insert ? .beam : .block
        let advance = glyphAdvance(atUTF16: index, font: caretFont)
        let scale = Double(window?.backingScaleFactor ?? 2)
        let box = CaretGeometry.box(
            shape: shape,
            glyphAdvance: Double(advance),
            ascender: Double(caretFont.ascender),
            descender: Double(caretFont.descender),
            originX: Double(metrics.originX),
            baselineY: Double(metrics.baselineY),
            beamPointWidth: CaretGeometry.beamPointWidth(backingScale: scale)
        )
        return alignedCaretRect(NSRect(x: box.x, y: box.y, width: box.width, height: box.height))
    }

    private func alignedCaretRect(_ rect: NSRect) -> NSRect {
        let scale = window?.backingScaleFactor ?? 2
        guard scale > 0 else { return rect }
        func snap(_ value: CGFloat) -> CGFloat { (value * scale).rounded() / scale }
        return NSRect(
            x: snap(rect.minX),
            y: snap(rect.minY),
            width: max(1 / scale, snap(rect.width)),
            height: max(1 / scale, snap(rect.height))
        )
    }

    private func silenceSystemCarets() {
        func walk(_ view: NSView) {
            if let indicator = view as? NSTextInsertionIndicator {
                if indicator.displayMode != .hidden {
                    indicator.displayMode = .hidden
                }
                if !indicator.isHidden {
                    indicator.isHidden = true
                }
            }
            for child in view.subviews where child !== caretChrome {
                walk(child)
            }
        }
        walk(self)
    }

    private func caretUTF16() -> Int {
        if engine.mode.isVisual {
            return clampUTF16(engine.cursor)
        }
        return clampUTF16(selectedRange().location)
    }

    private func caretGlyph(atUTF16 index: Int) -> String? {
        let ns = string as NSString
        guard index >= 0, index < ns.length else { return nil }
        let range = ns.rangeOfComposedCharacterSequence(at: index)
        let chunk = ns.substring(with: range)
        if chunk == "\n" || chunk == "\r" || chunk == "\t" || chunk == " " { return nil }
        return chunk
    }

    func noteContentSizeChanged() {
        guard !sizing, enclosingScrollView != nil else { return }
        sizing = true
        let height = fittedContentHeight()
        let width = max(enclosingScrollView?.contentSize.width ?? bounds.width, 1)
        if abs(bounds.width - width) > 1 || abs(bounds.height - height) > 1 {
            super.setFrameSize(NSSize(width: width, height: height))
        }
        sizing = false
    }

    func revealCaret() {
        noteContentSizeChanged()
        guard let scroll = enclosingScrollView else { return }
        let clip = scroll.contentView
        var rect = caretLineRect() ?? caretCell(suggested: NSRect(x: 0, y: 0, width: 1, height: rowHeight()))
        let line = engine.buffer.lineIndex(containing: clampUTF16(engine.cursor))
        let estimatedMinY = textContainerOrigin.y + CGFloat(line) * rowHeight()
        // A fragment TextKit has not laid out comes back inside the viewport,
        // so the clip never follows the cursor. Use the logical row instead.
        if line > 1, rect.maxY < rowHeight() * 2, estimatedMinY > clip.bounds.height {
            rect = NSRect(x: rect.minX, y: estimatedMinY, width: max(rect.width, 1), height: rowHeight())
        }
        let visible = clip.bounds
        var origin = visible.origin
        let pad = rowHeight()
        if rect.maxY > visible.maxY - 1 {
            origin.y += rect.maxY - visible.maxY + pad
        } else if rect.minY < visible.minY + 1 {
            origin.y -= visible.minY - rect.minY + pad
        }
        let maxY = max(0, bounds.height - visible.height)
        origin.y = min(max(0, origin.y), maxY)
        guard abs(origin.y - visible.origin.y) > 0.5 else { return }
        clip.setBoundsOrigin(origin)
        scroll.reflectScrolledClipView(clip)
    }

    func halfPageLines() -> Int {
        guard let clip = enclosingScrollView?.contentView, clip.bounds.height > 1 else {
            return max(1, engine.scrollLineCount)
        }
        return max(1, Int(clip.bounds.height / rowHeight()) / 2)
    }

    private func rowHeight() -> CGFloat {
        let caretFont = font ?? theme.bodyFont
        return max(1, (caretFont.ascender - caretFont.descender) * theme.lineHeight)
    }

    private func fittedContentHeight() -> CGFloat {
        let inset = textContainerInset.height * 2
        let clip = enclosingScrollView?.contentSize.height ?? bounds.height
        let rows = max(1, (string as NSString).components(separatedBy: "\n").count)
        let estimated = CGFloat(rows) * rowHeight() + inset
        var used: CGFloat = 0
        if textLayoutManager != nil {
            layoutAdapter.ensureFullLayout()
            used = (textLayoutManager?.usageBoundsForTextContainer.height ?? 0) + inset
        }
        return max(clip, ceil(used), ceil(estimated))
    }

    private func font(atUTF16 index: Int) -> NSFont {
        let fallback = self.font ?? theme.bodyFont
        guard let storage = textStorage, storage.length > 0 else { return fallback }
        let ns = string as NSString
        let length = ns.length
        if index >= length {
            // Past the last character: an extra line after a trailing newline uses
            // the typing font. End of a content line keeps that line's font.
            if length > 0 {
                let previous = length - 1
                let unit = ns.character(at: previous)
                if unit != 10 && unit != 13 {
                    return (storage.attribute(.font, at: previous, effectiveRange: nil) as? NSFont) ?? fallback
                }
            }
            return fallback
        }
        var probe = min(max(0, index), length - 1)
        let unit = ns.character(at: probe)
        if (unit == 10 || unit == 13), probe > 0 {
            let previous = probe - 1
            let prev = ns.character(at: previous)
            if prev != 10 && prev != 13 {
                probe = previous
            }
        }
        return (storage.attribute(.font, at: probe, effectiveRange: nil) as? NSFont) ?? fallback
    }

    private func glyphAdvance(atUTF16 index: Int, font: NSFont) -> CGFloat {
        let ns = string as NSString
        if index < ns.length {
            let range = ns.rangeOfComposedCharacterSequence(at: index)
            let chunk = ns.substring(with: range)
            if chunk != "\n", chunk != "\r", chunk != "\t" {
                let width = (chunk as NSString).size(withAttributes: [.font: font]).width
                if width >= 0.5 { return ceil(width) }
            }
        }
        let space = (" " as NSString).size(withAttributes: [.font: font]).width
        return max(1, ceil(space))
    }

    private struct LineMetrics {
        var originX: CGFloat
        var baselineY: CGFloat
        var lineMinX: CGFloat
        var lineWidth: CGFloat
    }

    private func caretBaseline(
        atUTF16 index: Int,
        forcingLayout: Bool
    ) -> (originX: CGFloat, baselineY: CGFloat)? {
        lineMetrics(atUTF16: index, forcingLayout: forcingLayout).map { ($0.originX, $0.baselineY) }
    }

    /// Baseline and leading edge of the glyph, in text-view coordinates.
    /// `locationForCharacter(at:)` is the baseline inside the line fragment, the
    /// same origin `NSTextLineFragment.draw(at:in:)` uses. The fragment's height
    /// includes line spacing and is not the caret.
    private func lineMetrics(atUTF16 index: Int, forcingLayout: Bool) -> LineMetrics? {
        guard let lm = textLayoutManager else { return nil }
        if forcingLayout {
            layoutAdapter.ensureFullLayout()
        }
        let length = (string as NSString).length
        let clamped = min(max(0, index), length)
        let doc = lm.documentRange.location
        let probe = clamped < length ? clamped : max(0, length - 1)
        let location: (any NSTextLocation)?
        if length == 0 {
            location = doc
        } else {
            location = lm.location(doc, offsetBy: probe)
        }
        guard let location, let fragment = lm.textLayoutFragment(for: location) else { return nil }
        let fragmentStart = lm.offset(from: doc, to: fragment.rangeInElement.location)
        if fragmentStart == NSNotFound { return nil }
        let local = clamped - fragmentStart
        let lines = fragment.textLineFragments
        // A trailing newline grows an extra line fragment with an empty range.
        // The caret past the document sits on that line, not on the previous glyph.
        let line: NSTextLineFragment?
        if clamped >= length, let extra = lines.last, extra.characterRange.length == 0 {
            line = extra
        } else {
            line = lines.first { candidate in
                let span = candidate.characterRange
                return local >= span.location && local < span.location + max(span.length, 1)
            } ?? lines.last
        }
        guard let line else { return nil }
        let charIndex = max(0, local - line.characterRange.location)
        let point = line.locationForCharacter(at: min(charIndex, max(0, line.characterRange.length)))
        let container = textContainerOrigin
        let fragmentFrame = fragment.layoutFragmentFrame
        let lineBounds = line.typographicBounds
        return LineMetrics(
            originX: container.x + fragmentFrame.minX + lineBounds.minX + point.x,
            baselineY: container.y + fragmentFrame.minY + lineBounds.minY + point.y,
            lineMinX: container.x + fragmentFrame.minX + lineBounds.minX,
            lineWidth: max(0, lineBounds.width)
        )
    }

    private func caretLineRect() -> NSRect? {
        guard let lm = textLayoutManager else { return nil }
        layoutAdapter.ensureFullLayout()
        let index = clampUTF16(selectedRange().location)
        let doc = lm.documentRange.location
        guard let location = lm.location(doc, offsetBy: index),
              let fragment = lm.textLayoutFragment(for: location) else { return nil }
        let fragmentStart = lm.offset(from: doc, to: fragment.rangeInElement.location)
        let local = index - fragmentStart
        guard let line = fragment.textLineFragments.first(where: { line in
            let span = line.characterRange
            return local >= span.location && local < span.location + max(span.length, 1)
        }) ?? fragment.textLineFragments.last else { return nil }
        let container = textContainerOrigin
        let fragmentFrame = fragment.layoutFragmentFrame
        var rect = line.typographicBounds
        rect.origin.x += container.x + fragmentFrame.minX
        rect.origin.y += container.y + fragmentFrame.minY
        return rect
    }

    @objc private func clipViewBoundsChanged(_ notification: Notification) {
        guard let clip = notification.object as? NSClipView else { return }
        if abs(clip.bounds.width - bounds.width) > 1 {
            noteContentSizeChanged()
        }
    }

    func clampUTF16(_ offset: Int) -> Int {
        min(max(0, offset), (string as NSString).length)
    }

    func nsRange(_ range: Range<Int>) -> NSRange {
        let loc = clampUTF16(range.lowerBound)
        let end = clampUTF16(range.upperBound)
        return NSRange(location: loc, length: max(0, end - loc))
    }
}

extension KeyEvent {
    init?(nsEvent: NSEvent) {
        let flags = nsEvent.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.control),
           let raw = nsEvent.charactersIgnoringModifiers?.lowercased(),
           let ch = raw.first,
           ch.isLetter || ch == "n" || ch == "p" || ch == "r" {
            self.init(.ctrl(ch))
            return
        }
        switch nsEvent.keyCode {
        case 53: self.init(.escape)
        case 36, 76: self.init(.enter)
        case 51: self.init(.backspace)
        case 117: self.init(.delete)
        case 48: self.init(.tab)
        case 123: self.init(.left)
        case 124: self.init(.right)
        case 125: self.init(.down)
        case 126: self.init(.up)
        default:
            guard let chars = nsEvent.characters, let ch = chars.first else { return nil }
            if ch.unicodeScalars.first?.value == 27 { self.init(.escape); return }
            self.init(.character(ch))
        }
    }
}

struct EditorView: NSViewRepresentable {
    var model: AppModel
    /// Bumped when the buffer is replaced outside a keystroke, so SwiftUI
    /// refreshes this representable. `@Observable` does not track `engine`.
    var revision: Int

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        scroll.autohidesScrollers = true
        let tv = VimTextView(usingTextLayoutManager: true)
        tv.commonInit()
        tv.engine = model.engine
        tv.layoutAdapter.textView = tv
        model.engine.layout = tv.layoutAdapter
        tv.vimDelegate = context.coordinator
        tv.minSize = NSSize(width: 0, height: 0)
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        scroll.documentView = tv
        context.coordinator.textView = tv
        context.coordinator.model = model
        tv.applyTheme(model.theme, focus: model.focusMode)
        tv.syncFromEngine()
        context.coordinator.syncedRevision = revision
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let tv = scroll.documentView as? VimTextView else { return }
        tv.engine = model.engine
        _ = revision
        tv.columnWidth = model.theme.columnWidth
        tv.isDirectoryBuffer = model.isDirectory
        let diagnostics = model.nsDiagnosticRanges()
        let diagnosticsChanged = tv.diagnosticRanges.map(\.0) != diagnostics.map(\.0)
        if diagnosticsChanged { tv.diagnosticRanges = diagnostics }
        WindowChrome.apply(theme: model.theme)
        if tv.appliedThemeID != model.themeIdentity || tv.appliedFocus != model.focusMode {
            tv.applyTheme(model.theme, focus: model.focusMode)
            tv.appliedThemeID = model.themeIdentity
            tv.appliedFocus = model.focusMode
        } else {
            tv.updateInsets()
        }
        let caret = min(model.engine.cursor, (tv.string as NSString).length)
        let bufferReplaced = context.coordinator.syncedRevision != revision
        if bufferReplaced || tv.string != model.engine.text || tv.selectedRange().location != caret {
            tv.syncFromEngine()
            context.coordinator.syncedRevision = revision
        } else if diagnosticsChanged {
            tv.queueRestyle()
        }
        let sheetUp = model.showConfirm || model.showUnsaved
        if model.picker == nil, !sheetUp, tv.window?.firstResponder !== tv {
            tv.window?.makeFirstResponder(tv)
        }
        if context.coordinator.hadPicker && model.picker == nil {
            tv.window?.makeFirstResponder(tv)
        }
        context.coordinator.hadPicker = model.picker != nil
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor
    final class Coordinator: NSObject, VimTextViewDelegate {
        var textView: VimTextView?
        weak var model: AppModel?
        var hadPicker = false
        var syncedRevision = -1

        func vimTextView(_ view: VimTextView, didHandle result: EngineResult) {
            model?.handleEngineResult(result)
        }

        func vimTextViewDidClick(_ view: VimTextView, characterOffset: Int, commandClick: Bool) {
            if commandClick {
                model?.goToDefinition()
            }
        }
    }
}
