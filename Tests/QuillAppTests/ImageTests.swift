import AppKit
import QuillMarkdown
import QuillVim
import XCTest
@testable import Quill

@MainActor
extension Probe {
    /// A local image and a missing one render under their source lines.
    /// The bytes of the note do not change, and `j` / `k` cross the preview.
    static func checkImages(failures: Failures) {
        check(QuillConfig.default.images, "images default", failures: failures)
        if let decoded = try? QuillConfig.decode(Data("images = false\n".utf8)) {
            check(!decoded.images, "images config off", failures: failures)
        } else {
            failures.append("images config off")
        }
        if let decoded = try? QuillConfig.decode(Data("leader = \" \"\n".utf8)) {
            check(decoded.images, "images config default \(decoded.images)", failures: failures)
        } else {
            failures.append("images config default")
        }
        check(
            (try? QuillConfig.decode(Data("images = \"yes\"\n".utf8))) == nil,
            "images config name",
            failures: failures
        )
        let model = AppModel()
        let imagesWereOn = model.showImages
        check(model.runCommand("view.toggleImages"), "images command", failures: failures)
        check(model.showImages != imagesWereOn, "images command toggle", failures: failures)

        let original = """
        before

        ![local](pic.png)

        after

        ![gone](missing.png)

        tail
        """
        let root: TempDirectory
        do {
            root = try TempDirectory()
            guard let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAACAAAAAQCAYAAAB3AH1ZAAAAJElEQVR4nGOQi1rwfyAxw6gDRh0w6oBRB4w6YNQBow4YaAcAAIupLj0fRW3jAAAAAElFTkSuQmCC") else {
                failures.append("images png")
                return
            }
            try png.write(to: root.url.appendingPathComponent("pic.png"))
        } catch {
            failures.append("images fixture \(error.localizedDescription)")
            return
        }
        let note = root.url.appendingPathComponent("note.md")
        let size = NSSize(width: 1000, height: 900)
        let harness = EditorHarness(text: original, size: size)
        let plain = EditorHarness(text: original, size: size)
        defer {
            harness.close()
            plain.close()
            withExtendedLifetime(root) {}
        }
        let tv = harness.view
        let engine = harness.engine
        tv.setImageContext(enabled: true, filePath: note.path)
        tv.reload()
        tv.layoutSubtreeIfNeeded()
        tv.flushImagePreviews()
        let ready = waitUntil(seconds: 2) {
            tv.layoutSubtreeIfNeeded()
            let local = tv.imagePreviews.blockViews.first { $0.destination == "pic.png" }
            return local?.showsImage == true && local?.frame.height ?? 0 > 24
        }
        let local = tv.imagePreviews.blockViews.first { $0.destination == "pic.png" }
        let missing = tv.imagePreviews.blockViews.first { $0.destination == "missing.png" }
        check(ready, "image local bitmap \(local?.frame ?? .zero)", failures: failures)
        check(missing != nil, "image missing block", failures: failures)
        check(missing?.showsImage == false, "image missing drew a bitmap", failures: failures)
        check(tv.string == original, "image storage changed", failures: failures)
        check(!tv.string.unicodeScalars.contains { $0.value == 0xFFFC }, "image inserted an attachment", failures: failures)

        let column = tv.textContainer?.size.width ?? 0
        if let local {
            check(local.frame.width > 40 && local.frame.width <= column + 1, "image width \(local.frame.width) column \(column)", failures: failures)
            check(local.frame.height <= CGFloat(ImageFit.maxHeight) + 1, "image height \(local.frame.height)", failures: failures)
            let aspect = local.frame.height / max(local.frame.width, 1)
            check(abs(aspect - 0.5) < 0.15, "image aspect \(aspect)", failures: failures)
        }
        if let missing {
            check(missing.frame.height > 20 && missing.frame.height < 120, "image placeholder \(missing.frame.height)", failures: failures)
            check(missing.frame.width > 40, "image placeholder width \(missing.frame.width)", failures: failures)
        }
        let bang = (original as NSString).range(of: "![local]").location
        if let local, let glyph = tv.lineGlyphBounds(atUTF16: bang) {
            check(local.frame.minY >= glyph.maxY - 2, "image overlapped the source \(local.frame) \(glyph)", failures: failures)
            let gap = local.frame.minY - glyph.maxY
            fputs("quill smoke image gap=\(gap) height=\(local.frame.height) column=\(column)\n", stderr)
        } else {
            failures.append("image source glyph")
        }
        if let local, let missing, let after = tv.lineGlyphBounds(atUTF16: (original as NSString).range(of: "after").location) {
            check(after.minY >= local.frame.maxY - 2, "image overlapped the next line \(local.frame) \(after)", failures: failures)
            check(missing.frame.minY > local.frame.maxY, "image order \(local.frame) \(missing.frame)", failures: failures)
        }

        let localLine = engine.buffer.lineIndex(containing: bang)
        engine.moveCursor(to: engine.buffer.lineContentRange(at: localLine).lowerBound)
        _ = tv.press("j")
        let below = engine.buffer.lineIndex(containing: engine.cursor)
        check(below == localLine + 1, "image j stayed on \(below) from \(localLine)", failures: failures)
        if let local {
            let caret = tv.renderedCaretRect()
            check(!local.frame.insetBy(dx: 0, dy: -1).intersects(caret), "image j landed inside \(caret) \(local.frame)", failures: failures)
            check(caret.minY >= local.frame.maxY - 2, "image j caret \(caret) block \(local.frame)", failures: failures)
        }
        _ = tv.press("k")
        let back = engine.buffer.lineIndex(containing: engine.cursor)
        check(back == localLine, "image k landed on \(back)", failures: failures)
        if let local {
            let caret = tv.renderedCaretRect()
            check(caret.maxY <= local.frame.minY + 2, "image k caret \(caret) block \(local.frame)", failures: failures)
        }
        check(tv.string == original, "image motion edited the text", failures: failures)

        engine.moveCursor(to: 0)
        _ = tv.press("iZ<Esc>u")
        check(tv.string == original, "image undo \(tv.string.prefix(12))", failures: failures)

        plain.view.setImageContext(enabled: false, filePath: note.path)
        plain.view.reload()
        plain.view.layoutSubtreeIfNeeded()
        let on = strokes(tv)
        let off = strokes(plain.view)
        fputs(String(format: "quill smoke image keystroke on=%.3f off=%.3f\n", on, off), stderr)
        check(on < max(off * 2.5, off + 8), "image keystroke \(on) plain \(off)", failures: failures)
        fflush(stderr)
    }

    /// Same insert path the smoke timed: `applyResult` of a character, images on versus off.
    private static func strokes(_ view: VimTextView) -> Double {
        view.engine.moveCursor(to: 0)
        view.engine.mode = .insert
        for _ in 0..<5 {
            view.applyResult(view.engine.handle(KeyEvent(.character("q"))))
        }
        let began = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<20 {
            view.applyResult(view.engine.handle(KeyEvent(.character("q"))))
        }
        return Double(DispatchTime.now().uptimeNanoseconds &- began) / 1_000_000 / 20
    }
}

final class ImageTests: QuillAppTestCase {
    @MainActor
    func testInlinePreviews() {
        let failures = Failures()
        Probe.checkImages(failures: failures)
    }
}
