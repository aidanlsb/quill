import AppKit
import SwiftUI
import QuillFS
import QuillMarkdown
import QuillText
import QuillVim

/// Screen rows from TextKit 2 line fragments. Only character ranges are read:
/// display columns, caret placement, and motion live in `ScreenModel`, so glyph
/// widths (headings, bold, kerned table pads) cannot move the caret.
// quill-concurrency: ScreenLayout is nonisolated and the main-actor key loop is the only caller.
@MainActor
final class TextKit2Layout: ScreenLayout, @unchecked Sendable {
    weak var textView: NSTextView?

    nonisolated func gapRows(after line: BufferLine, in buffer: TextBuffer) -> Int {
        // Preview height lives on the view. `line` already names the buffer row.
        _ = buffer
        return MainActor.assumeIsolated {
            guard let tv = textView as? VimTextView else { return 0 }
            return tv.imageGapRows(on: line.index)
        }
    }

    nonisolated func rowRanges(of line: BufferLine, in buffer: TextBuffer) -> [Range<Int>]? {
        // quill-concurrency: TextBuffer is not Sendable; the engine calls this synchronously on the main thread.
        nonisolated(unsafe) let buffer = buffer
        return MainActor.assumeIsolated {
            rows(of: line, in: buffer)
        }
    }

    /// Document ranges of the line fragments of `line`. `characterRange` is
    /// relative to its layout fragment. A buffer line ends only at `\n`, but TextKit
    /// also starts a paragraph at U+2029, so one buffer line can span several layout
    /// fragments; all of them up to `contentEnd` are read. `ScreenModel` clips these
    /// to the line and rejects anything that does not tile it, so a stale or partial
    /// layout degrades to one row, never a jump.
    private func rows(of line: BufferLine, in buffer: TextBuffer) -> [Range<Int>]? {
        guard !line.isEmpty, viewMatches(buffer), let tv = textView, let lm = tv.textLayoutManager else { return nil }
        let doc = lm.documentRange.location
        var rows: [Range<Int>] = []
        var at = line.start
        while at < line.contentEnd {
            ensureLayout(at: at, layout: lm)
            guard let location = lm.location(doc, offsetBy: at),
                  let fragment = lm.textLayoutFragment(for: location) else { return nil }
            let fragmentStart = lm.offset(from: doc, to: fragment.rangeInElement.location)
            let fragmentEnd = lm.offset(from: doc, to: fragment.rangeInElement.endLocation)
            guard fragmentStart != NSNotFound, fragmentEnd != NSNotFound, fragmentStart <= at, fragmentEnd > at else {
                return rows.isEmpty ? nil : rows
            }
            for row in fragment.textLineFragments {
                let range = row.characterRange
                guard range.location != NSNotFound, range.length > 0 else { continue }
                let start = fragmentStart + range.location
                rows.append(start..<(start + range.length))
            }
            at = fragmentEnd
        }
        return rows
    }

