import AppKit
import QuartzCore
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

    /// Text view and borderless window, with no file yet. Built before the GetURL event is dispatched.
    static func prepare() -> FastEditor {
        let delegate = AppDelegate()
        let model = AppModel()
        delegate.attach(model)
        let editor = FastEditor(model: model, delegate: delegate)
        session = editor
        editor.installShell()
        return editor
    }

    static func main(launchURL: URL? = nil, applicationReady: Bool = false) {
        // Registered, not stored. State restoration and window tabbing both run
        // while the first window is ordered front.
        UserDefaults.standard.register(defaults: [
            "ApplePersistenceIgnoreState": true,
            "NSQuitAlwaysKeepsWindows": false,
            "NSAutomaticWindowAnimationsEnabled": false,
        ])
        NSWindow.allowsAutomaticWindowTabbing = false
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let editor = prepare()
        show(editor, launchURL: launchURL, applicationReady: applicationReady)
    }

    static func show(_ editor: FastEditor, launchURL: URL? = nil, applicationReady: Bool = false) {
        let app = NSApplication.shared
        app.delegate = editor.delegate
        if applicationReady {
            // finishLaunching already ran, so willFinish will not install this handler.
            editor.delegate.installURLHandler()
        }
        OpenReadyProbe.armIfRequested()
        if let launchURL {
            editor.model.open(url: launchURL)
        }
        editor.model.consumeLaunchArguments(Array(CommandLine.arguments.dropFirst()))
        editor.reveal()
        app.activate()
        // A quill:// event is delivered inside the run loop. Starting it again nests forever.
        if !applicationReady {
            app.run()
        }
    }
}

@MainActor
final class FastEditor: NSObject, VimTextViewDelegate {
    let model: AppModel
    let delegate: AppDelegate
    let textView: VimTextView
    let window: NSWindow
    private var scroll: NSScrollView?

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
        model.onEditorState = { [weak self] in
            self?.syncHost()
        }
    }

    func present() {
        installShell()
        reveal()
    }

    func installShell() {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = false
        scroll.hasHorizontalScroller = false
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        textView.prepareForDisplay()
        textView.engine = model.engine
        textView.layoutAdapter.textView = textView
        model.engine.layout = textView.layoutAdapter
        textView.vimDelegate = self
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        scroll.documentView = textView

        window.title = model.title
        window.isReleasedWhenClosed = false
        // Shadow and titlebar chrome wait until the note is styled. Both rebuild
        // window frames, and the ready line only requires the visible text.
        window.hasShadow = false
        window.isMovableByWindowBackground = true
        window.delegate = delegate
        window.animationBehavior = .none
        self.scroll = scroll
    }

    func reveal() {
        window.title = model.title
        // Show the text view on its own. A scroll view's first display builds the
        // scroller, and the heading font does not need that.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        window.contentView = textView
        window.orderFront(nil)
        CATransaction.commit()

        textView.columnWidth = model.theme.columnWidth
        textView.isDirectoryBuffer = model.isDirectory
        textView.applyTheme(model.theme, focus: model.focusMode)
        textView.appliedThemeID = model.themeIdentity
        textView.appliedFocus = model.focusMode
        textView.disableAutomaticSubstitutions()
        // The storage observer lays the buffer out on the first edit. Detach it
        // until the heading font is applied, then put the caret back.
        let observer = textView.textStorage?.textStorageObserver
        textView.textStorage?.textStorageObserver = nil
        textView.syncFromEngine(layout: false)
        textView.restyleNow()
        textView.textStorage?.textStorageObserver = observer
        if let scroll {
            scroll.documentView = textView
            window.contentView = scroll
        }
        textView.syncFromEngine()

        if let scroll = textView.enclosingScrollView {
            scroll.hasVerticalScroller = true
            scroll.autohidesScrollers = true
        }
        window.setContentSize(NSSize(width: 960, height: 760))
        window.center()
        window.hasShadow = true
        WindowChrome.apply(model.theme, to: window)
        window.makeKey()
        window.makeFirstResponder(textView)
    }

    /// `:e`, `-`, and directory Enter replace the engine buffer with `didChangeText == false`,
    /// so `applyResult` leaves the old string on screen. Theme and focus land the same way.
    func syncHost() {
        textView.columnWidth = model.theme.columnWidth
        textView.isDirectoryBuffer = model.isDirectory
        window.title = model.title
        if textView.appliedThemeID != model.themeIdentity || textView.appliedFocus != model.focusMode {
            textView.applyTheme(model.theme, focus: model.focusMode)
            textView.appliedThemeID = model.themeIdentity
            textView.appliedFocus = model.focusMode
            WindowChrome.apply(model.theme, to: window)
        }
        let caret = min(model.engine.cursor, (textView.string as NSString).length)
        if textView.string != model.engine.text || textView.selectedRange().location != caret {
            textView.syncFromEngine()
            textView.restyleNow()
        }
        if model.showUnsaved {
            presentUnsaved()
        }
    }

    func vimTextView(_ view: VimTextView, didHandle result: EngineResult) {
        model.handleEngineResult(result)
        syncHost()
    }

    private var promptingUnsaved = false

    private func presentUnsaved() {
        guard !promptingUnsaved else { return }
        promptingUnsaved = true
        window.makeKeyAndOrderFront(nil)
        let alert = NSAlert()
        alert.messageText = model.message
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Don't Save")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.promptingUnsaved = false
                switch response {
                case .alertFirstButtonReturn:
                    self.model.saveAndContinue()
                case .alertSecondButtonReturn:
                    self.model.discardAndContinue()
                default:
                    self.model.cancelNavigation()
                }
                self.syncHost()
            }
        }
    }

    func vimTextViewDidClick(_ view: VimTextView, characterOffset: Int, commandClick: Bool) {
        if commandClick {
            model.goToDefinition()
        }
    }
}
