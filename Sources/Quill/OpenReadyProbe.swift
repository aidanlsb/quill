import AppKit
import Foundation
import QuillWorkspace

/// Prints one ready line once a launch-argument file is on screen and styled.
/// `QUILL_OPEN_PROBE=1` only. With the variable unset this does nothing.
@MainActor
enum OpenReadyProbe {
    private static var armed = false
    private static var finished = false
    private static var expectedText: String?

    static func armIfRequested() {
        guard !armed else { return }
        guard ProcessInfo.processInfo.environment["QUILL_OPEN_PROBE"] == "1" else { return }
        armed = true
        expectedText = loadExpectedText()
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 20_000_000_000)
            guard !finished else { return }
            fail("open ready timed out")
        }
    }

    /// Called after a restyle. Ready requires a window, the fixture text, and a heading font.
    static func consider(_ textView: VimTextView) {
        guard armed, !finished else { return }
        guard let expected = expectedText, !expected.isEmpty else { return }
        guard let window = textView.window, window.isVisible else { return }
        guard textView.string == expected else { return }
        guard headingUsesHeadingFont(textView, text: expected) else { return }
        finished = true
        fputs("quill open ready\n", stdout)
        fflush(stdout)
        proveEdit(textView, original: expected)
    }

    private static func loadExpectedText() -> String? {
        let arguments = Array(CommandLine.arguments.dropFirst())
        let path = LaunchRequest.parse(arguments).last?.path
            ?? EarlyOpenURL.current().flatMap { LaunchRequest.target(from: $0)?.path }
        guard let path else { return nil }
        let url = URL(fileURLWithPath: LaunchRequest.standardized(path))
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? TextCodec.decode(data).text
    }

    /// An ATX heading's text must carry the theme heading font, not the body font.
    private static func headingUsesHeadingFont(_ textView: VimTextView, text: String) -> Bool {
        let ns = text as NSString
        var lineStart = 0
        while lineStart <= ns.length {
            let newline = ns.rangeOfCharacter(
                from: .newlines,
                options: [],
                range: NSRange(location: lineStart, length: ns.length - lineStart)
            )
            let end = newline.location == NSNotFound ? ns.length : newline.location
            let line = ns.substring(with: NSRange(location: lineStart, length: end - lineStart))
            if let level = atxLevel(line), let storage = textView.textStorage, storage.length > 0 {
                let content = lineStart + level + 1
                let index = min(max(0, content), storage.length - 1)
                guard let font = storage.attribute(.font, at: index, effectiveRange: nil) as? NSFont else {
                    return false
                }
                let fonts = textView.theme.headingFonts
                guard !fonts.isEmpty else { return false }
                let expected = fonts[min(level - 1, fonts.count - 1)]
                let body = textView.theme.bodyFont
                let sizeMatchesHeading = abs(font.pointSize - expected.pointSize) < 0.6
                let distinctFromBody = abs(font.pointSize - body.pointSize) > 0.6 || font.fontName != body.fontName
                return sizeMatchesHeading && distinctFromBody
            }
            if newline.location == NSNotFound { break }
            lineStart = end + 1
        }
        return false
    }

    private static func atxLevel(_ line: String) -> Int? {
        var level = 0
        var index = line.startIndex
        while index < line.endIndex, line[index] == "#" {
            level += 1
            index = line.index(after: index)
            if level > 6 { return nil }
        }
        guard level >= 1, index < line.endIndex, line[index] == " " else { return nil }
        return level
    }

    /// Outside the timed interval: one character through `keyDown`, then the engine text.
    private static func proveEdit(_ textView: VimTextView, original: String) {
        guard let enter = keyEvent("i"), let typed = keyEvent("Z") else {
            fail("open edit could not build a key event")
            return
        }
        let before = textView.engine.text
        textView.keyDown(with: enter)
        textView.keyDown(with: typed)
        let after = textView.engine.text
        if before == original, after != before, after.contains("Z"), after.utf16.count == before.utf16.count + 1 {
            fputs("quill open edit ok\n", stdout)
            fflush(stdout)
            exit(0)
        }
        fail("open edit engine text unchanged")
    }

    private static func keyEvent(_ character: Character) -> NSEvent? {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0,
            context: nil,
            characters: String(character),
            charactersIgnoringModifiers: String(character),
            isARepeat: false,
            keyCode: 0
        )
    }

    private static func preview(_ text: String) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: "\\n")
        if flat.count <= 80 { return flat }
        return String(flat.prefix(80)) + "…"
    }

    private static func fail(_ message: String) {
        finished = true
        let windows = NSApplication.shared.windows.map { window in
            "visible=\(window.isVisible) title=\(window.title)"
        }.joined(separator: "; ")
        let views = NSApplication.shared.windows.compactMap { findTextView(in: $0.contentView) }
        let shown = views.map { preview($0.string) }.joined(separator: " | ")
        fputs(
            "FAIL \(message) windows=[\(windows)] views=[\(shown)] expected=\(preview(expectedText ?? ""))\n",
            stdout
        )
        fflush(stdout)
        exit(1)
    }

    private static func findTextView(in view: NSView?) -> VimTextView? {
        guard let view else { return nil }
        if let textView = view as? VimTextView { return textView }
        for subview in view.subviews {
            if let textView = findTextView(in: subview) { return textView }
        }
        return nil
    }
}