    /// Screen rows belong to the view only while it still holds this buffer.
    /// A directory reload updates the engine first; the previous note's line
    /// breaks must not be applied to the listing.
    private func viewMatches(_ buffer: TextBuffer) -> Bool {
        guard let tv = textView else { return false }
        let viewLength = (tv.string as NSString).length
        return viewLength == buffer.count
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
        let length = lm.offset(from: lm.documentRange.location, to: lm.documentRange.endLocation)
        QuillTrace.write("quill boot layout-full-len \(length)\n")
        guard length != NSNotFound, length > 0 else { return }
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
    /// Return true to consume the key. Esc dismisses the list and returns false so insert mode still ends.
    func vimTextView(_ view: VimTextView, handleCompletionKey key: KeyEvent) -> Bool
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
    /// Left unset until `host` or `applyTheme`. Building a theme here measured fonts on every view, including the launch view that already has the model theme.
    private var themeStorage: QuillTheme?
    var theme: QuillTheme {
        get {
            if let themeStorage { return themeStorage }
            let built = QuillTheme.current()
            themeStorage = built
            return built
        }
        set { themeStorage = newValue }
    }
    var diagnosticRanges: [(NSRange, Int)] = []
    var directoryStyleCache: DirectoryStyle?
    /// Tests watch reloads, row invalidation, and directory painting. Nil in the app.
    var onReload: (@MainActor () -> Void)?
    /// Last `Document.refreshID` applied to this view. A background window reloads when it moves.
    var seenRefresh = -1
    var onNeedsDisplay: (@MainActor (NSRect) -> Void)?
    var onDirectoryDecorations: (@MainActor () -> Void)?
    private var restyleQueued = false
    /// Stops `string =` from re-entering the drift repair.
    private var repairingDocument = false
    private var sizing = false
    /// True while `viewDidEndLiveResize` has cleared the inset for `super`.
    private var endingLiveResize = false
    /// Setting the text container lays out, which can call back into this view.
    private var updatingInsets = false
    /// Clip width the current inset was computed from. Scrolling changes the origin only.
    private var appliedClipWidth: CGFloat = -1
    /// Vertical clip origin to restore after the inset change in progress.
    private var resizeAnchorY: CGFloat?
    private weak var observedClip: NSClipView?
    private var tokenizer = MarkdownTokenizer(text: "")
    /// UTF-16 ranges already given span attributes. A gap between two styled
    /// screens is not covered; scrolling into it styles that screen only.
    private var styledCoverage = 0..<0
    /// Set when this document's visible spans have been written into the text storage.
    var didApplyDocumentStyle = false
    /// The startup probe counts one acceptance key. Stays false for every other key.
    var startupCountKeys = false
    var startupKeyEvents = 0
    var startupDidAcceptKey = false
    /// Mono cells that fit the column when a table was last painted. Whether a
    /// table is aligned or shown as typed depends on it, so a change repaints.
    private var paintedTableFit: Int?
    /// Set when the column width changes; the next `layout()` outside a live
    /// resize makes sure the caret is visible.
    private var revealAfterRewrap = false
    /// Read by `EditorView` in this file. `private` would hide them from that type.
    fileprivate var appliedThemeID = -1
    fileprivate var appliedFocus = false
    private var mouseAnchor: Int?
    private let caretChrome = CaretChrome(frame: .zero)
    private var placingCaret = false
    private var orderingCaret = false
    /// `revealCaret` scrolls, and that scroll restyles the new lines. Restyle
    /// moves the caret, so a second pass measures again. The flag stops that
    /// pass from re-entering through the clip notification.
    private var revealingCaret = false
    let imagePreviews = ImagePreviewController()

    override func awakeFromNib() {
        super.awakeFromNib()
        commonInit()
    }

    /// The only way to create an editor view bound to an engine.
    /// `EditorView`, `AppPerf`, and tests use it.
    static func host(
        engine: Engine,
        frame: NSRect = NSRect(x: 0, y: 0, width: 800, height: 600),
        theme: QuillTheme? = nil
    ) -> (scroll: NSScrollView, view: VimTextView) {
        let hostBegan = StartupProbe.begin("hostMs")
        defer { StartupProbe.end("hostMs", hostBegan) }
        let scroll = NSScrollView(frame: frame)
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        scroll.autohidesScrollers = true
        let tv = VimTextView.make()
        if let theme {
            tv.theme = theme
        }
        // setFrameSize measures the buffer. Bind the engine first, and give the
        // text container the clip width before any caller copies the text in.
        // A zero-width container traps TextKit on a long line.
        tv.engine = engine
        engine.layout = tv.layoutAdapter
        tv.commonInit()
        tv.minSize = NSSize(width: 0, height: 0)
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        scroll.documentView = tv
        tv.frame = frame
        tv.updateInsets()
        return (scroll, tv)
    }

    private func commonInit() {
        layoutAdapter.textView = self
        imagePreviews.attach(self)
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

    /// TextKit 2 view. Callers use `host(engine:frame:)`.
    private static func make(frame: NSRect = .zero) -> VimTextView {
        let view = VimTextView(usingTextLayoutManager: true)
        if frame != .zero {
            view.frame = frame
        }
        return view
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
            typingAttributes = theme.bodyAttributes
        }
        if !directory {
            directoryGhostHeight = 0
            directoryHeaderText = ""
        }
        invalidateDirectoryStyle()
        updateInsets()
        queueRestyle()
        imagePreviews.applyTheme()
        placeCaret()
    }

    func updateInsets(preservingOriginY: CGFloat? = nil) {
        if endingLiveResize || updatingInsets { return }
        guard let scroll = enclosingScrollView else { return }
        let clip = scroll.contentView
        let width = max(clip.bounds.width, 1)
        let target = columnMetrics(clipWidth: width)
        let currentColumn = textContainer?.size.width ?? -1
        let oldVertical = textContainerInset.height
        let hadInsets = textContainerInset.width > 0.5 || oldVertical > 0.5
        let metricsMatch = abs(textContainerInset.width - target.inset) < 0.5
            && abs(oldVertical - target.vertical) < 0.5
            && abs(currentColumn - target.column) < 0.5
        appliedClipWidth = width
        let baseline = preservingOriginY ?? clip.bounds.origin.y
        if metricsMatch {
            if preservingOriginY != nil, hadInsets {
                resizeAnchorY = baseline
                pinVerticalOrigin(baseline)
            }
            return
        }
        let columnChanged = abs(currentColumn - target.column) > 0.5
        defer {
            if columnChanged {
                refitTables()
                if hadInsets {
                    revealAfterRewrap = true
                    needsLayout = true
                }
            }
        }
        let caretBefore = (hadInsets && columnChanged) ? caretDocumentMidY() : nil
        updatingInsets = true
        textContainerInset = NSSize(width: target.inset, height: target.vertical)
        textContainer?.size = NSSize(width: max(1, target.column), height: CGFloat.greatestFiniteMagnitude)
        updatingInsets = false
        guard hadInsets else { return }
        let origin: CGFloat
        if let caretBefore, let caretAfter = caretDocumentMidY() {
            origin = baseline + (caretAfter - caretBefore)
        } else {
            origin = baseline + (target.vertical - oldVertical)
        }
        resizeAnchorY = origin
        pinVerticalOrigin(origin)
    }

    private func columnMetrics(clipWidth: CGFloat) -> (inset: CGFloat, vertical: CGFloat, column: CGFloat) {
        if isDirectoryBuffer {
            let inset = QuillMetrics.directoryHorizontalInset
            let vertical = QuillMetrics.directoryHeaderHeight + QuillMetrics.directoryHeaderGap
            return (inset, vertical, max(1, clipWidth - inset * 2))
        }
        let vertical = focusMode ? QuillMetrics.focusVerticalInset : QuillMetrics.verticalInset
        let span = QuillMetrics.columnSpan(width: clipWidth, column: columnWidth)
        return (span.inset, vertical, span.column)
    }

    func reload() {
        let reloadBegan = StartupProbe.begin("reloadMs")
        defer { StartupProbe.end("reloadMs", reloadBegan) }
        MainActor.assumeIsolated { self.onReload?() }
        invalidateDirectoryStyle()
        let text = engine.text
        let replaced = string != text
        if replaced {
            didApplyDocumentStyle = false
            let began = DispatchTime.now().uptimeNanoseconds
            string = text
            QuillPerfSplit.add("syncStringMs", since: began)
            let tokenBegan = DispatchTime.now().uptimeNanoseconds
            let through = viewportLastLine()
            tokenizer = MarkdownTokenizer(text: text, scanThroughLine: through)
            styledCoverage = 0..<0
            imagePreviews.noteDocumentReplaced()
            QuillPerfSplit.add("syncTokenMs", since: tokenBegan)
        }
        setSelectedRange(NSRange(location: clampUTF16(engine.cursor), length: 0))
        if let sel = engine.visualSelection, engine.mode.isVisual {
            let loc = clampUTF16(sel.lowerBound)
            let end = clampUTF16(sel.upperBound)
            setSelectedRange(NSRange(location: loc, length: max(0, end - loc)))
        }
        if replaced {
            let began = DispatchTime.now().uptimeNanoseconds
            queueRestyle(dirty: nil)
            QuillPerfSplit.add("syncStyleMs", since: began)
        } else if focusMode {
            queueRestyle(dirty: engine.cursor)
        }
        let frameBegan = DispatchTime.now().uptimeNanoseconds
        noteContentSizeChanged()
        QuillPerfSplit.add("syncFrameMs", since: frameBegan)
        let revealBegan = DispatchTime.now().uptimeNanoseconds
        revealCaret()
        QuillPerfSplit.add("syncRevealMs", since: revealBegan)
    }

    func applyResult(_ result: EngineResult) {
        if result.didChangeText {
            invalidateDirectoryStyle()
        }
        var applied: [TextEdit] = []
        if result.didChangeText {
            let delta = result.edits.reduce(0) { $0 + $1.replacement.utf16.count - $1.range.count }
            let previous = engine.buffer.count - delta
            // TextKit 2 can leave `textStorage.length` behind `string`. Patching
            // that short storage would edit the wrong document, so replace it.
            if result.edits.isEmpty || textStorage?.length != previous {
                string = engine.text
                tokenizer = MarkdownTokenizer(text: string)
            } else if let storage = textStorage {
                var ok = true
                let replaceBegan = DispatchTime.now().uptimeNanoseconds
                for edit in result.edits {
                    let nsRange = nsRange(edit.range)
                    if nsRange.location != NSNotFound, NSMaxRange(nsRange) <= storage.length {
                        storage.replaceCharacters(in: nsRange, with: edit.replacement)
                    } else {
                        ok = false
                        break
                    }
                }
                QuillPerfSplit.add("keyReplaceMs", since: replaceBegan)
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
            let began = DispatchTime.now().uptimeNanoseconds
            queueRestyle(dirty: dirty, edits: applied)
            QuillPerfSplit.add("keyRestyleMs", since: began)
        } else if focusMode {
            queueRestyle(dirty: engine.cursor)
        }
        let caretBegan = DispatchTime.now().uptimeNanoseconds
        noteContentSizeChanged()
        revealCaret()
        QuillPerfSplit.add("keyCaretMs", since: caretBegan)
        if result.didChangeText {
            if result.edits.isEmpty {
                imagePreviews.noteDocumentReplaced()
            } else {
                imagePreviews.noteEdits(result.edits)
            }
        }
        vimDelegate?.vimTextView(self, didHandle: result)
        assertViewMatchesEngine()
    }

    func useThisLayout() {
        engine.layout = layoutAdapter
    }

    /// A background window reloads when the shared buffer changes. The key window already patched itself.
    func syncFromEngine(isEditor: Bool, refresh: Int) {
        if seenRefresh == refresh { return }
        seenRefresh = refresh
        if isEditor { return }
        reload()
    }

    override func keyDown(with event: NSEvent) {
        useThisLayout()
        if event.modifierFlags.contains(.command) {
            super.keyDown(with: event)
            return
        }
        if hasMarkedText() || event.characters?.isEmpty != false {
            // A synthetic event with no window crashes NSTextView's key binding.
            if event.window == nil { return }
            super.keyDown(with: event)
            return
        }
        guard let key = KeyEvent(nsEvent: event) else {
            if event.window == nil { return }
            super.keyDown(with: event)
            return
        }
        if vimDelegate?.vimTextView(self, handleCompletionKey: key) == true {
            assertViewMatchesEngine()
            return
        }
        engine.scrollLineCount = halfPageLines()
        if startupCountKeys { startupKeyEvents += 1 }
        let result = engine.handle(key)
        applyResult(result)
        if result.beep {
            NSSound.beep()
        }
    }

    private func assertViewMatchesEngine() {
        #if DEBUG
        // A host command can replace the buffer before this returns. The model's
        // editor reloads inside that command; a view the model does not own
        // still has the previous document, so put the engine text back.
        let length = (string as NSString).length
        guard length != engine.buffer.count, !repairingDocument else { return }
        repairingDocument = true
        string = engine.text
        repairingDocument = false
        #endif
    }

    override func mouseDown(with event: NSEvent) {
        useThisLayout()
        super.mouseDown(with: event)
        let offset = clampUTF16(selectedRange().location)
        mouseAnchor = offset
        _ = engine.moveCursor(to: offset)
        if focusMode {
            queueRestyle(dirty: engine.cursor)
        }
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
        if revealAfterRewrap, !sizing, !inLiveResize {
            revealAfterRewrap = false
            revealCaretIfHidden()
        }
        placeCaret(forcingLayout: false)
        imagePreviews.reposition()
    }

    override func draw(_ dirtyRect: NSRect) {
        let probing = StartupProbe.recordsDraw
        let styled = probing && didApplyDocumentStyle
        let length = probing ? (textStorage?.length ?? 0) : 0
        super.draw(dirtyRect)
        if probing {
            StartupProbe.noteDrew(length: length, styled: styled)
        }
        guard isDirectoryBuffer, engine != nil else { return }
        drawDirectoryDecorations(in: dirtyRect)
    }

    override func drawBackground(in rect: NSRect) {
        guard isDirectoryBuffer else {
            super.drawBackground(in: rect)
            return
        }
        drawDirectoryBackground(in: rect)
    }

    override func setNeedsDisplay(_ invalidRect: NSRect) {
        MainActor.assumeIsolated { self.onNeedsDisplay?(invalidRect) }
        super.setNeedsDisplay(invalidRect)
    }

    override func setSelectedRange(
        _ charRange: NSRange,
        affinity: NSSelectionAffinity,
        stillSelecting stillSelectingFlag: Bool
    ) {
        let previous = selectedRange().location
        super.setSelectedRange(charRange, affinity: affinity, stillSelecting: stillSelectingFlag)
        if isDirectoryBuffer {
            invalidateDirectoryCaret(from: previous, to: charRange.location)
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
        let originY = enclosingScrollView?.contentView.bounds.origin.y
        let columnBefore = textContainer?.size.width ?? -1
        resizeAnchorY = nil
        let visible = visibleWidth(proposed: newSize.width)
        // Height-only frame changes must leave an inset a caller just set. The
        // caret smoke pins a 12×36 inset and then clears it; recomputing here
        // would put the writing column back.
        if abs(visible - appliedClipWidth) > 0.5 {
            updateInsets(preservingOriginY: originY)
        }
        let columnAfter = textContainer?.size.width ?? columnBefore
        var size = newSize
        size.width = visibleWidth(proposed: newSize.width)
        let columnChanged = abs(columnAfter - columnBefore) > 0.5
        if inLiveResize, !columnChanged, bounds.height > 1 {
            size.height = max(size.height, bounds.height)
        } else {
            size.height = max(size.height, fittedContentHeight())
        }
        let anchor = resizeAnchorY
        super.setFrameSize(size)
        sizing = false
        if let anchor {
            pinVerticalOrigin(anchor)
            resizeAnchorY = nil
        }
    }

    override func viewDidEndLiveResize() {
        let originY = enclosingScrollView?.contentView.bounds.origin.y ?? 0
        let preserved = textContainerInset
        // NSTextView scrolls by about the vertical inset when a live resize ends.
        // Hide the inset from that adjustment, then put the column back.
        endingLiveResize = true
        textContainerInset = .zero
        super.viewDidEndLiveResize()
        textContainerInset = preserved
        endingLiveResize = false
        appliedClipWidth = -1
        resizeAnchorY = nil
        updateInsets(preservingOriginY: originY)
        if !sizing {
            sizing = true
            let height = fittedContentHeight()
            let width = visibleWidth(proposed: bounds.width)
            if abs(bounds.height - height) > 1 || abs(bounds.width - width) > 1 {
                super.setFrameSize(NSSize(width: width, height: height))
            }
            sizing = false
        }
        if let anchor = resizeAnchorY {
            pinVerticalOrigin(anchor)
            resizeAnchorY = nil
        }
        if revealAfterRewrap { needsLayout = true }
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        observeClipView()
    }

    private func observeClipView() {
        if let old = observedClip {
            NotificationCenter.default.removeObserver(self, name: NSView.boundsDidChangeNotification, object: old)
            NotificationCenter.default.removeObserver(self, name: NSView.frameDidChangeNotification, object: old)
        }
        guard let clip = enclosingScrollView?.contentView else {
            observedClip = nil
            return
        }
        observedClip = clip
        clip.postsBoundsChangedNotifications = true
        clip.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(clipViewBoundsChanged(_:)),
            name: NSView.boundsDidChangeNotification,
            object: clip
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(clipViewBoundsChanged(_:)),
            name: NSView.frameDidChangeNotification,
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
        let styleBegan = StartupProbe.begin("restyleMs")
        defer { StartupProbe.end("restyleMs", styleBegan) }
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
        var plainShift = false
        var tableEdit = false
        if viewport == nil, !edits.isEmpty, tokenizer.acceptsEdits {
            plainShift = !focusMode
            var covered = 0..<0
            for edit in edits {
                let delta = edit.replacement.utf16.count - edit.range.count
                let probe = min(edit.range.lowerBound, max(0, tokenizer.utf16Count - 1))
                if tokenizer.lineContainsPipe(at: probe) { tableEdit = true }
                let beforeRange = tokenizer.lineContentSpan(containing: probe)
                let beforeSpans = beforeRange.isEmpty ? [] : tokenizer.spans(overlapping: beforeRange)
                let styled = !beforeRange.isEmpty && coverageContains(beforeRange)
                let changed = tokenizer.apply(
                    start: edit.range.lowerBound,
                    removedUTF16: edit.range.count,
                    replacement: edit.replacement
                )
                let afterProbe = min(edit.range.lowerBound, max(0, tokenizer.utf16Count - 1))
                if tokenizer.lineContainsPipe(at: afterProbe) { tableEdit = true }
                let afterRange = tokenizer.lineSpan(changed)
                let afterSpans = afterRange.isEmpty ? [] : tokenizer.spans(overlapping: afterRange)
                if !styled || !MarkdownTokenizer.spansFollowEdit(
                    beforeSpans,
                    afterSpans,
                    editAt: edit.range.lowerBound,
                    delta: delta
                ) || Self.editRewritesListMarker(beforeSpans, edit) {
                    plainShift = false
                }
                if covered.isEmpty {
                    covered = changed
                } else {
                    covered = min(covered.lowerBound, changed.lowerBound)..<max(covered.upperBound, changed.upperBound)
                }
            }
            if tableEdit {
                // A cell edit changes column widths without changing markdown tokens.
                // The plain-shift path would keep the previous kern.
                plainShift = false
            }
            if !plainShift {
                let span = tokenizer.lineSpan(covered)
                if focusMode {
                    let focus = tokenizer.paragraphRange(containing: engine.cursor)
                    styleLimit = min(span.lowerBound, focus.lowerBound)..<max(span.upperBound, focus.upperBound)
                } else {
                    styleLimit = span
                }
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
        if plainShift {
            // The edit did not change tokens. AppKit shifted the runs already
            // on this line; painting them again invalidates layout past the caret.
            shiftCoverage(for: edits)
            didApplyDocumentStyle = true
            return
        }
        if styleLimit == nil {
            // A nil limit used to paint every line. Opening a 10k-line note
            // spent the time in that attribute pass, and the runs it created
            // made the next insert at the top of the file walk the buffer.
            styleLimit = viewportUTF16()
        }
        shiftCoverage(for: edits)
        var limit = styleLimit ?? 0..<0
        let tables = tablesOverlapping(limit)
        if !tables.isEmpty {
            limit = tablePaintRange(limit, tables: tables)
            styleLimit = limit
            paintedTableFit = tableFit()
        }
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
            diagnostics: diagnosticRanges,
            tables: tables,
            tableColumnWidth: textContainer?.size.width
        )
        if let styleLimit, !styleLimit.isEmpty {
            noteStyled(styleLimit)
        }
        didApplyDocumentStyle = true
        imagePreviews.restoreSpacing(in: styleLimit)
        noteContentSizeChanged()
    }

    /// Replacing the bullet or the checkbox changes the hanging indent without
    /// changing the token's range. A plain shift would keep the old width.
    private static func editRewritesListMarker(_ spans: [TokenSpan], _ edit: TextEdit) -> Bool {
        let start = edit.range.lowerBound
        let end = edit.range.isEmpty ? start + 1 : edit.range.upperBound
        for span in spans where span.token == .listMarker || span.token == .taskBox {
            // The space after a checkbox is part of the hang and not its own token.
            let upper = span.token == .taskBox ? span.range.upperBound + 1 : span.range.upperBound
            if start < upper && end > span.range.lowerBound {
                return true
            }
        }
        return false
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
        // `y / row` assumes one row per buffer line. Wrapped lines and headings
        // are taller, so prefer the line TextKit actually laid out at that y.
        let topLine = laidOutLine(atContainerY: top - originY) ?? Int(floor((top - originY) / row))
        let bottomLine = laidOutLine(atContainerY: top + height - originY) ?? Int(ceil((top + height - originY) / row))
        let first = min(count - 1, max(0, topLine - 4))
        let last = min(count, max(first + 1, bottomLine + 8))
        return first..<last
    }

    private func laidOutLine(atContainerY y: CGFloat) -> Int? {
        guard let lm = textLayoutManager,
              let fragment = lm.textLayoutFragment(for: CGPoint(x: 0, y: max(0, y))) else { return nil }
        let offset = lm.offset(from: lm.documentRange.location, to: fragment.rangeInElement.location)
        guard offset != NSNotFound else { return nil }
        return engine.buffer.lineIndex(containing: min(max(0, offset), engine.buffer.count))
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
        // A jump leaves a gap. Remember the screen just painted so the next
        // keystroke there can skip painting. The screen above is styled again
        // when the clip scrolls back onto it.
        guard overlaps else {
            styledCoverage = range
            return
        }
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

    private func tableFit() -> Int? {
        guard let width = textContainer?.size.width else { return nil }
        return MarkdownStyler.fitColumns(width: width, advance: MarkdownStyler.monoAdvance(theme.monoFont))
    }

    /// Off-screen tables keep the old decision until they scroll back into view,
    /// which clearing coverage forces; tables on screen repaint now.
    private func refitTables() {
        guard !isDirectoryBuffer, let painted = paintedTableFit, painted != tableFit() else { return }
        paintedTableFit = nil
        styledCoverage = 0..<0
        let viewport = viewportUTF16()
        guard !tablesOverlapping(viewport).isEmpty else { return }
        queueRestyle(dirty: nil, edits: [], viewport: viewport)
    }

    /// Tables that intersect `limit`, using the tokenizer's line cache.
    /// An empty limit skips the lookup so a plain keystroke does not parse one.
    private func tablesOverlapping(_ limit: Range<Int>) -> [TableBlock] {
        guard tokenizer.acceptsEdits, !limit.isEmpty else { return [] }
        return tokenizer.tableBlocks(overlapping: limit)
    }

    /// Rows on screen, rows already painted, and the edited line. A cell edit
    /// changes every column's kern, including rows the caret is not on.
    /// Off-screen rows are dropped from coverage so the next scroll recomputes them.
    private func tablePaintRange(_ limit: Range<Int>, tables: [TableBlock]) -> Range<Int> {
        let viewport = viewportUTF16()
        let painted = styledCoverage
        var lower = limit.lowerBound
        var upper = limit.upperBound
        for block in tables {
            dropCoverage(overlapping: block.range)
            for row in block.rows {
                let rowEnd = min(block.range.upperBound, row.range.upperBound + 1)
                let span = row.range.lowerBound..<max(row.range.lowerBound + 1, rowEnd)
                if rangesOverlap(span, viewport) || rangesOverlap(span, limit) || rangesOverlap(span, painted) {
                    lower = min(lower, span.lowerBound)
                    upper = max(upper, span.upperBound)
                }
            }
        }
        return lower..<max(lower, upper)
    }

    private func rangesOverlap(_ lhs: Range<Int>, _ rhs: Range<Int>) -> Bool {
        !lhs.isEmpty && !rhs.isEmpty && lhs.lowerBound < rhs.upperBound && rhs.lowerBound < lhs.upperBound
    }

    private func dropCoverage(overlapping range: Range<Int>) {
        guard !styledCoverage.isEmpty else { return }
        let overlaps = range.lowerBound < styledCoverage.upperBound && styledCoverage.lowerBound < range.upperBound
        guard overlaps else { return }
        if styledCoverage.lowerBound < range.lowerBound {
            styledCoverage = styledCoverage.lowerBound..<range.lowerBound
        } else {
            styledCoverage = 0..<0
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

    /// The engine cursor is the caret. NSTextView's selection only follows it, and
    /// AppKit may move that selection on its own (clicks mid-sync, composed
    /// character snapping). Marked text is the exception: the input method owns it.
    private func caretUTF16() -> Int {
        if hasMarkedText() {
            return clampUTF16(selectedRange().location)
        }
        return clampUTF16(engine.cursor)
    }

    private func caretGlyph(atUTF16 index: Int) -> String? {
        let ns = string as NSString
        guard index >= 0, index < ns.length else { return nil }
        let range = ns.rangeOfComposedCharacterSequence(at: index)
        let chunk = ns.substring(with: range)
        if chunk == "\n" || chunk == "\t" || chunk == " " { return nil }
        return chunk
    }

    func noteContentSizeChanged() {
        guard !sizing, enclosingScrollView != nil else { return }
        sizing = true
        let height = fittedContentHeight()
        let width = visibleWidth(proposed: bounds.width)
        if abs(bounds.width - width) > 1 || abs(bounds.height - height) > 1 {
            super.setFrameSize(NSSize(width: width, height: height))
        }
        sizing = false
    }

    func revealCaret() {
        guard let scroll = enclosingScrollView, !revealingCaret else { return }
        revealingCaret = true
        defer { revealingCaret = false }
        let clip = scroll.contentView
        // Measure first: that lays out the caret's paragraph, and the frame
        // height below must already include it. Sizing the frame first left a
        // caret on a wrapped line past the bottom with nowhere to scroll.
        // A fragment above the buffer row is the last piece TextKit has built,
        // not the caret: `G` and search on a long note land in the middle.
        // A fragment at or below that row is the real line, including wrap.
        let row = rowHeight()
        let line = engine.buffer.lineIndex(containing: clampUTF16(engine.cursor))
        let lineCount = max(1, engine.buffer.lineCount)
        // TextKit's laid-out height can exceed one `rowHeight` per buffer line
        // (select-all, wrap, leading). A stale fragment then sits near the short
        // estimate and `G` stops above the end.
        let inset = textContainerInset.height * 2
        let estimatedSpan = CGFloat(lineCount) * row + imagePreviews.reservedHeight
        let extra = max(0, bounds.height - inset - estimatedSpan)
        let progress = CGFloat(line) / CGFloat(max(lineCount - 1, 1))
        let estimated = NSRect(
            x: 0,
            y: textContainerOrigin.y + CGFloat(line) * row + imagePreviews.heightBefore(line: line) + extra * progress,
            width: 1,
            height: row
        )
        // The typographic bounds are a partial rect: their height drops the line
        // spacing, and the em box hangs from the bottom of the screen line, so the
        // caret is already halfway off while that rect still counts as visible.
        // `scrollRect` is the whole screen line in text-view coordinates (it
        // includes `textContainerOrigin`). The last row also owns the paragraph
        // gap under it, which is where an image preview sits.
        // Scrolling restyles the lines that come on screen, and that moves the
        // caret a few points, so measure again. A later pass that cannot see the
        // caret keeps the scroll already made: `G` on a long note lays the end
        // out once, and the estimate sits short of that real line.
        for pass in 0..<3 {
            let caret = caretRect(forcingLayout: false)
            let rect: NSRect
            if let caret, let measured = scrollRect(around: caret), measured.midY + row * 4 >= estimated.midY {
                rect = measured
            } else if pass > 0 {
                return
            } else {
                rect = estimated
            }
            if pass == 0 {
                noteContentSizeChanged()
            }
            let visible = clip.bounds
            var origin = visible.origin
            origin.y = verticalOrigin(keeping: rect, caret: caret, in: visible, margin: row)
            let maxY = max(0, bounds.height - visible.height)
            origin.y = min(max(0, origin.y), maxY)
            // The view is as wide as the clip, so this pins x to 0. It also undoes a
            // sideways scroll that AppKit makes on its own, e.g. for a selection.
            let across = caret ?? rect
            if across.maxX > visible.maxX {
                origin.x += across.maxX - visible.maxX
            } else if across.minX < visible.minX {
                origin.x -= visible.minX - across.minX
            }
            origin.x = min(max(0, origin.x), max(0, bounds.width - visible.width))
            let nudgeY = abs(origin.y - visible.origin.y)
            if pass > 0, nudgeY > row * 4 { return }
            guard nudgeY > 0.5 || abs(origin.x - visible.origin.x) > 0.5 else { return }
            clip.setBoundsOrigin(origin)
            scroll.reflectScrolledClipView(clip)
        }
    }

    /// Rewrapping moves the caret's row. The resize anchor measures it before
    /// TextKit lays the new width out, so on a large rewrap it can leave the caret
    /// off screen. A fragment's y depends on every fragment above it, and after a
    /// width change only the viewport is laid out again, so lay out through the
    /// caret before measuring. Scrolling paints the lines that come on screen,
    /// and dropping a table's padding there rewraps it, so measure again after.
    /// This runs once per resize, not per live-resize frame.
    private func revealCaretIfHidden() {
        guard let clip = enclosingScrollView?.contentView, engine != nil, let lm = textLayoutManager else { return }
        let doc = lm.documentRange.location
        for _ in 0..<3 {
            let index = caretUTF16()
            lm.enumerateTextLayoutFragments(from: doc, options: [.ensuresLayout]) { fragment in
                let end = lm.offset(from: doc, to: fragment.rangeInElement.endLocation)
                return end != NSNotFound && end <= index
            }
            guard let caret = caretRect(forcingLayout: true),
                  !clip.bounds.insetBy(dx: -0.5, dy: -0.5).contains(caret) else { return }
            revealCaret()
        }
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
        // Buffer lines, not a forced full TextKit layout: forcing layout to
        // measure is what made scrolling a long file hitch. Wrapped lines and
        // tall headings are taller than one row each, so whatever TextKit has
        // already laid out (`usageBounds` reads, it does not lay out) can only
        // raise the estimate. Without it the frame ends above a wrapped caret.
        guard let engine else { return max(clip, bounds.height) }
        let rows = max(1, engine.buffer.lineCount)
        var content = CGFloat(rows) * rowHeight() + inset + imagePreviews.reservedHeight
        if let used = textLayoutManager?.usageBoundsForTextContainer, used.height > 0 {
            content = max(content, used.maxY + inset)
        }
        let ghosts = isDirectoryBuffer ? directoryGhostHeight : 0
        return max(clip, ceil(content)) + ghosts
    }

    func bodyRowHeight() -> CGFloat {
        rowHeight()
    }

    func imageGapRows(on line: Int) -> Int {
        imagePreviews.gapRows(on: line, rowHeight: rowHeight())
    }

    func setImageContext(enabled: Bool, filePath: String?) {
        imagePreviews.setContext(enabled: enabled, filePath: filePath)
    }

    func flushImagePreviews() {
        imagePreviews.flush()
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
                if unit != LineIndex.newline {
                    return (storage.attribute(.font, at: previous, effectiveRange: nil) as? NSFont) ?? fallback
                }
            }
            return fallback
        }
        var probe = min(max(0, index), length - 1)
        let unit = ns.character(at: probe)
        if unit == LineIndex.newline, probe > 0 {
            let previous = probe - 1
            if ns.character(at: previous) != LineIndex.newline {
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
            if chunk != "\n", chunk != "\t" {
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
        let fragmentEnd = lm.offset(from: doc, to: fragment.rangeInElement.endLocation)
        if !fragmentCovers(clamped, start: fragmentStart, end: fragmentEnd, documentLength: length) {
            return nil
        }
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
        let lineBounds = line.typographicBounds
        let lineMinX = container.x + fragmentFrame.minX + lineBounds.minX
        if let segment = segmentMetrics(atUTF16: clamped, layout: lm) {
            return LineMetrics(
                originX: container.x + segment.x,
                baselineY: container.y + segment.baseline,
                lineMinX: lineMinX,
                lineWidth: max(0, lineBounds.width)
            )
        }
        // No segment: an empty paragraph. It has one row, which starts at
        // index 0 under either reading of `locationForCharacter(at:)`.
        let point = line.locationForCharacter(at: line.characterRange.location)
        return LineMetrics(
            originX: lineMinX,
            baselineY: container.y + fragmentFrame.minY + lineBounds.minY + point.y,
            lineMinX: lineMinX,
            lineWidth: max(0, lineBounds.width)
        )
    }

    /// Leading edge and baseline of the grapheme at `index`, in text-container
    /// coordinates, from TextKit's text segments. Segments take document
    /// locations, so no line-fragment-relative index is involved. At the end of
    /// a line's content (insert mode) the caret stands after the previous grapheme.
    private func segmentMetrics(atUTF16 index: Int, layout lm: NSTextLayoutManager) -> (x: CGFloat, baseline: CGFloat)? {
        let ns = string as NSString
        let length = ns.length
        guard length > 0 else { return nil }
        func isNewline(_ at: Int) -> Bool {
            ns.character(at: at) == LineIndex.newline
        }
        if index < length, !isNewline(index) {
            return segment(ns.rangeOfComposedCharacterSequence(at: index), layout: lm).map { ($0.frame.minX, $0.baseline) }
        }
        if index > 0, index <= length, !isNewline(index - 1) {
            let previous = ns.rangeOfComposedCharacterSequence(at: index - 1)
            return segment(previous, layout: lm).map { ($0.frame.maxX, $0.baseline) }
        }
        return nil
    }

    private func segment(_ span: NSRange, layout lm: NSTextLayoutManager) -> (frame: CGRect, baseline: CGFloat)? {
        let doc = lm.documentRange.location
        guard let start = lm.location(doc, offsetBy: span.location),
              let end = lm.location(start, offsetBy: span.length),
              let range = NSTextRange(location: start, end: end) else { return nil }
        var found: (frame: CGRect, baseline: CGFloat)?
        lm.enumerateTextSegments(in: range, type: .standard, options: [.rangeNotRequired]) { _, frame, position, _ in
            if let baseline = CaretGeometry.resolvedBaseline(
                segmentMinY: Double(frame.minY),
                segmentHeight: Double(max(frame.height, 0.1)),
                baselinePosition: Double(position)
            ) {
                found = (frame, CGFloat(baseline))
            }
            return false
        }
        return found
    }

    /// `textLayoutFragment(for:)` can hand back an earlier fragment. That fragment
    /// does not contain `index`.
    private func fragmentCovers(_ index: Int, start: Int, end: Int, documentLength: Int) -> Bool {
        if start == NSNotFound || end == NSNotFound || start > end { return false }
        if index >= start && index < end { return true }
        return index >= documentLength && end >= documentLength && start <= documentLength
    }

    private func caretLineRect() -> NSRect? {
        guard let lm = textLayoutManager, engine != nil else { return nil }
        let index = caretUTF16()
        let doc = lm.documentRange.location
        guard let location = lm.location(doc, offsetBy: index),
              let fragment = lm.textLayoutFragment(for: location) else { return nil }
        let fragmentStart = lm.offset(from: doc, to: fragment.rangeInElement.location)
        let fragmentEnd = lm.offset(from: doc, to: fragment.rangeInElement.endLocation)
        let length = (string as NSString).length
        guard fragmentCovers(index, start: fragmentStart, end: fragmentEnd, documentLength: length) else {
            return nil
        }
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

    /// Screen line that must stay on screen, in text-view coordinates.
    /// The caret baseline already includes `textContainerOrigin`, so a non-zero
    /// inset is part of the rect. Paragraph spacing on the last screen row is the
    /// image preview under that line; a wrapped row above the last one does not
    /// include it.
    private func scrollRect(around caret: NSRect) -> NSRect? {
        let index = caretUTF16()
        let caretFont = font(atUTF16: index)
        let style = paragraphStyle(atUTF16: index)
        let lineHeight = CGFloat(CaretGeometry.lineFragmentHeight(
            ascender: Double(caretFont.ascender),
            descender: Double(caretFont.descender),
            leading: Double(caretFont.leading),
            lineHeightMultiple: Double(style.lineHeightMultiple),
            lineSpacing: Double(style.lineSpacing),
            minimumLineHeight: Double(style.minimumLineHeight),
            maximumLineHeight: Double(style.maximumLineHeight)
        ))
        let height = max(lineHeight, caret.height)
        var top = min(caret.minY, caret.maxY - height)
        var bottom = max(caret.maxY, top + height)
        let ends = screenRowEnds(atUTF16: index)
        if ends.first {
            top -= max(0, style.paragraphSpacingBefore)
        }
        if ends.last {
            bottom += max(0, style.paragraphSpacing)
        }
        if let laid = caretLineRect(),
           laid.maxY > caret.minY - 1,
           laid.minY < caret.maxY + 1,
           laid.minY >= top - height,
           laid.maxY <= bottom + height {
            top = min(top, laid.minY)
            bottom = max(bottom, laid.maxY)
        }
        guard bottom > top + 0.5 else { return nil }
        return NSRect(x: 0, y: top, width: 1, height: bottom - top)
    }

    /// `true` for the first and last text rows of the caret's layout fragment.
    /// An image preview's gap belongs to the last row only.
    private func screenRowEnds(atUTF16 index: Int) -> (first: Bool, last: Bool) {
        guard let lm = textLayoutManager else { return (true, true) }
        let length = (string as NSString).length
        if length == 0 { return (true, true) }
        let clamped = min(max(0, index), length)
        let doc = lm.documentRange.location
        let probe = clamped < length ? clamped : max(0, length - 1)
        guard let location = lm.location(doc, offsetBy: probe),
              let fragment = lm.textLayoutFragment(for: location) else { return (true, true) }
        let start = lm.offset(from: doc, to: fragment.rangeInElement.location)
        let end = lm.offset(from: doc, to: fragment.rangeInElement.endLocation)
        guard fragmentCovers(clamped, start: start, end: end, documentLength: length) else {
            return (true, true)
        }
        let content = fragment.textLineFragments.filter { $0.characterRange.length > 0 }
        guard !content.isEmpty else { return (true, true) }
        if clamped >= length { return (false, true) }
        let local = clamped - start
        guard let hit = content.firstIndex(where: { line in
            let span = line.characterRange
            return local >= span.location && local < span.location + span.length
        }) else { return (true, true) }
        return (hit == 0, hit == content.count - 1)
    }

    /// Scroll so `rect` stays fully inside `visible` with up to one line of margin.
    /// A preview taller than the window keeps the caret cell instead, so the
    /// picture cannot push the cursor off the top.
    private func verticalOrigin(keeping rect: NSRect, caret: NSRect?, in visible: NSRect, margin: CGFloat) -> CGFloat {
        let target: NSRect
        let pad: CGFloat
        if rect.height + 0.5 < visible.height {
            target = rect
            pad = min(margin, max(0, (visible.height - rect.height) / 2))
        } else if let caret, caret.height + 0.5 < visible.height {
            target = caret
            pad = min(margin, max(0, (visible.height - caret.height) / 2))
        } else {
            target = caret ?? rect
            pad = 0
        }
        var y = visible.origin.y
        if target.maxY > visible.maxY - pad + 0.5 {
            y += target.maxY - (visible.maxY - pad)
        } else if target.minY < visible.minY + pad - 0.5 {
            y -= (visible.minY + pad) - target.minY
        }
        return y
    }

    @objc private func clipViewBoundsChanged(_ notification: Notification) {
        guard let clip = notification.object as? NSClipView else { return }
        if abs(clip.bounds.width - appliedClipWidth) > 0.5 {
            updateInsets()
            if abs(clip.bounds.width - bounds.width) > 1 {
                noteContentSizeChanged()
            }
        }
        // Vertical scrolling used to return above. A table below the fold stays
        // unstyled until this pass paints the lines that just came on screen.
        restyleVisibleIfNeeded()
        imagePreviews.scheduleRefresh()
    }

    private func visibleWidth(proposed: CGFloat) -> CGFloat {
        if let clip = enclosingScrollView?.contentView, clip.bounds.width > 1 {
            return clip.bounds.width
        }
        if let content = enclosingScrollView?.contentSize.width, content > 1 {
            return content
        }
        return max(proposed, 1)
    }

    private func caretDocumentMidY() -> CGFloat? {
        guard engine != nil else { return nil }
        return caretLineRect()?.midY
    }

    private func pinVerticalOrigin(_ y: CGFloat) {
        guard let scroll = enclosingScrollView else { return }
        let clip = scroll.contentView
        guard clip.bounds.height > 1, bounds.height > 1 else { return }
        let maxY = max(0, bounds.height - clip.bounds.height)
        let clamped = min(max(0, y), maxY)
        guard abs(clamped - clip.bounds.origin.y) > 0.5 else { return }
        var origin = clip.bounds.origin
        origin.y = clamped
        clip.setBoundsOrigin(origin)
        scroll.reflectScrolledClipView(clip)
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

/// Theme, focus, and a directory swap restyle the window. A status-line change does not.
@MainActor
@discardableResult
func syncWindowChrome(
    view: VimTextView,
    theme: QuillTheme,
    themeIdentity: Int,
    focus: Bool,
    directoryChanged: Bool
) -> Bool {
    guard view.appliedThemeID != themeIdentity || view.appliedFocus != focus || directoryChanged else {
        return false
    }
    WindowChrome.apply(theme: theme)
    view.applyTheme(theme, focus: focus)
    view.appliedThemeID = themeIdentity
    view.appliedFocus = focus
    return true
}

struct EditorView: NSViewRepresentable {
    var model: AppModel
    var diagnostics: [(NSRange, Int)]
    var refresh: Int

    func makeNSView(context: Context) -> NSScrollView {
        let began = StartupProbe.begin("makeNSViewMs")
        defer { StartupProbe.end("makeNSViewMs", began) }
        let hosted = VimTextView.host(engine: model.engine)
        let scroll = hosted.scroll
        let tv = hosted.view
        if model.editor == nil { model.editor = tv }
        tv.vimDelegate = context.coordinator
        context.coordinator.textView = tv
        context.coordinator.model = model
        tv.columnWidth = model.theme.columnWidth
        tv.setImageContext(enabled: model.showImages, filePath: model.document.isDirectory ? nil : model.document.url?.path)
        tv.isDirectoryBuffer = model.document.isDirectory
        tv.directoryURL = model.document.isDirectory ? model.document.url : nil
        tv.directoryEntries = model.document.isDirectory ? (model.document.snapshot?.entries ?? []) : []
        let themeBegan = StartupProbe.begin("applyThemeMs")
        tv.applyTheme(model.theme, focus: model.focusMode)
        StartupProbe.end("applyThemeMs", themeBegan)
        tv.seenRefresh = refresh
        tv.reload()
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let tv = scroll.documentView as? VimTextView else { return }
        tv.engine = model.engine
        if model.editor == nil || tv.window?.isKeyWindow == true {
            model.editor = tv
        }
        tv.columnWidth = model.theme.columnWidth
        tv.setImageContext(enabled: model.showImages, filePath: model.document.isDirectory ? nil : model.document.url?.path)
        let entries = model.document.isDirectory ? (model.document.snapshot?.entries ?? []) : []
        let url = model.document.isDirectory ? model.document.url : nil
        let directoryChanged = tv.isDirectoryBuffer != model.document.isDirectory
            || tv.directoryURL != url
            || tv.directoryEntries != entries
        tv.isDirectoryBuffer = model.document.isDirectory
        tv.directoryURL = url
        tv.directoryEntries = entries
        if directoryChanged { tv.invalidateDirectoryStyle() }
        let diagnosticsChanged = tv.diagnosticRanges.count != diagnostics.count
            || tv.diagnosticRanges.map(\.0) != diagnostics.map(\.0)
        if diagnosticsChanged {
            tv.diagnosticRanges = diagnostics
            tv.queueRestyle()
        }
        if model.document.isDirectory {
            scroll.drawsBackground = true
            scroll.backgroundColor = model.theme.directoryBackgroundColor
            tv.window?.backgroundColor = model.theme.directoryBackgroundColor
        } else {
            scroll.drawsBackground = false
        }
        if !syncWindowChrome(
            view: tv,
            theme: model.theme,
            themeIdentity: model.themeIdentity,
            focus: model.focusMode,
            directoryChanged: directoryChanged
        ) {
            tv.updateInsets()
        }
        let sheetUp: Bool
        switch model.prompt {
        case .confirmFilesystem, .unsaved: sheetUp = true
        case .none, .picker: sheetUp = false
        }
        let pickerUp = model.picker != nil
        if !pickerUp, !sheetUp, tv.window?.firstResponder !== tv {
            tv.window?.makeFirstResponder(tv)
        }
        if context.coordinator.hadPicker && !pickerUp {
            tv.window?.makeFirstResponder(tv)
        }
        context.coordinator.hadPicker = pickerUp
        tv.syncFromEngine(isEditor: model.editor === tv, refresh: refresh)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor
    final class Coordinator: NSObject, VimTextViewDelegate {
        var textView: VimTextView?
        weak var model: AppModel?
        var hadPicker = false

        func vimTextView(_ view: VimTextView, didHandle result: EngineResult) {
            model?.afterEdit(result)
        }

        func vimTextViewDidClick(_ view: VimTextView, characterOffset: Int, commandClick: Bool) {
            if commandClick {
                model?.goToDefinition()
            }
        }

        func vimTextView(_ view: VimTextView, handleCompletionKey key: KeyEvent) -> Bool {
            model?.handleCompletionKey(key) ?? false
        }
    }
}
