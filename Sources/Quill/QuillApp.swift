import AppKit
import SwiftUI
import UniformTypeIdentifiers

@main
struct QuillApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
                .frame(minWidth: 720, minHeight: 480)
                .onAppear {
                    appDelegate.attach(model)
                    AppActivation.bringForward()
                    model.consumeLaunchArguments(Array(CommandLine.arguments.dropFirst()))
                    NSApplication.shared.windows.forEach { $0.delegate = appDelegate }
                    WindowChrome.apply(theme: model.theme)
                    QuillTrace.event("keyWindow")
                    AppPerf.noteKeyWindow()
                    AppSmoke.noteWindowAppeared()
                    AppSmoke.runIfRequested(model: model)
                }
                .onOpenURL { url in
                    model.open(url: url)
                    AppActivation.bringForward()
                }
        }
        .defaultSize(width: 960, height: 760)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New") { model.newUntitled() }
                    .keyboardShortcut("n", modifiers: .command)
                Button("Open…") { model.openPanel() }
                    .keyboardShortcut("o", modifiers: .command)
                Button("Save") { model.save() }
                    .keyboardShortcut("s", modifiers: .command)
                Button("Save As…") { model.saveAs() }
                    .keyboardShortcut("s", modifiers: [.command, .shift])
            }
            CommandGroup(after: .toolbar) {
                Button("Find Files") { model.presentFilePicker() }
                    .keyboardShortcut("p", modifiers: .command)
                Button("Live Grep") { model.presentGrepPicker() }
                    .keyboardShortcut("f", modifiers: [.command, .shift])
                Button("Focus Mode") { model.toggleFocus() }
                    .keyboardShortcut("f", modifiers: [.command, .control])
                Button("Go to Definition") { model.goToDefinition() }
                    .keyboardShortcut("d", modifiers: .command)
            }
            CommandGroup(after: .sidebar) {
                Button("Toggle Light/Dark") { model.toggleTheme() }
                    .keyboardShortcut("l", modifiers: [.command, .shift])
            }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var model: AppModel?
    private var pending: [URL] = []

    override init() {
        super.init()
        QuillTrace.event("delegateInit")
    }

    func attach(_ model: AppModel) {
        self.model = model
        drainPending()
        AppSmoke.noteAttachedModel()
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleGetURLEvent(_:withReplyEvent:)),
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL)
        )
        // `.regular` before any window exists. A quill:// open from the CLI
        // otherwise comes up behind the terminal.
        AppActivation.prepare()
        QuillTrace.event("willFinishLaunching")
        // A background shell does not activate the app, so the SwiftUI window
        // may never appear. Arm the smoke watchdog before that wait.
        AppSmoke.prepareIfRequested()
    }

    /// Apple events arrive on the main thread, sometimes before SwiftUI has
    /// attached the model. `NSApp` is not required; the URL is queued.
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

    private func accept(_ url: URL) {
        if let model {
            model.open(url: url)
        } else {
            pending.append(url)
        }
        AppActivation.bringForward()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        drainPending()
        AppActivation.bringForward()
        QuillTrace.event("didFinishLaunching")
        // Do not wait for onAppear. That callback is the only thing that used
        // to start smoke, and it never runs when no window becomes key.
        AppSmoke.launchDidFinish(model: model)
        AppPerf.launchDidFinish()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Smoke and the perf probe open their own windows before the SwiftUI
        // window exists, then release them. Closing that last window must not
        // terminate the process mid-check. Those modes exit on their own.
        let env = ProcessInfo.processInfo.environment
        return env["QUILL_SMOKE"] != "1" && env["QUILL_PERF"] != "1"
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        model?.requestTerminate() ?? .terminateNow
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        model?.requestClose(sender) ?? true
    }

    private func drainPending() {
        guard let model, !pending.isEmpty else { return }
        let urls = pending
        pending.removeAll()
        urls.forEach { model.open(url: $0) }
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
