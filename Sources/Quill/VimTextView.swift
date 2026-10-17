import AppKit
import SwiftUI
import QuillVim

final class TextKit2Layout: TextLayout {
    weak var textView: NSTextView?

    func displayColumn(of offset: Int, in buffer: TextBuffer) -> Int {
        LogicalLineLayout.shared.displayColumn(of: offset, in: buffer)
    }

    func position(
        from offset: Int,
        displayLines delta: Int,
        preferredColumn: Int,
        in buffer: TextBuffer
    ) -> Int {
        guard let tv = textView, let lm = tv.textLayoutManager, delta != 0 else {
            return LogicalLineLayout.shared.position(
                from: offset,
                displayLines: delta,
                preferredColumn: preferredColumn,
                in: buffer
            )
        }
        let utf16 = utf16Offset(offset, in: buffer.text)
        guard let location = lm.location(lm.documentRange.location, offsetBy: utf16) else {
            return LogicalLineLayout.shared.position(
                from: offset, displayLines: delta, preferredColumn: preferredColumn, in: buffer
            )
        }
        var fragment = lm.textLayoutFragment(for: location)
        var remaining = delta
        let step = remaining > 0 ? 1 : -1
        while remaining != 0, let current = fragment {
            let next: NSTextLayoutFragment?
            if step > 0 {
                if let end = current.rangeInElement.endLocation as? NSTextLocation,
                   let after = lm.location(end, offsetBy: 1) {
                    next = lm.textLayoutFragment(for: after)
                } else {
                    next = nil
                }
            } else {
                let start = current.rangeInElement.location
                if let before = lm.location(start, offsetBy: -1) {
                    next = lm.textLayoutFragment(for: before)
                } else {
                    next = nil
                }
            }
            guard let next, next !== current else { break }
            fragment = next
            remaining -= step
        }
        guard let fragment else {
            return offset
        }
        let startUTF16 = lm.offset(from: lm.documentRange.location, to: fragment.rangeInElement.location)
        let dest = characterOffset(utf16: max(0, startUTF16 + min(preferredColumn, 80)), in: buffer.text)
        return buffer.clampedCursor(dest, normalMode: true)
    }

    private func utf16Offset(_ characterOffset: Int, in text: String) -> Int {
        let i = text.index(text.startIndex, offsetBy: min(characterOffset, text.count))
        return i.utf16Offset(in: text)
    }

    private func characterOffset(utf16: Int, in text: String) -> Int {
        let i = String.Index(utf16Offset: min(utf16, text.utf16.count), in: text)
        return text.distance(from: text.startIndex, to: i)
    }
}

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
        }
        let utf16 = utf16Offset(engine.cursor)
        setSelectedRange(NSRange(location: utf16, length: 0))
        if let sel = engine.visualSelection, engine.mode.isVisual {
            let loc = utf16Offset(sel.lowerBound)
            let end = utf16Offset(sel.upperBound)
            setSelectedRange(NSRange(location: loc, length: max(0, end - loc)))
        }
        queueRestyle()
        scrollToVisible(rectForCharacterRange())
    }

    func applyResult(_ result: EngineResult) {
        if result.didChangeText {
            if let edit = engine.lastEdit {
                let nsRange = nsRange(edit.range)
                if nsRange.location != NSNotFound, let storage = textStorage {
                    storage.replaceCharacters(in: nsRange, with: edit.replacement)
                } else {
                    string = engine.text
                }
            } else {
                string = engine.text
            }
        }
        syncFromEngine()
        vimDelegate?.vimTextView(self, didHandle: result)
    }

    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command) {
            super.keyDown(with: event)
            return
        }
        if hasMarkedText() {
            super.keyDown(with: event)
            return
        }
        guard let key = KeyEvent(nsEvent: event) else {
            super.keyDown(with: event)
            return
        }
        let result = engine.handle(key)
        applyResult(result)
        if result.beep {
            NSSound.beep()
        }
    }

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        let utf16 = selectedRange().location
        let offset = characterOffset(utf16: utf16)
        engine.moveCursor(to: offset)
        vimDelegate?.vimTextViewDidClick(self, characterOffset: offset, commandClick: event.modifierFlags.contains(.command))
    }

    override func drawInsertionPoint(in rect: NSRect, color: NSColor, turnedOn flag: Bool) {
        guard flag else {
            super.drawInsertionPoint(in: rect, color: color, turnedOn: flag)
            return
        }
        if engine.mode == .insert {
            super.drawInsertionPoint(in: rect, color: color, turnedOn: flag)
            return
        }
        var block = rect
        block.size.width = max(rect.width, theme.bodyFont.maximumAdvancement.width * 0.55)
        color.withAlphaComponent(engine.mode.isVisual ? 0.15 : 0.35).setFill()
        block.fill()
    }

    override func insertText(_ insertString: Any, replacementRange: NSRange) {
        // All typing goes through keyDown → engine.
    }

    func queueRestyle() {
        guard !restyleQueued else { return }
        restyleQueued = true
        DispatchQueue.main.async { [weak self] in
            guard let self, let storage = self.textStorage else { return }
            self.restyleQueued = false
            MarkdownStyler.restyle(storage, theme: self.theme, diagnostics: self.diagnosticRanges)
        }
    }

    func utf16Offset(_ characterOffset: Int) -> Int {
        let text = string
        let i = text.index(text.startIndex, offsetBy: min(max(0, characterOffset), text.count))
        return i.utf16Offset(in: text)
    }

    func characterOffset(utf16: Int) -> Int {
        let text = string
        let i = String.Index(utf16Offset: min(max(0, utf16), text.utf16.count), in: text)
        return text.distance(from: text.startIndex, to: i)
    }

    func nsRange(_ range: Range<Int>) -> NSRange {
        let loc = utf16Offset(range.lowerBound)
        let end = utf16Offset(range.upperBound)
        return NSRange(location: loc, length: end - loc)
    }

    private func rectForCharacterRange() -> NSRect {
        let r = firstRect(forCharacterRange: selectedRange(), actualRange: nil)
        return window?.convertFromScreen(r) ?? visibleRect
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
    @ObservedObject var model: AppModel

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
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let tv = scroll.documentView as? VimTextView else { return }
        tv.engine = model.engine
        tv.columnWidth = model.theme.columnWidth
        tv.isDirectoryBuffer = model.isDirectory
        tv.diagnosticRanges = model.nsDiagnosticRanges()
        tv.applyTheme(model.theme, focus: model.focusMode)
        if tv.string != model.engine.text {
            tv.syncFromEngine()
        } else {
            tv.updateInsets()
            tv.queueRestyle()
        }
        if context.coordinator.hadPicker && model.picker == nil {
            tv.window?.makeFirstResponder(tv)
        }
        context.coordinator.hadPicker = model.picker != nil
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, VimTextViewDelegate {
        var textView: VimTextView?
        weak var model: AppModel?
        var hadPicker = false

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
