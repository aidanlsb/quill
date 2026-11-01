import AppKit
import QuillMarkdown
import QuillSearch
import QuillVim

extension AppModel {
    func addComment() {
        guard !document.isDirectory else { return }
        if engine.mode.isVisual {
            wrapCommentSelection()
            return
        }
        let at = engine.cursor
        let insert = MarkdownComments.empty
        apply(engine.applyHostEdit(replacing: at..<at, with: insert, insertAt: at + MarkdownComments.emptyBodyUTF16))
    }

    func resolveComment() {
        guard !document.isDirectory else { return }
        guard let comment = MarkdownComments.at(cursor: engine.cursor, in: engine.text) else {
            message = "No comment"
            NSSound.beep()
            return
        }
        let replacement = comment.resolvedText(in: engine.text)
        apply(engine.applyHostEdit(replacing: comment.range, with: replacement))
        engine.rememberRepeatableCommand("edit.commentResolve")
    }

    func jumpComment(forward: Bool) {
        guard !document.isDirectory else { return }
        guard let target = MarkdownComments.jump(from: engine.cursor, forward: forward, in: engine.text) else {
            message = "No comment"
            NSSound.beep()
            return
        }
        apply(engine.moveCursor(to: target.range.lowerBound))
    }

    func presentCommentsPicker() {
        guard !document.isDirectory else { return }
        let restore: (Mode, Int)?
        if case .picker(let opened) = prompt, opened.kind == .comments {
            restore = opened.restore
        } else {
            restore = (engine.mode, engine.cursor)
        }
        let token = beginPromptWork()
        let picker = PickerEngine(source: commentPickerItems())
        prompt = .picker(PickerSession(id: token, kind: .comments, picker: picker, restore: restore))
        message = ":Comments"
    }

    func confirmCommentPicker(_ item: PickerItem) {
        clearPrompt()
        guard let offset = Int(item.payload) else { return }
        engine.mode = .normal
        apply(engine.moveCursor(to: offset))
    }

    func dismissCommentsPicker() {
        let restoreState: (Mode, Int)?
        if case .picker(let opened) = prompt, opened.kind == .comments {
            restoreState = opened.restore
        } else {
            restoreState = nil
        }
        clearPrompt()
        guard let restoreState else { return }
        engine.mode = restoreState.0
        if engine.cursor != restoreState.1 {
            engine.moveCursor(to: restoreState.1)
        }
        status = engine.mode.displayName
    }

    private func wrapCommentSelection() {
        guard var range = engine.visualSelection, !range.isEmpty else {
            message = "No selection"
            NSSound.beep()
            return
        }
        var selected = engine.buffer.substring(range)
        if selected.hasSuffix("\n") {
            selected.removeLast()
            range = range.lowerBound..<(range.upperBound - 1)
        }
        guard MarkdownComments.isSingleLine(selected), !selected.isEmpty else {
            message = "Comment must stay in one paragraph"
            NSSound.beep()
            return
        }
        let wrapped = MarkdownComments.wrap(selected)
        let insertAt = range.lowerBound + MarkdownComments.wrapInsertUTF16(selectedUTF16: selected.utf16.count)
        apply(engine.applyHostEdit(replacing: range, with: wrapped, insertAt: insertAt))
    }

    private func commentPickerItems() -> [PickerItem] {
        let text = engine.text
        return MarkdownComments.find(in: text).map { comment in
            let line = engine.buffer.lineIndex(containing: comment.range.lowerBound) + 1
            let body = comment.bodyText(in: text)
            let title: String
            if let highlight = comment.highlightText(in: text), !highlight.isEmpty {
                let note = body.isEmpty ? "comment" : body
                title = "\(highlight) → \(note)"
            } else if body.isEmpty {
                title = "(empty)"
            } else {
                title = body
            }
            return PickerItem(
                title: title,
                subtitle: "L\(line)",
                payload: String(comment.range.lowerBound),
                preview: engine.buffer.substring(engine.buffer.lineContentRange(at: line - 1))
            )
        }
    }
}
