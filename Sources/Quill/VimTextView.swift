import AppKit
import SwiftUI
import QuillMarkdown
import QuillVim

/// TextKit 2 display-line layout. `@unchecked Sendable` because the vim engine
/// only invokes this from the app's main-actor event loop (keyDown / sync).
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
        // TextBuffer is not Sendable; the engine calls this synchronously on the main thread.
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
        lm.ensureLayout(for: lm.documentRange)
        guard let location = lm.location(lm.documentRange.location, offsetBy: utf16) else {
            return LogicalLineLayout.shared.position(
                from: offset, displayLines: delta, preferredColumn: preferredColumn, in: buffer
            )
        }
        guard let fragment = lm.textLayoutFragment(for: location) else {
            return LogicalLineLayout.shared.position(
                from: offset, displayLines: delta, preferredColumn: preferredColumn, in: buffer
            )
        }
        let lines = visualLines(around: fragment, layout: lm, extra: abs(delta) + 1)
        guard !lines.isEmpty else { return offset }
        let local = utf16 - lines[0].documentLocation
        var index = lines.firstIndex { line in
            let start = line.fragmentRange.location
            return local >= start && local < start + max(line.fragmentRange.length, 1)
        } ?? 0
        if preferredColumn != stickyColumn {
            stickyColumn = preferredColumn
            stickyX = lines[index].line.locationForCharacter(at: min(local - lines[index].fragmentRange.location, lines[index].fragmentRange.length)).x
        }
        index = min(max(0, index + delta), lines.count - 1)
        let line = lines[index]
        let hit = line.line.characterIndex(for: CGPoint(x: stickyX, y: line.line.typographicBounds.midY))
        let dest = line.documentLocation + line.fragmentRange.location + hit
        return buffer.clampedCursor(dest, normalMode: true)
    }

    private struct VisualLine {
        var line: NSTextLineFragment
        var fragmentRange: NSRange
        var documentLocation: Int
    }

    private func visualLines(around fragment: NSTextLayoutFragment, layout lm: NSTextLayoutManager, extra: Int) -> [VisualLine] {
        var fragments: [NSTextLayoutFragment] = [fragment]
        var backward: NSTextLayoutFragment? = fragment
        for _ in 0..<extra {
            guard let current = backward else { break }
            let start = current.rangeInElement.location
            guard let before = lm.location(start, offsetBy: -1),
                  let previous = lm.textLayoutFragment(for: before),
                  previous !== current else { break }
            fragments.insert(previous, at: 0)
            backward = previous
        }
        var forward: NSTextLayoutFragment? = fragment
        for _ in 0..<extra {
            guard let current = forward else { break }
            let end = current.rangeInElement.endLocation
            guard let after = lm.location(end, offsetBy: 0),
                  let next = lm.textLayoutFragment(for: after),
                  next !== current else { break }
            fragments.append(next)
            forward = next
        }
        return fragments.flatMap { piece in
            let origin = lm.offset(from: lm.documentRange.location, to: piece.rangeInElement.location)
            return piece.textLineFragments.map { line in
                VisualLine(line: line, fragmentRange: line.characterRange, documentLocation: origin)
            }
        }
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
        allowsUndo = false
        isIncrementalSearchingEnabled = false
        textContainer?.widthTracksTextView = true
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
        insertionPointColor = theme.textColor
        selectedTextAttributes = [
            .backgroundColor: theme.linkColor.withAlphaComponent(0.28),
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
    }

    func updateInsets() {
        guard let clip = enclosingScrollView?.contentView else { return }
        let width = clip.bounds.width
        let extra = focusMode ? 72 : 40
        let inset = max(24, (width - columnWidth) / 2)
        textContainerInset = NSSize(width: inset, height: CGFloat(extra))
        textContainer?.size = NSSize(width: columnWidth, height: CGFloat.greatestFiniteMagnitude)
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

    override func drawInsertionPoint(in rect: NSRect, color: NSColor, turnedOn flag: Bool) {
        guard engine != nil, flag else {
            super.drawInsertionPoint(in: rect, color: color, turnedOn: flag)
            return
        }
        let cell = caretCell(suggested: rect)
        if engine.mode == .insert {
            color.setFill()
        } else {
            color.withAlphaComponent(engine.mode.isVisual ? 0.15 : 0.35).setFill()
        }
        cell.fill()
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

    /// One character cell: the advance of the glyph under the cursor, and the em box
    /// of the font actually applied to that glyph. The line-fragment rect AppKit
    /// passes in is only a fallback origin; its width and height are not the cell.
    func caretCell(suggested rect: NSRect) -> NSRect {
        let index = clampUTF16(selectedRange().location)
        let caretFont = font(atUTF16: index)
        let shape: CaretShape = engine.mode == .insert ? .beam : .block
        let advance = glyphAdvance(atUTF16: index, font: caretFont)
        let metrics = caretBaseline(atUTF16: index, suggested: rect, font: caretFont)
        let box = CaretGeometry.box(
            shape: shape,
            glyphAdvance: Double(advance),
            ascender: Double(caretFont.ascender),
            descender: Double(caretFont.descender),
            originX: Double(metrics.originX),
            baselineY: Double(metrics.baselineY)
        )
        return NSRect(x: box.x, y: box.y, width: box.width, height: box.height)
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
        let rect = caretLineRect() ?? caretCell(suggested: NSRect(x: 0, y: 0, width: 1, height: rowHeight()))
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
        if let lm = textLayoutManager {
            lm.ensureLayout(for: lm.documentRange)
            used = lm.usageBoundsForTextContainer.height + inset
        }
        return max(clip, ceil(used), ceil(estimated))
    }

    private func font(atUTF16 index: Int) -> NSFont {
        let fallback = self.font ?? theme.bodyFont
        guard let storage = textStorage, storage.length > 0 else { return fallback }
        let ns = string as NSString
        var probe = min(max(0, index), storage.length - 1)
        let unit = ns.character(at: probe)
        if (unit == 10 || unit == 13), probe > 0 {
            probe -= 1
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

    private func caretBaseline(atUTF16 index: Int, suggested rect: NSRect, font: NSFont) -> (originX: CGFloat, baselineY: CGFloat) {
        if let placed = glyphPlacement(atUTF16: index) {
            return placed
        }
        let originX = rect.origin.x
        let baselineY = rect.maxY + font.descender
        return (originX, baselineY)
    }

    /// Baseline and leading edge of the glyph, in text-view coordinates.
    private func glyphPlacement(atUTF16 index: Int) -> (originX: CGFloat, baselineY: CGFloat)? {
        guard let lm = textLayoutManager else { return nil }
        lm.ensureLayout(for: lm.documentRange)
        let doc = lm.documentRange.location
        guard let location = lm.location(doc, offsetBy: index),
              let fragment = lm.textLayoutFragment(for: location) else { return nil }
        let fragmentStart = lm.offset(from: doc, to: fragment.rangeInElement.location)
        let local = index - fragmentStart
        guard let line = fragment.textLineFragments.first(where: { line in
            let span = line.characterRange
            return local >= span.location && local < span.location + max(span.length, 1)
        }) ?? fragment.textLineFragments.last else { return nil }
        let charIndex = max(0, local - line.characterRange.location)
        let point = line.locationForCharacter(at: min(charIndex, max(0, line.characterRange.length)))
        let container = textContainerOrigin
        let fragmentFrame = fragment.layoutFragmentFrame
        let lineBounds = line.typographicBounds
        let originX = container.x + fragmentFrame.minX + lineBounds.minX + point.x
        let baselineY = container.y + fragmentFrame.minY + lineBounds.minY + point.y
        return (originX, baselineY)
    }

    private func caretLineRect() -> NSRect? {
        guard let lm = textLayoutManager else { return nil }
        lm.ensureLayout(for: lm.documentRange)
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
