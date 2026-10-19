import AppKit
import SwiftUI
import UniformTypeIdentifiers
import QuillWorkspace

@main
enum QuillMain {
    static func main() {
        let targets = LaunchRequest.parse(Array(CommandLine.arguments.dropFirst()))
        if targets.isEmpty {
            QuillApp.main()
        } else {
            FastOpen.main()
        }
    }
}

struct QuillApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @State private var model = AppModel()

    var body: some Scene {
        let _ = appDelegate.attach(model)
        WindowGroup {
            EditorHost(model: model, appDelegate: appDelegate)
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

/// Launch-argument open lives here so both the SwiftUI scene and the fallback window run it.
private struct EditorHost: View {
    var model: AppModel
    var appDelegate: AppDelegate

    var body: some View {
        ContentView(model: model)
            .frame(minWidth: 720, minHeight: 480)
            .onAppear {
                appDelegate.attach(model)
                NSApplication.shared.setActivationPolicy(.regular)
                model.consumeLaunchArguments(Array(CommandLine.arguments.dropFirst()))
                NSApplication.shared.windows.forEach { $0.delegate = appDelegate }
                WindowChrome.apply(theme: model.theme)
                OpenReadyProbe.armIfRequested()
                AppSmoke.runIfRequested(model: model)
            }
            .onOpenURL { url in
                model.open(url: url)
            }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var model: AppModel?
    private var pending: [URL] = []
    /// Retained when SwiftUI declines to open its own window. See `presentMainWindowIfNeeded`.
    private var launchedWindow: NSWindow?

    func attach(_ model: AppModel) {
        self.model = model
        drainPending()
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        // A bare exec is not a bundled app. AppKit leaves it prohibited, and then no window appears.
        NSApplication.shared.setActivationPolicy(.regular)
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleGetURLEvent(_:withReplyEvent:)),
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL)
        )
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
    }

    /// AppKit treats a bare path argument as a document open. SwiftUI then skips its
    /// default window, so `onAppear` never runs and the launch-argument open never starts.
    /// Claiming the file here lets that path proceed. The bytes are loaded from argv.
    func application(_ sender: NSApplication, openFile filename: String) -> Bool {
        _ = filename
        return true
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        drainPending()
        NSApplication.shared.activate()
        OpenReadyProbe.armIfRequested()
        presentMainWindowIfNeeded()
    }

    /// SwiftUI's `WindowGroup` stays empty when argv contains a path. Host the same
    /// `ContentView` so launch-argument open still runs from `onAppear`.
    private func presentMainWindowIfNeeded() {
        guard let model else { return }
        if NSApplication.shared.windows.contains(where: \.isVisible) { return }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 960, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Quill"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.titlebarSeparatorStyle = .none
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(
            rootView: EditorHost(model: model, appDelegate: self)
        )
        window.delegate = self
        window.center()
        launchedWindow = window
        window.makeKeyAndOrderFront(nil)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
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
