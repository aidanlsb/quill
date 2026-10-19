import AppKit
import ObjectiveC
import QuillVim
@testable import Quill
/// One editor, wired by `VimTextView.host(engine:frame:)`, driven through `keyDown`.
@MainActor
final class EditorHarness {
    let engine: Engine
    let view: VimTextView
    let scroll: NSScrollView
    let window: NSWindow
    init(
        text: String,
        size: NSSize = NSSize(width: 800, height: 600),
        theme: QuillTheme = .current(),
        column: CGFloat? = nil
    ) {
        let engine = Engine(text: text)
        self.engine = engine
        (scroll, view, window) = Self.makeWindow(engine: engine, size: size)
        if let column { view.columnWidth = column }
        view.applyTheme(theme, focus: false)
        view.reload()
        finish()
    }
    /// Hosts the model's engine the way `EditorView.makeNSView` does.
    init(model: AppModel, size: NSSize = NSSize(width: 800, height: 600)) {
        engine = model.engine
        (scroll, view, window) = Self.makeWindow(engine: model.engine, size: size)
        view.columnWidth = model.theme.columnWidth
        view.isDirectoryBuffer = model.isDirectory
        view.directoryURL = model.isDirectory ? model.fileURL : nil
        view.directoryEntries = model.isDirectory ? (model.directorySnapshot?.entries ?? []) : []
        view.applyTheme(model.theme, focus: model.focusMode)
        view.reload()
        finish()
    }
    @discardableResult
    func type(_ keys: String) -> EngineResult {
        view.press(keys)
    }
    func resize(to size: NSSize) {
        window.setContentSize(size)
        scroll.setFrameSize(size)
        scroll.tile()
        scroll.layoutSubtreeIfNeeded()
        view.layoutSubtreeIfNeeded()
    }
    func caretRect() -> NSRect { view.renderedCaretRect() }

    func clipOrigin() -> CGFloat { scroll.contentView.bounds.origin.y }

    func settle() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }

    func close() {
        window.orderOut(nil)
        window.close()
    }

    private func finish() {
        window.makeFirstResponder(view)
        view.layoutSubtreeIfNeeded()
    }

    private static func makeWindow(
        engine: Engine,
        size: NSSize
    ) -> (NSScrollView, VimTextView, NSWindow) {
        let frame = NSRect(origin: .zero, size: size)
        let hosted = VimTextView.host(engine: engine, frame: frame)
        let window = NSWindow(
            contentRect: frame,
            styleMask: [.titled, .resizable, .closable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
        window.contentView = hosted.scroll
        hosted.scroll.frame = window.contentView?.bounds ?? frame
        window.makeKeyAndOrderFront(nil)
        return (hosted.scroll, hosted.view, window)
    }
}

@MainActor
private final class KeySink: NSObject, VimTextViewDelegate {
    var last = EngineResult.noop
    var forward: ((EngineResult) -> Void)?

    func vimTextView(_ view: VimTextView, didHandle result: EngineResult) {
        last = result
        forward?(result)
    }

    func vimTextViewDidClick(_ view: VimTextView, characterOffset: Int, commandClick: Bool) {}

    func vimTextView(_ view: VimTextView, handleCompletionKey key: KeyEvent) -> Bool { false }

    private static var key: UInt8 = 0

    static func install(on view: VimTextView) -> KeySink {
        if let existing = objc_getAssociatedObject(view, &key) as? KeySink {
            return existing
        }
        let created = KeySink()
        objc_setAssociatedObject(view, &key, created, .OBJC_ASSOCIATION_RETAIN)
        return created
    }
}

extension VimTextView {
    /// Vim notation (`ihello<Esc>`, `<C-d>`, `<CR>`) sent through `keyDown`.
    @discardableResult
    @MainActor
    func press(_ notation: String, forward: ((EngineResult) -> Void)? = nil) -> EngineResult {
        let sink = KeySink.install(on: self)
        sink.forward = forward
        vimDelegate = sink
        var last = EngineResult.noop
        for event in KeyEvent.parse(notation) {
            guard let nsEvent = EditorHarness.nsEvent(event, windowNumber: window?.windowNumber ?? 0) else {
                continue
            }
            keyDown(with: nsEvent)
            last = sink.last
        }
        return last
    }
}

extension EditorHarness {
    static func nsEvent(_ event: KeyEvent, windowNumber: Int) -> NSEvent? {
        let flags: NSEvent.ModifierFlags
        let chars: String
        let keyCode: UInt16
        switch event.key {
        case .character(let ch):
            flags = []
            chars = String(ch)
            keyCode = 0
        case .text(let text):
            flags = []
            chars = text
            keyCode = 0
        case .escape:
            flags = []
            chars = "\u{1b}"
            keyCode = 53
        case .enter:
            flags = []
            chars = "\r"
            keyCode = 36
        case .backspace:
            flags = []
            chars = "\u{7f}"
            keyCode = 51
        case .delete:
            flags = []
            chars = "\u{F728}"
            keyCode = 117
        case .tab:
            flags = []
            chars = "\t"
            keyCode = 48
        case .ctrl(let ch):
            flags = .control
            chars = String(ch)
            keyCode = 0
        case .up:
            flags = []
            chars = "\u{F700}"
            keyCode = 126
        case .down:
            flags = []
            chars = "\u{F701}"
            keyCode = 125
        case .left:
            flags = []
            chars = "\u{F702}"
            keyCode = 123
        case .right:
            flags = []
            chars = "\u{F703}"
            keyCode = 124
        }
        return NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: flags,
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: windowNumber,
            context: nil,
            characters: chars,
            charactersIgnoringModifiers: chars,
            isARepeat: false,
            keyCode: keyCode
        )
    }
}
