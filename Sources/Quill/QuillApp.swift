import AppKit
import QuillSearch

/// AppKit owns startup. A SwiftUI `WindowGroup` was the time between process start and the first editable frame.
@main
enum QuillMain {
    static func main() {
        StartupProbe.mark("appInit")
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuItemValidation {
    private var ownedModel: AppModel?
    private var pending: [URL] = []
    private var launchWindowShown = false
    private var shell: EditorShell?
    private var hostedWindow: NSWindow?

    var model: AppModel {
        if let ownedModel { return ownedModel }
        let began = StartupProbe.begin("modelMs")
        let created = AppModel()
        StartupProbe.end("modelMs", began)
        ownedModel = created
        StartupUI.attach(created)
        return created
    }

    override init() {
        super.init()
        QuillTrace.event("delegateInit")
        StartupProbe.arm()
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        StartupProbe.mark("willFinish")
        installURLHandler()
        // `.regular` before any window exists. A quill:// open from the CLI
        // otherwise comes up behind the terminal.
        AppActivation.prepare()
        QuillTrace.event("willFinishLaunching")
        // A background shell does not activate the app. Arm the smoke watchdog
        // before that wait, and build the model so a URL that arrives next can
        // read its file before the window is shown.
        AppSmoke.prepareIfRequested()
        _ = model
    }

    /// Apple events arrive on the main thread. The file is installed before
    /// `applicationDidFinishLaunching` returns, which is before the first draw.
    @objc nonisolated func handleGetURLEvent(
        _ event: NSAppleEventDescriptor,
        withReplyEvent reply: NSAppleEventDescriptor
    ) {
        guard let urlString = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue,
              let url = URL(string: urlString) else { return }
        // quill-concurrency: The Apple event arrives on the main thread; assumeIsolated hops without capturing self.
        nonisolated(unsafe) let delegate = self
        MainActor.assumeIsolated {
            delegate.accept(url)
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        urls.forEach { accept($0) }
    }

    func accept(_ url: URL) {
        if !launchWindowShown {
            if ownedModel == nil {
                pending.append(url)
            } else {
                model.open(url: url, immediate: true)
            }
            return
        }
        model.open(url: url)
        if let hostedWindow {
            show(hostedWindow)
        }
        AppActivation.bringForward()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        StartupProbe.mark("didFinish")
        installURLHandler()
        model.consumeLaunchArguments(Array(CommandLine.arguments.dropFirst()), immediate: true)
        drainPending()
        let window = ensureShell()
        shell?.displayDocument()
        installMenus()
        show(window)
        if let textView = shell?.textView {
            window.makeFirstResponder(textView)
        }
        launchWindowShown = true
        WindowChrome.apply(theme: model.theme)
        QuillTrace.event("keyWindow")
        AppPerf.noteKeyWindow()
        StartupUI.noteKeyWindow()
        AppSmoke.noteAttachedModel()
        AppSmoke.noteWindowAppeared()
        AppSmoke.launchDidFinish(model: model)
        AppPerf.launchDidFinish()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // The perf probe opens a window and orders it out. Closing that last
        // window must not terminate the process before `quill perf done`.
        // The launch smoke exits on its own and does not open throwaway windows.
        ProcessInfo.processInfo.environment["QUILL_PERF"] != "1"
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        ownedModel?.requestTerminate() ?? .terminateNow
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        ownedModel?.requestClose(sender) ?? true
    }

    @objc func runMenuCommand(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        model.runCommand(id)
    }

    @objc func validateMenuItem(_ item: NSMenuItem) -> Bool {
        guard let id = item.representedObject as? String else { return true }
        return model.isCommandEnabled(id: id)
    }

    private func installURLHandler() {
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleGetURLEvent(_:withReplyEvent:)),
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL)
        )
    }

    private func ensureShell() -> NSWindow {
        if let hostedWindow { return hostedWindow }
        let shell = EditorShell(model: model)
        self.shell = shell
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 960, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Quill"
        window.isReleasedWhenClosed = false
        window.collectionBehavior.insert(.moveToActiveSpace)
        window.contentMinSize = NSSize(width: 720, height: 480)
        window.contentViewController = shell
        window.delegate = self
        WindowChrome.apply(model.theme, to: window)
        window.center()
        hostedWindow = window
        return window
    }

    private func show(_ window: NSWindow) {
        window.collectionBehavior.insert(.moveToActiveSpace)
        let app = NSApplication.shared
        app.activate()
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        app.activate()
    }

    private func drainPending() {
        guard ownedModel != nil, !pending.isEmpty else { return }
        let urls = pending
        pending.removeAll()
        urls.forEach { model.open(url: $0, immediate: true) }
    }

    private func installMenus() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        appItem.submenu = appMenu
        appMenu.addItem(
            withTitle: "About Quill",
            action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
            keyEquivalent: ""
        )
        appMenu.addItem(.separator())
        appMenu.addItem(
            withTitle: "Quit Quill",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )

        addMenu("File", to: main) { addCommands(category: "File", to: $0) }
        addMenu("Edit", to: main) { menu in
            addStandardEditItems(to: menu)
            if !model.menuEntries(category: "Edit").isEmpty {
                menu.addItem(.separator())
                addCommands(category: "Edit", to: menu)
            }
        }
        addMenu("Search", to: main) { addCommands(category: "Search", to: $0) }
        addMenu("Navigate", to: main) { addCommands(category: "Navigate", to: $0) }
        addMenu("View", to: main) { addCommands(category: "View", to: $0) }
        NSApplication.shared.mainMenu = main
    }

    private func addMenu(_ title: String, to main: NSMenu, fill: (NSMenu) -> Void) {
        let item = NSMenuItem()
        main.addItem(item)
        let menu = NSMenu(title: title)
        item.submenu = menu
        fill(menu)
    }

    private func addCommands(category: String, to menu: NSMenu) {
        for entry in model.menuEntries(category: category) {
            let item = NSMenuItem(title: entry.name, action: #selector(runMenuCommand(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = entry.id
            if let chord = menuChord(for: entry) {
                item.keyEquivalent = String(chord.key).lowercased()
                item.keyEquivalentModifierMask = chord.flags
            }
            menu.addItem(item)
        }
    }

    private func addStandardEditItems(to menu: NSMenu) {
        menu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        menu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        menu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        menu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        menu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
    }

    private func menuChord(for entry: CommandEntry) -> (key: Character, flags: NSEvent.ModifierFlags)? {
        for binding in entry.bindings {
            guard case .chord(let key, let command, let shift, let option, let control) = binding.kind else { continue }
            var flags: NSEvent.ModifierFlags = []
            if command { flags.insert(.command) }
            if shift { flags.insert(.shift) }
            if option { flags.insert(.option) }
            if control { flags.insert(.control) }
            return (key, flags)
        }
        return nil
    }
}

/// `open -a` asks Launch Services to activate Quill. The window still has to
/// be ordered front: a quill:// delivery can arrive before the window exists,
/// and a direct binary launch never becomes key on its own.
@MainActor
enum AppActivation {
    static func prepare() {
        let app = NSApplication.shared
        if app.activationPolicy() != .regular {
            _ = app.setActivationPolicy(.regular)
        }
    }

    static func bringForward() {
        prepare()
        let app = NSApplication.shared
        app.activate()
        if let key = app.keyWindow {
            key.makeKeyAndOrderFront(nil)
            return
        }
        if let window = app.windows.first(where: { $0.canBecomeKey }) ?? app.windows.first {
            window.makeKeyAndOrderFront(nil)
        }
    }
}
