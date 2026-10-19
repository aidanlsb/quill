import AppKit
import SwiftUI
import UniformTypeIdentifiers

@main
struct QuillApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            EditorRoot(model: appDelegate.model, delegate: appDelegate)
        }
        .defaultSize(width: 960, height: 760)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New") { appDelegate.model.newUntitled() }
                    .keyboardShortcut("n", modifiers: .command)
                Button("Open…") { appDelegate.model.openPanel() }
                    .keyboardShortcut("o", modifiers: .command)
                Button("Save") { appDelegate.model.save() }
                    .keyboardShortcut("s", modifiers: .command)
                Button("Save As…") { appDelegate.model.saveAs() }
                    .keyboardShortcut("s", modifiers: [.command, .shift])
            }
            CommandGroup(after: .toolbar) {
                Button("Find Files") { appDelegate.model.presentFilePicker() }
                    .keyboardShortcut("p", modifiers: .command)
                Button("Live Grep") { appDelegate.model.presentGrepPicker() }
                    .keyboardShortcut("f", modifiers: [.command, .shift])
                Button("Focus Mode") { appDelegate.model.toggleFocus() }
                    .keyboardShortcut("f", modifiers: [.command, .control])
                Button("Go to Definition") { appDelegate.model.goToDefinition() }
                    .keyboardShortcut("d", modifiers: .command)
            }
            CommandGroup(after: .sidebar) {
                Button("Toggle Light/Dark") { appDelegate.model.toggleTheme() }
                    .keyboardShortcut("l", modifiers: [.command, .shift])
            }
        }
    }
}

/// The document view. An existing window prefers the `quill://` event so a
/// warm launch does not try to open a second scene and then show neither.
private struct EditorRoot: View {
    @Bindable var model: AppModel
    var delegate: AppDelegate

    var body: some View {
        ContentView(model: model)
            .frame(minWidth: 720, minHeight: 480)
            .handlesExternalEvents(preferring: ["*"], allowing: ["*"])
            .onAppear { delegate.noteWindow() }
            .onOpenURL { url in
                delegate.accept(url)
            }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var ownedModel: AppModel?
    private var pending: [URL] = []
    private var launched = false
    /// `quill://` was delivered. SwiftUI will not open a window for that event
    /// once this delegate has taken `kAEGetURL`, so we open one ourselves.
    private var quillOpenNeedsWindow = false
    private var ensuringWindow = false
    private var hostedWindow: NSWindow?

    var model: AppModel {
        if let ownedModel { return ownedModel }
        let created = AppModel()
        ownedModel = created
        return created
    }

    override init() {
        super.init()
        QuillTrace.event("delegateInit")
    }

    func attach(_ model: AppModel) {
        ownedModel = model
        drainPending()
        AppSmoke.noteAttachedModel()
    }

    func noteWindow() {
        attach(model)
        model.consumeLaunchArguments(Array(CommandLine.arguments.dropFirst()))
        let app = NSApplication.shared
        app.windows.forEach { $0.delegate = self }
        WindowChrome.apply(theme: model.theme)
        QuillTrace.event("keyWindow")
        AppPerf.noteKeyWindow()
        AppSmoke.noteWindowAppeared()
        AppSmoke.runIfRequested(model: model)
        ensureDocumentWindowIfNeeded()
        AppActivation.bringForward()
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        installURLHandler()
        // `.regular` before any window exists. A quill:// open from the CLI
        // otherwise comes up behind the terminal.
        AppActivation.prepare()
        QuillTrace.event("willFinishLaunching")
        // A background shell does not activate the app, so the SwiftUI window
        // may never appear. Arm the smoke watchdog before that wait.
        AppSmoke.prepareIfRequested()
    }

    /// Apple events arrive on the main thread, sometimes before SwiftUI has
    /// attached the model. Taking this event is what stops WindowGroup from
    /// creating a window; `ensureDocumentWindowIfNeeded` opens one instead.
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
        if url.scheme == "quill" {
            quillOpenNeedsWindow = true
        }
        if ownedModel != nil || launched {
            model.open(url: url)
        } else {
            pending.append(url)
        }
        if launched {
            ensureDocumentWindowIfNeeded()
        }
        AppActivation.bringForward()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        launched = true
        installURLHandler()
        drainPending()
        // SwiftUI may still be building its window. Front that one if it is
        // already on screen; the task below opens a window if it never appears.
        if quillOpenNeedsWindow, let existing = documentWindow(), existing.isVisible {
            show(existing)
            quillOpenNeedsWindow = false
        }
        AppActivation.bringForward()
        QuillTrace.event("didFinishLaunching")
        // Do not wait for onAppear. That callback is the only thing that used
        // to start smoke, and it never runs when no window becomes key.
        AppSmoke.launchDidFinish(model: ownedModel)
        AppPerf.launchDidFinish()
        Task { @MainActor in
            installURLHandler()
            ensureDocumentWindowIfNeeded()
            AppActivation.bringForward()
        }
    }

    private func installURLHandler() {
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleGetURLEvent(_:withReplyEvent:)),
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL)
        )
    }

    /// Front a document window. SwiftUI's scene is used when it already has
    /// one; otherwise a hosted window shows the same model the URL opened.
    private func ensureDocumentWindowIfNeeded() {
        guard quillOpenNeedsWindow, !ensuringWindow else { return }
        let env = ProcessInfo.processInfo.environment
        if env["QUILL_SMOKE"] == "1" || env["QUILL_PERF"] == "1" { return }
        ensuringWindow = true
        defer { ensuringWindow = false }
        AppActivation.prepare()
        if let existing = documentWindow() {
            show(existing)
            quillOpenNeedsWindow = false
            return
        }
        if let hostedWindow {
            show(hostedWindow)
            quillOpenNeedsWindow = false
            return
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 960, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Quill"
        window.isReleasedWhenClosed = false
        window.collectionBehavior = window.collectionBehavior.union(.moveToActiveSpace)
        window.contentViewController = NSHostingController(
            rootView: EditorRoot(model: model, delegate: self)
        )
        window.delegate = self
        hostedWindow = window
        WindowChrome.apply(model.theme, to: window)
        window.center()
        show(window)
        quillOpenNeedsWindow = false
    }

    private func show(_ window: NSWindow) {
        window.collectionBehavior = window.collectionBehavior.union(.moveToActiveSpace)
        let app = NSApplication.shared
        app.activate()
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        app.activate()
    }

    private func documentWindow() -> NSWindow? {
        let candidates = NSApplication.shared.windows.filter { window in
            window.canBecomeKey
                && window.styleMask.contains(.titled)
                && window.frame.width > 200
                && window.frame.height > 80
        }
        return candidates.first { $0.isVisible } ?? candidates.first
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Smoke and the perf probe open their own windows before the SwiftUI
        // window exists, then release them. Closing that last window must not
        // terminate the process mid-check. Those modes exit on their own.
        let env = ProcessInfo.processInfo.environment
        return env["QUILL_SMOKE"] != "1" && env["QUILL_PERF"] != "1"
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        ownedModel?.requestTerminate() ?? .terminateNow
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        ownedModel?.requestClose(sender) ?? true
    }

    private func drainPending() {
        guard let ownedModel, !pending.isEmpty else { return }
        let urls = pending
        pending.removeAll()
        urls.forEach { ownedModel.open(url: $0) }
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
