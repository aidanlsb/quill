import AppKit
import QuillSearch
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
                ForEach(model.menuEntries(category: "File")) { entry in
                    menuButton(entry)
                }
            }
            CommandGroup(after: .toolbar) {
                ForEach(model.menuEntries(category: "Search")) { entry in
                    menuButton(entry)
                }
                ForEach(model.menuEntries(category: "Navigate")) { entry in
                    menuButton(entry)
                }
            }
            CommandGroup(after: .sidebar) {
                ForEach(model.menuEntries(category: "View")) { entry in
                    menuButton(entry)
                }
                ForEach(model.menuEntries(category: "Edit")) { entry in
                    menuButton(entry)
                }
            }
        }
    }

    @ViewBuilder
    private func menuButton(_ entry: CommandEntry) -> some View {
        let enabled = model.isCommandEnabled(id: entry.id)
        if let chord = menuChord(for: entry) {
            Button(entry.name) { model.runCommand(entry.id) }
                .keyboardShortcut(KeyEquivalent(chord.key), modifiers: chord.modifiers)
                .disabled(!enabled)
        } else {
            Button(entry.name) { model.runCommand(entry.id) }
                .disabled(!enabled)
        }
    }

    private func menuChord(for entry: CommandEntry) -> (key: Character, modifiers: EventModifiers)? {
        for binding in entry.bindings {
            guard case .chord(let key, let command, let shift, let option, let control) = binding.kind else { continue }
            var modifiers: EventModifiers = []
            if command { modifiers.insert(.command) }
            if shift { modifiers.insert(.shift) }
            if option { modifiers.insert(.option) }
            if control { modifiers.insert(.control) }
            return (key, modifiers)
        }
        return nil
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
