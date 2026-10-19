import AppKit
import Foundation
import QuillVim
import SwiftUI
/// `QUILL_SMOKE=1` launch check. Prints `quill smoke passed` or `FAIL …` and exits.
enum AppSmoke {
    @MainActor private static var started = false
    @MainActor private static let trace = SmokeTraceStore()
    @MainActor
    static func prepareIfRequested() {
        guard ProcessInfo.processInfo.environment["QUILL_SMOKE"] == "1" else { return }
        trace.arm(seconds: 20)
        fputs("quill smoke: watchdog armed (20s)\n", stderr)
        fflush(stderr)
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        app.activate()
        noteAppKit(probe: false)
    }
    @MainActor
    static func noteAttachedModel() {
        trace.update {
            $0.modelAttached = true
            if $0.modelSource == "none" { $0.modelSource = "swiftui" }
        }
    }
    @MainActor
    static func noteWindowAppeared() {
        trace.update { $0.windowAppeared = true }
        noteAppKit(probe: false)
    }
    @MainActor
    static func launchDidFinish(model: AppModel?) {
        trace.update { $0.launchFinished = true }
        guard ProcessInfo.processInfo.environment["QUILL_SMOKE"] == "1" else { return }
        let resolved = model ?? AppModel()
        trace.update {
            $0.modelAttached = true
            if $0.modelSource == "none" { $0.modelSource = model == nil ? "synthesized" : "swiftui" }
        }
        runIfRequested(model: resolved)
    }
    @MainActor
    static func runIfRequested(model: AppModel) {
        guard !started else { return }
        guard ProcessInfo.processInfo.environment["QUILL_SMOKE"] == "1" else { return }
        started = true
        trace.update { $0.smokeStarted = true }
        fputs("quill smoke started\n", stderr)
        fflush(stderr)
        var failures: [String] = []
        guard let editor = editor(for: model) else {
            finish(["editor view did not appear"])
            return
        }
        if editor.view.engine !== model.engine { failures.append("editor engine is not the model") }
        editor.window.makeFirstResponder(editor.view)
        let before = model.engine.text
        type("ix<Esc>", on: editor.view)
        if model.engine.text == before || editor.view.string != model.engine.text {
            failures.append("keystroke did not change the buffer")
        }
        editor.window.setContentSize(NSSize(
            width: max(720, editor.window.frame.width - 80),
            height: max(480, editor.window.frame.height - 80)
        ))
        editor.view.enclosingScrollView?.layoutSubtreeIfNeeded()
        editor.view.layoutSubtreeIfNeeded()
        finish(failures)
    }
    @MainActor
    static func recordProbeSnapshot() { noteAppKit(probe: true) }
    @MainActor
    private static func finish(_ failures: [String]) {
        if failures.isEmpty {
            fputs("quill smoke passed\n", stderr)
        } else {
            for failure in failures { fputs("FAIL \(failure)\n", stderr) }
        }
        fflush(stderr)
        trace.cancel()
        exit(failures.isEmpty ? 0 : 1)
    }
    @MainActor
    private static func editor(for model: AppModel) -> (view: VimTextView, window: NSWindow)? {
        if let found = wait(model, 1.5) { return found }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 960, height: 760),
            styleMask: [.titled, .resizable, .closable], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
        window.contentViewController = NSHostingController(rootView: EditorView(model: model, diagnostics: model.diagnosticRanges))
        window.makeKeyAndOrderFront(nil)
        return wait(model, 2)
    }
    @MainActor
    private static func wait(_ model: AppModel, _ seconds: TimeInterval) -> (view: VimTextView, window: NSWindow)? {
        let deadline = Date().addingTimeInterval(seconds)
        repeat {
            for window in NSApplication.shared.windows {
                if let view = text(in: window.contentView, engine: model.engine) { return (view, window) }
            }
            if Date() >= deadline { return nil }
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
        } while true
    }
    @MainActor
    private static func text(in view: NSView?, engine: Engine) -> VimTextView? {
        guard let view else { return nil }
        if let text = view as? VimTextView, text.engine === engine { return text }
        if let scroll = view as? NSScrollView, let found = text(in: scroll.documentView, engine: engine) { return found }
        for sub in view.subviews { if let found = text(in: sub, engine: engine) { return found } }
        return nil
    }
    @MainActor
    private static func type(_ notation: String, on view: VimTextView) {
        for event in KeyEvent.parse(notation) {
            let chars: String
            let code: UInt16
            switch event.key {
            case .character(let ch): (chars, code) = (String(ch), 0)
            case .escape: (chars, code) = ("\u{1b}", 53)
            default: continue
            }
            guard let ns = NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: view.window?.windowNumber ?? 0, context: nil,
                characters: chars, charactersIgnoringModifiers: chars,
                isARepeat: false, keyCode: code
            ) else { continue }
            view.keyDown(with: ns)
        }
    }
    @MainActor
    private static func noteAppKit(probe: Bool) {
        let app = NSApplication.shared
        let policy: String
        switch app.activationPolicy() {
        case .regular: policy = "regular"
        case .accessory: policy = "accessory"
        case .prohibited: policy = "prohibited"
        @unknown default: policy = "unknown"
        }
        trace.update {
            $0.activationPolicy = policy
            $0.windowCount = app.windows.count
            if probe { $0.probeAnswered = true }
        }
    }
