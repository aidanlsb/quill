import AppKit
import XCTest
@testable import Quill

@MainActor
extension Probe {
    static func checkPicker(failures: Failures) {
        let fixture: TempDirectory
        do {
            fixture = try TempDirectory()
            try fixture.write("notes.md", "alpha notes\n")
            try fixture.write("ideas.md", "beta ideas\n")
        } catch {
            failures.append("picker fixture: \(error.localizedDescription)")
            return
        }
        let root = fixture.url
        defer { withExtendedLifetime(fixture) {} }

        let model = AppModel()
        model.open(url: root)
        model.presentFilePicker()
        // The index finishes on a task. NSHostingView does not redraw when that
        // task assigns `picker`, so the panel is hosted only after it is open
        // and replaced again after each edit.
        let indexed = waitUntil(seconds: 2) { model.picker != nil }
        guard indexed else {
            failures.append("picker did not open (\(model.message))")
            return
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 640),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        window.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        // A new hosting view each time. Assigning rootView on the same
        // NSHostingView leaves the previous caret in the hierarchy.
        var host = showPicker(window, model)
        let opened = waitUntil(seconds: 0.8) {
            settle(host, window)
            let hint = queryField(in: host)?.placeholderAttributedString?.string ?? ""
            return hint == "File name"
                && modeField(in: host)?.stringValue == "INSERT"
                && (caretView(in: host)?.bounds.height ?? 0) >= 8
        }
        guard opened, let field = queryField(in: host) else {
            failures.append("picker query field missing \(viewDump(host))")
            return
        }
        let placeholder = field.placeholderAttributedString?.string ?? field.placeholderString ?? ""
        check(field.stringValue.isEmpty, "picker query was \(field.stringValue) before typing", failures: failures)
        check(placeholder == "File name", "picker placeholder \(placeholder)", failures: failures)
        if let painted = field.textColor {
            let drift = abs(brightness(painted) - brightness(model.theme.textColor))
            let contrast = abs(brightness(painted) - brightness(model.theme.backgroundColor))
            check(drift < 0.08, "picker query color drift \(drift)", failures: failures)
            check(contrast > 0.45, "picker query contrast \(contrast)", failures: failures)
        } else {
            failures.append("picker query color missing")
        }
        check(field.font?.isFixedPitch == true, "picker query font \(field.font?.fontName ?? "")", failures: failures)
        let mode = modeField(in: host)?.stringValue ?? ""
        check(mode == "INSERT", "picker mode \(mode)", failures: failures)
        guard let caretBefore = caretView(in: host) else {
            failures.append("picker caret missing \(viewDump(host))")
            return
        }
        check(caretBefore.bounds.height >= 8, "picker caret height \(caretBefore.bounds.height)", failures: failures)
        check(caretBefore.bounds.width <= 2, "picker caret width \(caretBefore.bounds.width)", failures: failures)
        let caretXBefore = caretBefore.convert(caretBefore.bounds, to: nil).minX

        model.handlePicker(.character("n"))
        model.handlePicker(.character("o"))
        host = showPicker(window, model)
        let filtered = waitUntil(seconds: 0.6) {
            settle(host, window)
            let titles = resultTitles(in: host)
            return queryField(in: host)?.stringValue == "no"
                && titles.contains { $0.contains("notes.md") }
                && !titles.contains { $0.contains("ideas.md") }
        }
        let shown = queryField(in: host)?.stringValue ?? ""
        let titles = resultTitles(in: host)
        check(filtered && shown == "no", "picker query showed \(shown) results \(titles)", failures: failures)
        check(titles.contains { $0.contains("notes.md") }, "picker filter missing notes \(titles)", failures: failures)
        check(!titles.contains { $0.contains("ideas.md") }, "picker filter kept ideas \(titles)", failures: failures)
        if let notes = resultFields(in: host).first(where: { $0.stringValue.contains("notes.md") }) {
            let matched = attrChannel(notes, utf16: 0)
            let rest = attrChannel(notes, utf16: 2)
            check(abs(matched - rest) > 0.12, "picker highlight \(matched) vs \(rest)", failures: failures)
        } else {
            failures.append("picker highlight missing notes row \(titles)")
        }
        if let caretAfter = caretView(in: host) {
            let caretXAfter = caretAfter.convert(caretAfter.bounds, to: nil).minX
            check(caretXAfter > caretXBefore + 2, "picker caret stayed at \(caretXBefore) -> \(caretXAfter)", failures: failures)
        } else {
            failures.append("picker caret disappeared while typing")
        }

        model.handlePicker(.escape)
        host = showPicker(window, model)
        let leftInsert = waitUntil(seconds: 0.4) {
            settle(host, window)
            return modeField(in: host)?.stringValue == "NORMAL" && caretView(in: host) == nil
        }
        let normal = modeField(in: host)?.stringValue ?? ""
        check(leftInsert && normal == "NORMAL", "picker mode \(normal)", failures: failures)
        check(queryField(in: host)?.stringValue == "no", "picker query cleared in normal mode", failures: failures)
        check(caretView(in: host) == nil, "picker caret still drawn in normal mode", failures: failures)

        model.handlePicker(.character("q"))
        model.presentGrepPicker()
        host = showPicker(window, model)
        let grepOpen = waitUntil(seconds: 0.4) {
            settle(host, window)
            let hint = queryField(in: host)?.placeholderAttributedString?.string ?? ""
            return hint == "Pattern" && queryField(in: host)?.stringValue.isEmpty == true
        }
        check(grepOpen, "grep query field \(queryField(in: host)?.stringValue ?? "missing")", failures: failures)
        for character in "alpha" {
            model.handlePicker(.character(character))
        }
        var seenGrep = model.picker?.items.map(\.title) ?? []
        host = showPicker(window, model)
        let grepped = waitUntil(seconds: 1.5) {
            let titlesNow = model.picker?.items.map(\.title) ?? []
            if titlesNow != seenGrep {
                seenGrep = titlesNow
                host = showPicker(window, model)
            } else {
                settle(host, window)
            }
            let hits = resultTitles(in: host)
            return queryField(in: host)?.stringValue == "alpha"
                && hits.contains { $0.contains("notes.md") }
                && !hits.contains { $0.contains("ideas.md") }
        }
        let grepShown = queryField(in: host)?.stringValue ?? ""
        let hits = resultTitles(in: host)
        check(grepped && grepShown == "alpha", "grep query showed \(grepShown) results \(hits)", failures: failures)
        check(hits.contains { $0.contains("notes.md") }, "grep results missing notes \(hits)", failures: failures)
        check(!hits.contains { $0.contains("ideas.md") }, "grep results kept ideas \(hits)", failures: failures)
        if let snippet = fields("quill.picker.snippet", in: host).first(where: { $0.stringValue.localizedCaseInsensitiveContains("alpha") }) {
            let matched = attrChannel(snippet, utf16: 0)
            let restIndex = (snippet.stringValue as NSString).length > 6 ? 6 : 1
            let rest = attrChannel(snippet, utf16: restIndex)
            check(abs(matched - rest) > 0.12, "grep highlight \(matched) vs \(rest) in \(snippet.stringValue)", failures: failures)
        } else {
            failures.append("grep highlight missing snippet \(hits)")
        }
    }

    /// Opens the command palette, types a query, and runs Focus Mode.
}

final class PickerTests: QuillAppTestCase {
    @MainActor
    func testPicker() {
        let failures = Failures()
        Probe.checkPicker(failures: failures)
    }
}
