import AppKit
import QuillSearch
import QuillWorkspace
import SwiftUI

/// SwiftUI starts the process. It does not build the document window: that scene was the launch.
@main
struct QuillApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    init() {
        StartupProbe.mark("appInit")
    }

    var body: some Scene {
        // No document scene. Settings is inert until opened; the delegate makes the editor window.
        Settings {
            EmptyView()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuItemValidation {
    private var ownedModel: AppModel?
    private var pending: [URL] = []
    private var launchWindowShown = false
    private var shell: EditorShell?
    private var hostedWindow: NSWindow?
    private let handoff = HandoffBox()
    private var instance: InstanceServer?
    static weak var current: AppDelegate?

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
        if !Self.standaloneLaunch() {
            let targets = LaunchRequest.parse(Array(CommandLine.arguments.dropFirst()))
            let box = handoff
            switch InstanceBridge.claim(socket: Self.socketPath(), targets: targets, onMessage: { box.deliver($0) }) {
            case .delivered:
                exit(0)
            case .primary(let server):
                instance = server
            case .unavailable:
                break
            }
        }
        QuillTrace.event("delegateInit")
        StartupProbe.arm()
        Self.current = self
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        handoff.set { targets in
            DispatchQueue.main.async {
                // The main queue is the main thread. assumeIsolated hops onto the main actor.
                MainActor.assumeIsolated {
                    AppDelegate.current?.acceptHandoff(targets)
                }
            }
        }
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
        StartupProbe.mark("activated")
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
        StartupUI.noteFileArrival(model)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        StartupProbe.mark("didFinish")
        installURLHandler()
        model.consumeLaunchArguments(Array(CommandLine.arguments.dropFirst()), immediate: true)
        drainPending()
        let window = ensureShell()
        StartupProbe.mark("windowMade")
        shell?.displayDocument()
        installMenus()
        show(window)
        if let textView = shell?.textView {
            window.makeFirstResponder(textView)
            textView.layoutSubtreeIfNeeded()
            textView.display()
        }
        window.display()
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

    func applicationWillTerminate(_ notification: Notification) {
        instance?.stop()
    }

    func acceptHandoff(_ targets: [LaunchTarget]) {
        for target in targets {
            accept(LaunchRequest.url(for: target))
        }
        guard launchWindowShown else { return }
        if let hostedWindow {
            show(hostedWindow)
            if let textView = shell?.textView {
                hostedWindow.makeFirstResponder(textView)
            }
        }
        AppActivation.bringForward()
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
        AppActivation.activate(window)
    }

    /// `QUILL_SOCKET` in the environment, or the same path passed on argv.
    /// `open` drops the environment; the argument still names the socket.
    private static func socketPath() -> String {
        let args = CommandLine.arguments
        if let index = args.firstIndex(of: "--quill-socket"), index + 1 < args.count {
            return args[index + 1]
        }
        return InstanceSocket.path()
    }

    private static func standaloneLaunch() -> Bool {
        let env = ProcessInfo.processInfo.environment
        if env["QUILL_SMOKE"] == "1" || env["QUILL_PERF"] == "1" || env["QUILL_STANDALONE"] == "1" {
            return true
        }
        return CommandLine.arguments.contains("--quill-standalone")
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

/// Cold launches come from `open -a`, which is what macOS 14+ will activate.
/// A handoff to the running app orders that same window forward.
@MainActor
enum AppActivation {
    static func prepare() {
        let app = NSApplication.shared
        if app.activationPolicy() != .regular {
            _ = app.setActivationPolicy(.regular)
        }
    }

    static func bringForward() {
        let app = NSApplication.shared
        let window = app.keyWindow ?? app.windows.first { $0.canBecomeKey } ?? app.windows.first
        activate(window)
    }

    static func activate(_ window: NSWindow?) {
        prepare()
        let app = NSApplication.shared
        app.activate()
        if !app.isActive {
            app.activate(ignoringOtherApps: true)
        }
        if let window {
            window.collectionBehavior.insert(.moveToActiveSpace)
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
        }
    }
}

// quill-concurrency: NSLock guards the handler the accept thread calls before the delegate is ready.
private final class HandoffBox: @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (@Sendable ([LaunchTarget]) -> Void)?
    private var queued: [[LaunchTarget]] = []

    func set(_ handler: @escaping @Sendable ([LaunchTarget]) -> Void) {
        lock.lock()
        self.handler = handler
        let pending = queued
        queued.removeAll()
        lock.unlock()
        for batch in pending {
            handler(batch)
        }
    }

    func deliver(_ targets: [LaunchTarget]) {
        lock.lock()
        let handler = self.handler
        if handler == nil {
            queued.append(targets)
        }
        lock.unlock()
        handler?(targets)
    }
}
