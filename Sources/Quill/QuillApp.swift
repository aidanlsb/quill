import AppKit
import SwiftUI
import UniformTypeIdentifiers

@main
struct QuillApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
                .frame(minWidth: 720, minHeight: 480)
                .onAppear {
                    appDelegate.model = model
                    NSApp.setActivationPolicy(.regular)
                    consumeLaunchURLs()
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

    private func consumeLaunchURLs() {
        let extras = CommandLine.arguments.dropFirst()
        if let first = extras.first {
            let url = URL(fileURLWithPath: first)
            model.open(url: url)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var model: AppModel?
    private var pending: [URL] = []

    func application(_ application: NSApplication, open urls: [URL]) {
        if let model {
            urls.forEach { model.open(url: $0) }
        } else {
            pending.append(contentsOf: urls)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let model, let url = pending.first {
            model.open(url: url)
            pending.removeAll()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
