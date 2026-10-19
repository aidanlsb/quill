import AppKit
import QuillVim
import XCTest
@testable import Quill

@MainActor
extension Probe {
    static func checkCommandPalette(failures: Failures) {
        let model = AppModel()
        let cursor = model.engine.cursor
        check(model.engine.mode == .normal, "palette started in \(model.engine.mode.displayName)", failures: failures)
        model.presentCommandPalette()
        check(model.pickerKind == .commands, "palette did not open", failures: failures)
        model.handlePicker(.escape)
        check(model.picker == nil, "palette stayed open after escape", failures: failures)
        check(model.engine.mode == .normal, "palette escape left \(model.engine.mode.displayName)", failures: failures)
        check(model.engine.cursor == cursor, "palette escape moved the cursor", failures: failures)

        _ = model.engine.type("i")
        check(model.engine.mode == .insert, "palette insert setup \(model.engine.mode.displayName)", failures: failures)
        let insertCursor = model.engine.cursor
        model.presentCommandPalette()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 640),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        window.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        var host = showPicker(window, model)
        let opened = waitUntil(seconds: 0.8) {
            settle(host, window)
            let hint = queryField(in: host)?.placeholderAttributedString?.string ?? ""
            return hint == "Command"
                && queryField(in: host)?.stringValue.isEmpty == true
                && modeField(in: host)?.stringValue == "INSERT"
                && (caretView(in: host)?.bounds.height ?? 0) >= 8
        }
        guard opened else {
            failures.append("palette query field missing \(viewDump(host))")
            return
        }
        for character in "foc" {
            model.handlePicker(.character(character))
        }
        host = showPicker(window, model)
        let filtered = waitUntil(seconds: 0.6) {
            settle(host, window)
            let titles = resultTitles(in: host)
            let shortcut = fields("quill.picker.shortcut", in: host).first?.stringValue ?? ""
            return queryField(in: host)?.stringValue == "foc"
                && titles.first?.contains("Focus Mode") == true
                && shortcut == "\u{2303}\u{2318}F"
        }
        let shown = queryField(in: host)?.stringValue ?? ""
        let titles = resultTitles(in: host)
        let shortcut = fields("quill.picker.shortcut", in: host).first?.stringValue ?? ""
        check(filtered && shown == "foc", "palette query showed \(shown) results \(titles)", failures: failures)
        check(titles.first?.contains("Focus Mode") == true, "palette results \(titles)", failures: failures)
        check(shortcut == "\u{2303}\u{2318}F", "palette shortcut \(shortcut)", failures: failures)
        if let title = resultFields(in: host).first,
           let shortcutField = fields("quill.picker.shortcut", in: host).first {
            let titleFrame = title.convert(title.bounds, to: host)
            let shortcutFrame = shortcutField.convert(shortcutField.bounds, to: host)
            check(
                shortcutFrame.minX > titleFrame.maxX,
                "palette shortcut overlapped the title \(shortcutFrame) \(titleFrame)",
                failures: failures
            )
            check(
                shortcutFrame.maxX > host.bounds.width * 0.75,
                "palette shortcut was not trailing \(shortcutFrame.maxX) of \(host.bounds.width)",
                failures: failures
            )
        } else {
            failures.append("palette row missing title or shortcut \(viewDump(host))")
        }
        model.handlePicker(.enter)
        check(model.focusMode, "palette focus command did not run", failures: failures)
        check(model.picker == nil, "palette stayed open after enter", failures: failures)
        check(model.engine.mode == .insert, "palette enter left \(model.engine.mode.displayName)", failures: failures)
        check(model.engine.cursor == insertCursor, "palette enter moved the cursor", failures: failures)

        model.presentCommandPalette()
        host = showPicker(window, model)
        let recent = waitUntil(seconds: 0.6) {
            settle(host, window)
            return resultTitles(in: host).first?.contains("Focus Mode") == true
        }
        check(recent, "palette recent order \(resultTitles(in: host))", failures: failures)
        model.handlePicker(.escape)
        check(model.picker == nil, "palette stayed open after the second escape", failures: failures)
        check(model.engine.mode == .insert, "palette second escape left \(model.engine.mode.displayName)", failures: failures)
        check(model.focusMode, "palette escape cleared focus mode", failures: failures)
    }

    /// A fresh hosting view shows the picker's current query, caret, and rows.
    /// Reusing one view left the previous insert-mode caret in the tree.
}

final class PaletteTests: QuillAppTestCase {
    @MainActor
    func testCommandPalette() {
        let failures = Failures()
        Probe.checkCommandPalette(failures: failures)
    }
}
