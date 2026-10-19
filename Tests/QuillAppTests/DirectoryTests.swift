import AppKit
import XCTest
@testable import Quill

@MainActor
extension Probe {
    static func checkDirectoryChrome(
        model: AppModel,
        tv: VimTextView,
        scroll: NSScrollView,
        root: URL,
        failures: Failures
    ) {
        let width = scroll.contentView.bounds.width
        let prose = QuillMetrics.columnSpan(width: width, column: tv.columnWidth)
        let column = tv.textContainer?.size.width ?? 0
        let font = tv.textStorage.flatMap { storage -> NSFont? in
            guard storage.length > 0 else { return nil }
            return storage.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        }
        check(font?.isFixedPitch == true, "directory font pitch \(font?.fontName ?? "missing")", failures: failures)
        check(
            font?.familyName == model.theme.directoryFont.familyName,
            "directory font family \(font?.familyName ?? "")",
            failures: failures
        )
        check(
            abs((font?.pointSize ?? 0) - model.theme.directoryFont.pointSize) < 0.25,
            "directory font size \(font?.pointSize ?? 0)",
            failures: failures
        )
        check(
            (font?.pointSize ?? 0) <= model.theme.bodyFont.pointSize - 2,
            "directory font \(font?.pointSize ?? 0) is not compact next to \(model.theme.bodyFont.pointSize)",
            failures: failures
        )
        check(model.theme.directoryFont.isFixedPitch, "directory font mono", failures: failures)
        check(
            abs(tv.textContainerInset.width - QuillMetrics.directoryHorizontalInset) < 0.5,
            "directory inset \(tv.textContainerInset.width)",
            failures: failures
        )
        check(
            tv.textContainerInset.width + 40 < prose.inset,
            "directory inset \(tv.textContainerInset.width) still tracks the prose column \(prose.inset) at width \(width)",
            failures: failures
        )
        check(
            column > prose.column + 40,
            "directory column \(column) is not wider than the prose column \(prose.column)",
            failures: failures
        )
        let headerInset = QuillMetrics.directoryHeaderHeight + QuillMetrics.directoryHeaderGap
        check(
            abs(tv.textContainerInset.height - headerInset) < 0.5,
            "directory header inset \(tv.textContainerInset.height)",
            failures: failures
        )
        check(
            colorDistance(tv.backgroundColor, model.theme.directoryBackgroundColor) < 0.02,
            "directory background view",
            failures: failures
        )
        let dark = QuillTheme.current(scheme: .dark)
        let light = QuillTheme.current(scheme: .light)
        check(
            colorDistance(dark.directoryBackgroundColor, dark.backgroundColor) > 0.04,
            "directory background dark",
            failures: failures
        )
        check(
            colorDistance(light.directoryBackgroundColor, light.backgroundColor) > 0.04,
            "directory background light",
            failures: failures
        )
        let header = DirectoryStyleBuilder.abbreviatedDirectory(
            path: root.path,
            home: FileManager.default.homeDirectoryForCurrentUser.path
        )
        check(tv.directoryHeaderText == header, "directory header \(tv.directoryHeaderText)", failures: failures)
        check(
            DirectoryStyleBuilder.abbreviatedDirectory(path: "/Users/quill/notes", home: "/Users/quill") == "~/notes/",
            "directory header home",
            failures: failures
        )
        check(
            DirectoryStyleBuilder.abbreviatedDirectory(path: "/Users/quill", home: "/Users/quill") == "~/",
            "directory header root",
            failures: failures
        )
        check(
            DirectoryStyleBuilder.abbreviatedDirectory(path: "/Users/quill2/notes", home: "/Users/quill") == "/Users/quill2/notes/",
            "directory header boundary",
            failures: failures
        )
        if let dot = foreground(in: tv, needle: ".hidden") {
            check(colorDistance(dot, model.theme.dimColor) < 0.08, "directory dim \(dot)", failures: failures)
        } else {
            failures.append("directory dim missing")
        }
        if let folder = foreground(in: tv, needle: "sub/") {
            check(
                colorDistance(folder, model.theme.directoryAccentColor) < 0.08,
                "directory accent \(folder)",
                failures: failures
            )
        } else {
            failures.append("directory accent missing")
        }
        let parent = URL(fileURLWithPath: "/notes")
        let original = [
            DirEntry(originalURL: parent.appendingPathComponent("keep.md"), name: "keep.md", isDirectory: false, entryID: 1),
            DirEntry(originalURL: parent.appendingPathComponent("gone.md"), name: "gone.md", isDirectory: false, entryID: 2),
        ]
        let edited = [
            DirectoryBufferLine(text: "keep.md", anchorID: 1, sourcePath: "/notes/keep.md", sourceIsDirectory: false, transfer: .identity),
            DirectoryBufferLine(text: "fresh.md", anchorID: nil, sourcePath: nil, sourceIsDirectory: false, transfer: nil),
        ]
        let preview = DirectoryStyleBuilder.style(
            directoryPath: "/notes",
            homePath: "/Users/quill",
            lines: edited,
            original: original
        )
        let created = preview.lines.contains { $0.mark == .created && $0.name == "fresh.md" }
        let removed = preview.deleted.contains { $0.name == "gone.md" }
        check(created, "new was not marked", failures: failures)
        check(removed, "delete was not marked", failures: failures)

        let proseEngine = Engine(text: "Hello\n")
        let proseHosted = VimTextView.host(engine: proseEngine, frame: scroll.frame)
        let proseScroll = proseHosted.scroll
        let proseView = proseHosted.view
        proseView.isDirectoryBuffer = false
        proseView.columnWidth = model.theme.columnWidth
        proseView.applyTheme(model.theme, focus: false)
        proseScroll.layoutSubtreeIfNeeded()
        proseView.layoutSubtreeIfNeeded()
        proseView.updateInsets()
        let proseWidth = proseScroll.contentView.bounds.width
        let proseSpan = QuillMetrics.columnSpan(width: proseWidth, column: proseView.columnWidth)
        check(
            abs(proseView.textContainerInset.width - proseSpan.inset) < 1,
            "prose inset \(proseView.textContainerInset.width) expected \(proseSpan.inset)",
            failures: failures
        )
    }

