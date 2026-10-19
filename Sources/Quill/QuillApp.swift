import AppKit
import Darwin
import SwiftUI
import UniformTypeIdentifiers
import QuillWorkspace

@main
enum QuillMain {
    static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if !LaunchRequest.parse(arguments).isEmpty {
            FastOpen.main()
            return
        }
        // Smoke stays on the SwiftUI editor. A quill:// launch from `open -a` has an empty
        // argv; the GetURL event is not delivered until the run loop is already up.
        if ProcessInfo.processInfo.environment["QUILL_SMOKE"] == "1" {
            QuillApp.main()
            return
        }
        // `open` without -W exits before this process can read its arguments. The launcher
        // passes the same quill:// URL in the environment, which is here at startup.
        if let url = LaunchOpenURL.fromEnvironment() ?? LaunchOpenURL.find() {
            EarlyOpenURL.remember(url)
            FastOpen.main(launchURL: url)
            return
        }
        // No file and no quill:// URL. This call is the first NSApplicationMain.
        // A run loop started before it returns, and a second main never presents a window.
        QuillApp.main()
    }
}

/// `open -a Quill quill://…` does not put the URL on this process's argv. It is still
/// an argument of that `open` process, which is alive while it waits for us. Reading it
/// there avoids the wait until Launch Services delivers the GetURL event.
enum LaunchOpenURL {
    /// `QUILL_LAUNCH_URL` is set by `Scripts/quill` on the app process. `open` does not
    /// keep itself alive for a normal launch, so its argv is not a reliable source.
    static func fromEnvironment() -> URL? {
        guard let raw = getenv("QUILL_LAUNCH_URL") else { return nil }
        return url(inEnvironment: String(cString: raw))
    }

    static func url(inEnvironment raw: String) -> URL? {
        guard let url = URL(string: raw), LaunchRequest.target(from: url) != nil else { return nil }
        return url
    }

    static func find() -> URL? {
        let bundle = Bundle.main
        let bundlePath = bundle.bundlePath
        guard bundlePath.hasSuffix(".app") else { return nil }
        let bundleName = bundle.object(forInfoDictionaryKey: "CFBundleName") as? String ?? ""
        let bundleIdentifier = bundle.bundleIdentifier ?? ""
        let needed = proc_listallpids(nil, 0)
        guard needed > 0 else { return nil }
        var pids = [pid_t](repeating: 0, count: Int(needed) + 64)
        let count = Int(proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size)))
        guard count > 0 else { return nil }
        var byPath: (pid: pid_t, url: URL)?
        var byName: (pid: pid_t, url: URL)?
        for pid in pids.prefix(count) where pid > 0 {
            guard path(of: pid).hasSuffix("/open") else { continue }
            guard let match = self.match(
                in: arguments(of: pid),
                bundlePath: bundlePath,
                bundleName: bundleName,
                bundleIdentifier: bundleIdentifier
            ) else { continue }
            if match.byPath {
                if byPath == nil || pid > byPath!.pid { byPath = (pid, match.url) }
            } else if byName == nil || pid > byName!.pid {
                byName = (pid, match.url)
            }
        }
        return (byPath ?? byName)?.url
    }

    /// The last `quill://` argument, when this command line targets the bundle.
    static func match(
        in arguments: [String],
        bundlePath: String,
        bundleName: String,
        bundleIdentifier: String
    ) -> (url: URL, byPath: Bool)? {
        let bundle = canonical(bundlePath)
        let names = Set([bundleName, bundleIdentifier, (bundle as NSString).lastPathComponent].filter { !$0.isEmpty })
        var byPath = false
        var byName = false
        var found: URL?
        for arg in arguments {
            if names.contains(arg) { byName = true }
            let resolved = canonical(arg)
            if resolved == bundle || resolved.hasPrefix(bundle + "/") { byPath = true }
            if let url = URL(string: arg), LaunchRequest.target(from: url) != nil {
                found = url
            }
        }
        guard let found, byPath || byName else { return nil }
        return (found, byPath)
    }

    private static func canonical(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    }

    private static func path(of pid: pid_t) -> String {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return "" }
        let bytes = buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }

    private static func arguments(of pid: pid_t) -> [String] {
        var mib = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else { return [] }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0, size >= MemoryLayout<Int32>.size else { return [] }
        let argc = buffer.withUnsafeBytes { raw in
            raw.load(fromByteOffset: 0, as: Int32.self)
        }
        var index = MemoryLayout<Int32>.size
        while index < buffer.count, buffer[index] != 0 { index += 1 }
        while index < buffer.count, buffer[index] == 0 { index += 1 }
        let limit = min(max(0, Int(argc)), 64)
        var args: [String] = []
        var start = index
        while index < buffer.count, args.count < limit {
            if buffer[index] == 0 {
                if index > start {
                    args.append(String(decoding: buffer[start..<index], as: UTF8.self))
                }
                start = index + 1
            }
            index += 1
        }
        return args
    }
}

enum EarlyOpenURL {
    // quill-concurrency: The launch URL is written on the main thread during the
    // GetURL handler and read on that same thread by the open probe.
    nonisolated(unsafe) private static var cached: URL?

    static func remember(_ url: URL) {
        guard cached == nil, LaunchRequest.target(from: url) != nil else { return }
        cached = url
    }

    static func current() -> URL? {
        if let cached { return cached }
        guard let event = NSAppleEventManager.shared().currentAppleEvent else { return nil }
        guard event.eventClass == AEEventClass(kInternetEventClass),
              event.eventID == AEEventID(kAEGetURL),
              let raw = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue,
              let url = URL(string: raw),
              LaunchRequest.target(from: url) != nil else { return nil }
        cached = url
        return url
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
        installURLHandler()
    }

    func installURLHandler() {
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
        EarlyOpenURL.remember(url)
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
        if let url = URL(string: filename), url.scheme == "quill" {
            accept(url)
        } else {
            accept(URL(fileURLWithPath: filename))
        }
        return true
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        drainPending()
        NSApplication.shared.activate()
        OpenReadyProbe.armIfRequested()
        // SwiftUI creates its window on this turn. A window built here stacks a second one.
        Task { @MainActor [weak self] in
            self?.presentMainWindowIfNeeded()
        }
    }

    /// SwiftUI's `WindowGroup` stays empty when argv contains a path. Host the same
    /// `ContentView` so launch-argument open still runs from `onAppear`.
    private func presentMainWindowIfNeeded() {
        guard let model else { return }
        // FastOpen already presented the note. A SwiftUI window here would be a second editor.
        if FastOpen.ownsWindow { return }
        if !NSApplication.shared.windows.isEmpty { return }
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
