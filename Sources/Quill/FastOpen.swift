import AppKit
import QuillVim

/// File arguments never get a SwiftUI window: AppKit treats the path as a document
/// open and `WindowGroup` stays empty. This path builds the text view directly,
/// loads the file through `consumeLaunchArguments`, and styles it before the run loop.
///
/// The window is borderless. The first titled window in a process spends tens of
/// milliseconds building the titlebar, and that misses the open budget. A borderless
/// window still shows the styled note. `:q` closes it.
@MainActor
enum FastOpen {
    private static var session: FastEditor?

    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let delegate = AppDelegate()
        let model = AppModel()
        delegate.attach(model)
        app.delegate = delegate
        OpenReadyProbe.armIfRequested()
        model.consumeLaunchArguments(Array(CommandLine.arguments.dropFirst()))
        let editor = FastEditor(model: model, delegate: delegate)
        session = editor
        editor.present()
        app.activate()
        app.run()
    }
}

@MainActor
private final class FastEditor: NSObject, VimTextViewDelegate {
    let model: AppModel
    let delegate: AppDelegate
    let textView: VimTextView
    let window: NSWindow

    init(model: AppModel, delegate: AppDelegate) {
        self.model = model
        self.delegate = delegate
        textView = VimTextView(usingTextLayoutManager: true)
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 960, height: 760),
            styleMask: [.borderless],
            backing: .buffered,
            defer: true
        )
        super.init()
    }

    func present() {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        scroll.autohidesScrollers = true
        textView.commonInit()
        textView.engine = model.engine
        textView.layoutAdapter.textView = textView
        model.engine.layout = textView.layoutAdapter
        textView.vimDelegate = self
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        scroll.documentView = textView

        window.title = model.title
        window.isReleasedWhenClosed = false
        window.hasShadow = true
        window.isMovableByWindowBackground = true
        window.delegate = delegate
        window.contentView = scroll
        window.setContentSize(NSSize(width: 960, height: 760))
        window.center()
        window.makeKeyAndOrderFront(nil)
        WindowChrome.apply(model.theme, to: window)

        textView.columnWidth = model.theme.columnWidth
        textView.isDirectoryBuffer = model.isDirectory
        textView.applyTheme(model.theme, focus: model.focusMode)
        textView.syncFromEngine()
        textView.restyleNow()
        window.makeFirstResponder(textView)
    }

    func vimTextView(_ view: VimTextView, didHandle result: EngineResult) {
        model.handleEngineResult(result)
    }

    func vimTextViewDidClick(_ view: VimTextView, characterOffset: Int, commandClick: Bool) {
        if commandClick {
            model.goToDefinition()
        }
    }
}
