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
                    NSApp.setActivationPolicy(.regular)
                    model.consumeLaunchArguments(Array(CommandLine.arguments.dropFirst()))
                    NSApp.windows.forEach { $0.delegate = appDelegate }
                }
                .onOpenURL { url in
                    model.open(url: url)
                }
        }
        .defaultSize(width: 960, height: 760)
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
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var model: AppModel?
    private var pending: [URL] = []

    func attach(_ model: AppModel) {
        self.model = model
        drainPending()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        if let model {
            urls.forEach { model.open(url: $0) }
        } else {
            pending.append(contentsOf: urls)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        drainPending()
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