    static func checkDirectory(failures: Failures) {
        let fixture: TempDirectory
        do {
            fixture = try TempDirectory()
            try FileManager.default.createDirectory(
                at: fixture.url.appendingPathComponent("sub"),
                withIntermediateDirectories: true
            )
            try fixture.write("notes.md", "hello notes\n")
            try fixture.write(".hidden", "hidden\n")
        } catch {
            failures.append("fixture: \(error.localizedDescription)")
            return
        }
        let root = fixture.url
        defer { withExtendedLifetime(fixture) {} }

        let model = AppModel()
        model.open(url: root)
        check(model.isDirectory, "quill . did not open a directory buffer (\(model.message))", failures: failures)
        check(model.engine.openOnEnter, "directory buffer did not arm Enter", failures: failures)
        check(model.engine.text.contains("notes.md"), "listing missing notes.md: \(model.engine.text)", failures: failures)
        check(model.engine.text.contains("sub/"), "listing missing sub/: \(model.engine.text)", failures: failures)

        let frame = NSRect(x: 0, y: 0, width: 800, height: 480)
        let hosted = VimTextView.host(engine: model.engine, frame: frame)
        let scroll = hosted.scroll
        let tv = hosted.view
        let window = NSWindow(
            contentRect: frame,
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentView = scroll
        scroll.frame = window.contentView?.bounds ?? scroll.frame
        scroll.layoutSubtreeIfNeeded()
        tv.isDirectoryBuffer = true
        tv.directoryURL = root
        tv.directoryEntries = model.directorySnapshot?.entries ?? []
        tv.columnWidth = model.theme.columnWidth
        tv.applyTheme(model.theme, focus: false)
        tv.syncFromEngine()
        tv.layoutSubtreeIfNeeded()
        tv.updateInsets()
        tv.queueRestyle()
        check(tv.string.contains("notes.md"), "text view did not show the directory listing", failures: failures)
        checkDirectoryChrome(model: model, tv: tv, scroll: scroll, root: root, failures: failures)

        var guardSteps = 0
        while !model.engine.lineTextUnderCursor().hasPrefix("notes.md"), guardSteps < 10 {
            let step = tv.press("j") { model.handleEngineResult($0) }
            guardSteps += 1
            if step.beep { break }
        }
        let opened = tv.press("<CR>") { model.handleEngineResult($0) }
        check(opened.actions.contains(.openUnderCursor), "Enter did not open the entry: \(opened.actions)", failures: failures)
        let deadline = Date().addingTimeInterval(3)
        while model.isDirectory, Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        check(model.engine.text.contains("hello notes"), "Enter did not load notes.md: \(model.engine.text)", failures: failures)
        tv.syncFromEngine()
        check(tv.string.contains("hello notes"), "text view stayed on the directory after Enter", failures: failures)

        let parent = tv.press("-") { model.handleEngineResult($0) }
        check(parent.actions == [.openParentDirectory], "minus actions \(parent.actions)", failures: failures)
        check(model.isDirectory, "minus did not return to the directory (\(model.message))", failures: failures)
        check(model.engine.text.contains("notes.md"), "parent listing lost notes.md", failures: failures)

        guardSteps = 0
        while !model.engine.lineTextUnderCursor().hasPrefix("notes.md"), guardSteps < 10 {
            _ = tv.press("j")
            guardSteps += 1
        }
        _ = tv.press("0c$renamed.md<Esc>")
        check(
            model.engine.lineTextUnderCursor().hasPrefix("renamed.md"),
            "rename left \(model.engine.lineTextUnderCursor())",
            failures: failures
        )
        let pending = DirectoryStyleBuilder.style(
            directoryPath: model.fileURL?.path ?? "",
            homePath: FileManager.default.homeDirectoryForCurrentUser.path,
            lines: DirectoryStyleBuilder.lines(from: model.engine.buffer),
            original: model.directorySnapshot?.entries ?? []
        )
        let marked = pending.lines.contains { line in
            if case .renamed(let from) = line.mark {
                return line.name == "renamed.md" && from == "notes.md"
            }
            return false
        }
        check(marked, "rename was not marked \(pending.lines.map { "\($0.name) \($0.mark)" })", failures: failures)
        model.save()
        check(model.showConfirm, " :w did not ask to apply filesystem changes (\(model.message))", failures: failures)
        let renamed = model.pendingOps.contains { op in
            if case .rename = op { return true }
            return false
        }
        check(renamed, "save planned \(model.pendingOps.map(\.summary)) instead of a rename", failures: failures)
    }

}

final class DirectoryTests: QuillAppTestCase {
    @MainActor
    func testDirectory() {
        let failures = Failures()
        Probe.checkDirectory(failures: failures)
    }
}
