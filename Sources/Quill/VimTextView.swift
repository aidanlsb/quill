import AppKit
import SwiftUI
import QuillFS
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
    /// Caret offset that `stickyX` was measured from, or the last vertical landing.
    /// A different offset means the caret moved some other way, so the x is stale.
    private var goalOrigin = -1

    nonisolated func displayColumn(of offset: Int, in buffer: TextBuffer) -> Int {
        // quill-concurrency: TextBuffer is not Sendable; the engine calls this synchronously on the main thread.
        nonisolated(unsafe) let buffer = buffer
        return MainActor.assumeIsolated {
            let range = screenRange(at: offset, in: buffer)
            return max(0, offset - range.lowerBound)
        }
    }

    nonisolated func screenLineStart(at offset: Int, in buffer: TextBuffer) -> Int {
        // quill-concurrency: TextBuffer is not Sendable; the engine calls this synchronously on the main thread.
        nonisolated(unsafe) let buffer = buffer
        return MainActor.assumeIsolated {
            screenRange(at: offset, in: buffer).lowerBound
        }
    }

    nonisolated func screenLineEnd(at offset: Int, in buffer: TextBuffer) -> Int {
        // quill-concurrency: TextBuffer is not Sendable; the engine calls this synchronously on the main thread.
        nonisolated(unsafe) let buffer = buffer
        return MainActor.assumeIsolated {
            buffer.lastCursor(in: screenRange(at: offset, in: buffer))
        }
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
        let logical = LogicalLineLayout.shared.position(
            from: offset, displayLines: delta, preferredColumn: preferredColumn, in: buffer
        )
        // A motion can run before the view catches the buffer (directory reload).
        // Laying that stale string out and treating its rows as buffer offsets
        // deletes the wrong span. Logical lines until the lengths agree.
        guard viewMatches(buffer), let tv = textView, let lm = tv.textLayoutManager else { return logical }
        let utf16 = min(max(0, offset), (tv.string as NSString).length)
        guard let origin = visualLine(at: utf16, layout: lm) else {
            stickyColumn = -1
            goalOrigin = -1
            return logical
        }
        if TextBuffer.isEndColumn(preferredColumn) {
            stickyColumn = preferredColumn
            stickyX = .greatestFiniteMagnitude
        } else if utf16 != goalOrigin || preferredColumn != stickyColumn {
            stickyColumn = preferredColumn
            let local = min(max(0, utf16 - origin.start), max(0, selectableCount(origin, buffer: buffer) - 1))
            stickyX = origin.line.locationForCharacter(at: local).x
        }
        // Step one visual row at a time. Each step lays out that row's fragment
        // only. Enumerating the whole document here made `j` on a long file
        // wait for TextKit before the caret moved.
        var line = origin
        var remaining = abs(delta)
        let forward = delta > 0
        while remaining > 0 {
            guard let next = adjacentVisualLine(to: line, forward: forward, layout: lm) else { break }
            line = next
            remaining -= 1
        }
        let hit = characterOffset(on: line, atX: stickyX, buffer: buffer)
        let dest = buffer.clampedCursor(line.start + hit, normalMode: true)
        goalOrigin = dest
        return dest
    }

    private func screenRange(at offset: Int, in buffer: TextBuffer) -> Range<Int> {
        guard viewMatches(buffer), let tv = textView, let lm = tv.textLayoutManager else {
            return logicalRange(at: offset, in: buffer)
        }
        let utf16 = min(max(0, offset), (tv.string as NSString).length)
        guard let line = visualLine(at: utf16, layout: lm) else {
            return logicalRange(at: offset, in: buffer)
        }
        let end = min(buffer.count, line.start + line.length)
        return min(line.start, end)..<end
    }

    /// The visual row containing `utf16`. Layout is ensured only through this
    /// offset, so `j` can step past the viewport without laying out the file.
    private func visualLine(at utf16: Int, layout lm: NSTextLayoutManager) -> VisualLine? {
        ensureLayout(at: utf16, layout: lm)
        let doc = lm.documentRange.location
        guard let location = lm.location(doc, offsetBy: utf16),
              let fragment = lm.textLayoutFragment(for: location) else { return nil }
        let rows = visualRows(in: fragment, layout: lm)
        return rows.last(where: { utf16 >= $0.start && utf16 < $0.start + max($0.length, 1) }) ?? rows.last
    }

    private func adjacentVisualLine(to line: VisualLine, forward: Bool, layout lm: NSTextLayoutManager) -> VisualLine? {
        let doc = lm.documentRange.location
        guard let location = lm.location(doc, offsetBy: min(line.start, max(0, line.start))),
              let fragment = lm.textLayoutFragment(for: location) else { return nil }
        let rows = visualRows(in: fragment, layout: lm)
        if let index = rows.firstIndex(where: { $0.start == line.start }) {
            let next = forward ? index + 1 : index - 1
            if rows.indices.contains(next) { return rows[next] }
        }
        let probe = forward ? line.start + max(line.length, 1) : line.start - 1
        guard probe >= 0 else { return nil }
        let limit = ((textView?.string ?? "") as NSString).length
        guard probe < limit else { return nil }
        return visualLine(at: probe, layout: lm)
    }

    private func visualRows(in fragment: NSTextLayoutFragment, layout lm: NSTextLayoutManager) -> [VisualLine] {
        let fragmentStart = lm.offset(from: lm.documentRange.location, to: fragment.rangeInElement.location)
        if fragmentStart == NSNotFound { return [] }
        var rows: [VisualLine] = []
        for line in fragment.textLineFragments {
            let range = line.characterRange
            if range.location == NSNotFound || range.length == 0 { continue }
            rows.append(VisualLine(
                line: line,
                start: fragmentStart + range.location,
                length: range.length
            ))
        }
        return rows
    }

    /// Screen rows belong to the view only while it still holds this buffer.
    /// A directory reload updates the engine first; the previous note's line
    /// breaks must not be applied to the listing.
    private func viewMatches(_ buffer: TextBuffer) -> Bool {
        guard let tv = textView else { return false }
        return (tv.string as NSString).length == buffer.count
    }

    /// Lays out only the fragment that contains `utf16`. `textLayoutFragment(for:)`
    /// returns the last fragment already built, so after a short note is replaced
    /// `j` stays on that last row. `.ensuresLayout` is what extends past it;
    /// `ensureLayout(for:)` on a one-character range does not.
    private func ensureLayout(at utf16: Int, layout lm: NSTextLayoutManager) {
        let doc = lm.documentRange
        let length = lm.offset(from: doc.location, to: doc.endLocation)
        guard length != NSNotFound, length > 0 else { return }
        let clamped = min(max(0, utf16), length - 1)
        guard let start = lm.location(doc.location, offsetBy: clamped) else { return }
        var covered = false
        lm.enumerateTextLayoutFragments(from: start, options: [.ensuresLayout]) { fragment in
            let end = lm.offset(from: doc.location, to: fragment.rangeInElement.endLocation)
            covered = end != NSNotFound && end > clamped
            return false
        }
        if covered { return }
        lm.enumerateTextLayoutFragments(from: doc.location, options: [.ensuresLayout]) { fragment in
            let end = lm.offset(from: doc.location, to: fragment.rangeInElement.endLocation)
            if end == NSNotFound { return false }
            return end <= clamped
        }
    }

    private func logicalRange(at offset: Int, in buffer: TextBuffer) -> Range<Int> {
        if buffer.isEmpty { return 0..<0 }
        let line = buffer.lineIndex(containing: offset)
        return buffer.lineContentRange(at: line)
    }

    /// How many UTF-16 units on this row can hold the caret. The trailing
    /// newline is in the fragment range and is not one of them.
    private func selectableCount(_ line: VisualLine, buffer: TextBuffer) -> Int {
        var length = line.length
        guard length > 1 else { return max(length, 1) }
        let last = line.start + length - 1
        guard last < buffer.count else { return length }
        let ch = buffer.character(at: last)
        if ch == "\n" || ch == "\r" {
            length -= 1
        }
        return max(length, 1)
    }

    /// Index within the visual line whose glyph contains `x`.
    /// `locationForCharacter(at:)` takes a 0-based index in the line, the same
    /// index the caret uses. Binary search stays in that space, so a document
    /// offset from `characterIndex(for:)` cannot clamp the hit to the row's end.
    private func characterOffset(on line: VisualLine, atX x: CGFloat, buffer: TextBuffer) -> Int {
        let last = selectableCount(line, buffer: buffer) - 1
        if last <= 0 { return 0 }
        var low = 0
        var high = last
        while low < high {
            let mid = (low + high) / 2
            let nextX = line.line.locationForCharacter(at: mid + 1).x
            if nextX <= x {
                low = mid + 1
            } else {
                high = mid
            }
        }
        return low
    }

    private struct VisualLine {
        var line: NSTextLineFragment
        /// Document UTF-16 offset of the first character on this visual line.
        var start: Int
        var length: Int
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
                    length: range.length
                ))
            }
            return true
        }
        return lines
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
    var directoryURL: URL?
    var directoryEntries: [DirEntry] = []
    var directoryHeaderText = ""
    var directoryGhostHeight: CGFloat = 0
    var focusMode = false
    var columnWidth: CGFloat = 640
    var theme = QuillTheme.current()
    var diagnosticRanges: [(NSRange, Int)] = []
    private var restyleQueued = false
    private var sizing = false
    private var tokenizer = MarkdownTokenizer(text: "")
    /// UTF-16 ranges already given span attributes. A gap between two styled
    /// screens is not covered; scrolling into it styles that screen only.
    private var styledCoverage = 0..<0
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
        let directory = isDirectoryBuffer
        let painted = directory ? theme.directoryBackgroundColor : theme.backgroundColor
        backgroundColor = painted
        // TextKit 2 draws NSTextInsertionIndicator from this color. Keep it clear;
        // CaretChrome is the cursor, tinted to match the painted background.
        insertionPointColor = .clear
        let accent = CaretInk.accent(for: painted)
        selectedTextAttributes = [
            .backgroundColor: accent.withAlphaComponent(0.22),
            .foregroundColor: theme.textColor,
        ]
        defaultParagraphStyle = {
            let p = NSMutableParagraphStyle()
            if directory {
                p.alignment = .left
                p.lineHeightMultiple = QuillMetrics.directoryLineHeight
            } else {
                p.lineHeightMultiple = theme.lineHeight
            }
            return p
        }()
        font = directory ? theme.directoryFont : theme.bodyFont
        textColor = theme.textColor
        if !directory {
            directoryGhostHeight = 0
            directoryHeaderText = ""
        }
        updateInsets()
        queueRestyle()
        placeCaret()
    }

    func updateInsets() {
        guard let clip = enclosingScrollView?.contentView else { return }
        let width = max(clip.bounds.width, 1)
        if isDirectoryBuffer {
            let inset = QuillMetrics.directoryHorizontalInset
            let vertical = QuillMetrics.directoryHeaderHeight + QuillMetrics.directoryHeaderGap
            textContainerInset = NSSize(width: inset, height: vertical)
            textContainer?.size = NSSize(width: max(1, width - inset * 2), height: CGFloat.greatestFiniteMagnitude)
            return
        }
        let vertical = focusMode ? QuillMetrics.focusVerticalInset : QuillMetrics.verticalInset
        let span = QuillMetrics.columnSpan(width: width, column: columnWidth)
        textContainerInset = NSSize(width: span.inset, height: vertical)
        textContainer?.size = NSSize(width: span.column, height: CGFloat.greatestFiniteMagnitude)
    }

    func syncFromEngine() {
        let text = engine.text
        let replaced = string != text
        if replaced {
            string = text
            let through = viewportLastLine()
            tokenizer = MarkdownTokenizer(text: text, scanThroughLine: through)
            styledCoverage = 0..<0
        }
        setSelectedRange(NSRange(location: clampUTF16(engine.cursor), length: 0))
        if let sel = engine.visualSelection, engine.mode.isVisual {
            let loc = clampUTF16(sel.lowerBound)
            let end = clampUTF16(sel.upperBound)
            setSelectedRange(NSRange(location: loc, length: max(0, end - loc)))
        }
        if replaced {
            queueRestyle(dirty: nil)
        } else if focusMode {
            queueRestyle(dirty: engine.cursor)
        }
        noteContentSizeChanged()
        revealCaret()
    }

    func applyResult(_ result: EngineResult) {
        var applied: [TextEdit] = []
        if result.didChangeText {
            if result.edits.isEmpty {
                string = engine.text
                tokenizer = MarkdownTokenizer(text: string)
            } else if let storage = textStorage {
                var ok = true
                for edit in result.edits {
                    let nsRange = nsRange(edit.range)
                    if nsRange.location != NSNotFound, NSMaxRange(nsRange) <= storage.length {
                        storage.replaceCharacters(in: nsRange, with: edit.replacement)
                    } else {
                        ok = false
                        break
                    }
                }
                if ok {
                    applied = result.edits
                } else {
                    string = engine.text
                    tokenizer = MarkdownTokenizer(text: string)
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
        if result.didChangeText {
            queueRestyle(dirty: dirty, edits: applied)
        } else if focusMode {
            queueRestyle(dirty: engine.cursor)
        }
        noteContentSizeChanged()
        revealCaret()
        if isDirectoryBuffer { needsDisplay = true }
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

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard isDirectoryBuffer, engine != nil else { return }
        drawDirectoryDecorations()
    }

    override func drawBackground(in rect: NSRect) {
        guard isDirectoryBuffer else {
            super.drawBackground(in: rect)
            return
        }
        drawDirectoryBackground(in: rect)
    }

    override func setSelectedRange(
        _ charRange: NSRange,
        affinity: NSSelectionAffinity,
        stillSelecting stillSelectingFlag: Bool
    ) {
        super.setSelectedRange(charRange, affinity: affinity, stillSelecting: stillSelectingFlag)
        if isDirectoryBuffer {
            needsDisplay = true
        }
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

    func queueRestyle(dirty: Int? = nil, edits: [TextEdit] = [], viewport: Range<Int>? = nil) {
        if isDirectoryBuffer {
            directoryGhostHeight = restyleDirectoryBuffer()
            needsDisplay = true
            noteContentSizeChanged()
            return
        }
        guard !restyleQueued else { return }
        restyleQueued = true
        defer { restyleQueued = false }
        guard let storage = textStorage else { return }
        // Attribute edits used to hop to the next turn, so the key handler
        // returned before styling. Doing it here puts that cost on the keystroke.
        var styleLimit: Range<Int>? = viewport
        if viewport == nil, !edits.isEmpty, tokenizer.acceptsEdits {
            var covered = 0..<0
            for edit in edits {
                let changed = tokenizer.apply(
                    start: edit.range.lowerBound,
                    removedUTF16: edit.range.count,
                    replacement: edit.replacement
                )
                if covered.isEmpty {
                    covered = changed
                } else {
                    covered = min(covered.lowerBound, changed.lowerBound)..<max(covered.upperBound, changed.upperBound)
                }
            }
            let span = tokenizer.lineSpan(covered)
            if focusMode {
                let focus = tokenizer.paragraphRange(containing: engine.cursor)
                styleLimit = min(span.lowerBound, focus.lowerBound)..<max(span.upperBound, focus.upperBound)
            } else {
                styleLimit = span
            }
        } else if viewport == nil, tokenizer.acceptsEdits, storage.length == tokenizer.utf16Count {
            if let dirty {
                styleLimit = tokenizer.paragraphRange(containing: dirty)
            }
        } else if viewport == nil {
            tokenizer.replace(text: storage.string, dirtyUTF16: dirty ?? 0)
            if let dirty {
                styleLimit = tokenizer.paragraphRange(containing: dirty)
            }
        }
        if styleLimit == nil {
            // A nil limit used to paint every line. Opening a 10k-line note
            // spent the time in that attribute pass, and the runs it created
            // made the next insert at the top of the file walk the buffer.
            styleLimit = viewportUTF16()
        }
        shiftCoverage(for: edits)
        let limit = styleLimit ?? 0..<0
        let visibleSpans = limit.isEmpty ? [] : tokenizer.spans(overlapping: limit)
        let focusParagraph = focusMode ? tokenizer.paragraphRange(containing: engine.cursor) : nil
        MarkdownStyler.restyle(
            storage,
            theme: theme,
            spans: visibleSpans,
            dirtyUTF16: dirty,
            paragraphUTF16: styleLimit,
            focus: focusMode,
            caret: engine.cursor,
            focusParagraph: focusParagraph,
            diagnostics: diagnosticRanges
        )
        if let styleLimit, !styleLimit.isEmpty {
            noteStyled(styleLimit)
        }
        noteContentSizeChanged()
    }

    /// Lines that fit in the clip, plus a short margin, so a keystroke does not
    /// style the whole note and a scroll has the next screen ready.
    private func viewportLineBounds() -> Range<Int> {
        let count = engine.buffer.lineCount
        guard count > 0 else { return 0..<0 }
        let row = max(rowHeight(), 1)
        let clip = enclosingScrollView?.contentView.bounds ?? .zero
        let height = clip.height > 2 ? clip.height : 600
        let originY = textContainerOrigin.y
        let top = clip.height > 2 ? clip.minY : 0
        let first = max(0, Int(floor((top - originY) / row)) - 4)
        let last = min(count, max(first + 1, Int(ceil((top + height - originY) / row)) + 8))
        return first..<last
    }

    private func viewportLastLine() -> Int {
        let lines = viewportLineBounds()
        guard !lines.isEmpty else { return 0 }
        return lines.upperBound - 1
    }

    private func viewportUTF16() -> Range<Int> {
        let lines = viewportLineBounds()
        guard !lines.isEmpty, tokenizer.acceptsEdits, tokenizer.utf16Count > 0 else { return 0..<0 }
        return tokenizer.lineSpan(lines)
    }

    private func coverageContains(_ range: Range<Int>) -> Bool {
        !styledCoverage.isEmpty
            && styledCoverage.lowerBound <= range.lowerBound
            && styledCoverage.upperBound >= range.upperBound
    }

    private func noteStyled(_ range: Range<Int>) {
        if styledCoverage.isEmpty {
            styledCoverage = range
            return
        }
        let overlaps = range.lowerBound <= styledCoverage.upperBound + 1
            && styledCoverage.lowerBound <= range.upperBound + 1
        guard overlaps else { return }
        styledCoverage = min(styledCoverage.lowerBound, range.lowerBound)..<max(styledCoverage.upperBound, range.upperBound)
    }

    private func shiftCoverage(for edits: [TextEdit]) {
        guard !styledCoverage.isEmpty else { return }
        for edit in edits {
            let delta = edit.replacement.utf16.count - edit.range.count
            guard delta != 0 else { continue }
            if edit.range.lowerBound < styledCoverage.lowerBound {
                styledCoverage = (styledCoverage.lowerBound + delta)..<(styledCoverage.upperBound + delta)
            } else if edit.range.lowerBound < styledCoverage.upperBound {
                styledCoverage = styledCoverage.lowerBound..<(styledCoverage.upperBound + delta)
            }
        }
    }

    private func restyleVisibleIfNeeded() {
        guard !restyleQueued, !isDirectoryBuffer else { return }
        let viewport = viewportUTF16()
        guard !viewport.isEmpty, !coverageContains(viewport) else { return }
        queueRestyle(dirty: nil, edits: [], viewport: viewport)
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
        let painted = isDirectoryBuffer ? theme.directoryBackgroundColor : theme.backgroundColor
        if caretChrome.superview === self,
           caretChrome.isHidden == !show,
           placedCaretMatches(cell, index: index, painted: painted) {
            return
        }
        if caretChrome.superview !== self {
            orderingCaret = true
            addSubview(caretChrome)
            orderingCaret = false
        }
        caretChrome.frame = cell
        let accent = CaretInk.accent(for: painted)
        caretChrome.accent = accent
        caretChrome.blockAlpha = CGFloat(CaretGeometry.blockFillAlpha)
        let shapeIsBeam = engine.mode == .insert
        caretChrome.kind = shapeIsBeam ? .beam : .block
        if shapeIsBeam {
            caretChrome.glyph = nil
        } else if let redraw = CaretInk.glyphRedraw(text: theme.textColor, accent: accent, background: painted),
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
        placedPainted = painted.caretRGB()
    }

    private var placedMode: Mode?
    private var placedIndex = -1
    private var placedPainted: CaretRGB?

    private func placedCaretMatches(_ cell: NSRect, index: Int, painted: NSColor) -> Bool {
        guard placedMode == engine.mode, placedIndex == index else { return false }
        guard let previous = placedPainted, let next = painted.caretRGB() else { return false }
        guard abs(previous.r - next.r) < 0.01,
              abs(previous.g - next.g) < 0.01,
              abs(previous.b - next.b) < 0.01 else { return false }
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
        if isDirectoryBuffer {
            return QuillMetrics.directoryRowHeight(for: font ?? theme.directoryFont)
        }
        let caretFont = font ?? theme.bodyFont
        return max(1, (caretFont.ascender - caretFont.descender) * theme.lineHeight)
    }

    private func fittedContentHeight() -> CGFloat {
        let inset = textContainerInset.height * 2
        let clip = enclosingScrollView?.contentSize.height ?? bounds.height
        // Buffer lines, not a forced full TextKit layout. `usageBounds` lays
        // out every fragment, which is what made scrolling a long file hitch.
        let rows = max(1, engine.buffer.lineCount)
        let estimated = CGFloat(rows) * rowHeight() + inset
        let ghosts = isDirectoryBuffer ? directoryGhostHeight : 0
        return max(clip, ceil(estimated)) + ghosts
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

    private func paragraphStyle(atUTF16 index: Int) -> NSParagraphStyle {
        let fallback = defaultParagraphStyle ?? NSParagraphStyle.default
        guard let storage = textStorage, storage.length > 0 else { return fallback }
        let probe = min(max(0, index), storage.length - 1)
        return (storage.attribute(.paragraphStyle, at: probe, effectiveRange: nil) as? NSParagraphStyle) ?? fallback
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
    private func lineMetrics(atUTF16 index: Int, forcingLayout _: Bool) -> LineMetrics? {
        guard let lm = textLayoutManager else { return nil }
        // Lay out the fragment under the caret only. A full-document layout
        // here walked every line on each caret move.
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
        let container = textContainerOrigin
        let fragmentFrame = fragment.layoutFragmentFrame
        // A trailing newline grows an extra line fragment with an empty range.
        // Its typographic bounds are wrong (FB15131180): the origin is too high and
        // the height drops the paragraph's line spacing, so the em box lands on the
        // fragment top. Place it from the previous line's bottom instead.
        if clamped >= length, lines.last?.characterRange.length == 0 {
            let content = lines.dropLast().last
            let lineTop: CGFloat
            let lineMinX: CGFloat
            if let content {
                let bounds = content.typographicBounds
                lineTop = container.y + fragmentFrame.minY + bounds.maxY
                lineMinX = container.x + fragmentFrame.minX + bounds.minX
            } else {
                lineTop = container.y + fragmentFrame.minY
                lineMinX = container.x + fragmentFrame.minX
            }
            let caretFont = font(atUTF16: clamped)
            let style = paragraphStyle(atUTF16: max(0, length - 1))
            let baseline = CaretGeometry.extraLineBaseline(
                previousLineMaxY: Double(lineTop),
                ascender: Double(caretFont.ascender),
                descender: Double(caretFont.descender),
                leading: Double(caretFont.leading),
                lineHeightMultiple: Double(style.lineHeightMultiple),
                lineSpacing: Double(style.lineSpacing),
                minimumLineHeight: Double(style.minimumLineHeight),
                maximumLineHeight: Double(style.maximumLineHeight)
            )
            return LineMetrics(
                originX: lineMinX,
                baselineY: CGFloat(baseline),
                lineMinX: lineMinX,
                lineWidth: 0
            )
        }
        let line = lines.first { candidate in
            let span = candidate.characterRange
            return local >= span.location && local < span.location + max(span.length, 1)
        } ?? lines.last
        guard let line else { return nil }
        let charIndex = max(0, local - line.characterRange.location)
        let point = line.locationForCharacter(at: min(charIndex, max(0, line.characterRange.length)))
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
        restyleVisibleIfNeeded()
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
        tv.columnWidth = model.theme.columnWidth
        tv.isDirectoryBuffer = model.isDirectory
        tv.directoryURL = model.isDirectory ? model.fileURL : nil
        tv.directoryEntries = model.isDirectory ? (model.directorySnapshot?.entries ?? []) : []
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
        let entries = model.isDirectory ? (model.directorySnapshot?.entries ?? []) : []
        let url = model.isDirectory ? model.fileURL : nil
        let directoryChanged = tv.isDirectoryBuffer != model.isDirectory
            || tv.directoryURL != url
            || tv.directoryEntries != entries
        tv.isDirectoryBuffer = model.isDirectory
        tv.directoryURL = url
        tv.directoryEntries = entries
        let diagnostics = model.nsDiagnosticRanges()
        let diagnosticsChanged = tv.diagnosticRanges.map(\.0) != diagnostics.map(\.0)
        if diagnosticsChanged { tv.diagnosticRanges = diagnostics }
        WindowChrome.apply(theme: model.theme)
        if model.isDirectory {
            scroll.drawsBackground = true
            scroll.backgroundColor = model.theme.directoryBackgroundColor
            tv.window?.backgroundColor = model.theme.directoryBackgroundColor
        } else {
            scroll.drawsBackground = false
        }
        if tv.appliedThemeID != model.themeIdentity || tv.appliedFocus != model.focusMode || directoryChanged {
            tv.applyTheme(model.theme, focus: model.focusMode)
            tv.appliedThemeID = model.themeIdentity
            tv.appliedFocus = model.focusMode
        } else {
            tv.updateInsets()
        }
        let caret = min(model.engine.cursor, (tv.string as NSString).length)
        let bufferReplaced = context.coordinator.syncedRevision != revision
        // A keystroke already updated this view. Comparing the whole string
        // here, or treating that keystroke's revision bump as a buffer swap,
        // restyled the document again on every character.
        if bufferReplaced || tv.selectedRange().location != caret {
            if bufferReplaced {
                tv.syncFromEngine()
            } else if tv.string != model.engine.text {
                tv.syncFromEngine()
            } else if model.focusMode {
                tv.queueRestyle(dirty: caret)
            }
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
            model?.handleEngineResult(result, fromTextView: true)
        }

        func vimTextViewDidClick(_ view: VimTextView, characterOffset: Int, commandClick: Bool) {
            if commandClick {
                model?.goToDefinition()
            }
        }
    }
}
