import AppKit

/// TextKit 2's stock content storage builds an `NSTextParagraph` for every
/// line, then shifts each one when a character is inserted at the top of the
/// note. A 10k-line insert spent the keystroke there. This storage keeps line
/// starts as integers and builds a paragraph only when layout asks for it.
final class ViewportContentStorage: NSTextContentStorage {
    private var lineStarts: [Int] = [0]
    private var indexedLength = 0
    /// True while the superclass still owns the element array. Turned off
    /// after the layout manager has adopted this storage, so a long note does
    /// not shift one paragraph object per line on each insert.
    private var stockEditing = true
    /// Once a long note skips the stock element array, stay there. Calling
    /// super later would walk that stale array and trap.
    private var lineIndexOnly = false
    private var loggedFastEdit = false
    private var loggedDocLen = false
    /// Below this, smoke and normal notes use the stock element update.
    /// The 10k-line perf note is far above it.
    private static let lineIndexUTF16Threshold = 20_000

    /// The text-storage setter runs `processEditing`. Keep the superclass's
    /// element array valid until `useLineIndex()` — skipping that on an empty
    /// storage crashes inside the setter.
    func prime(_ storage: NSTextStorage) {
        stockEditing = true
        textStorage = storage
        rebuildLineStarts()
    }

    func useLineIndex() {
        stockEditing = false
        rebuildLineStarts()
    }

    override func enumerateTextElements(
        from textLocation: NSTextLocation?,
        options: NSTextContentManager.EnumerationOptions = [],
        using block: (NSTextElement) -> Bool
    ) -> NSTextLocation? {
        if !prefersLineIndex(length: textStorage?.length ?? 0) {
            return super.enumerateTextElements(from: textLocation, options: options, using: block)
        }
        ensureIndex()
        let length = textStorage?.length ?? 0
        if length == 0 || lineStarts.isEmpty {
            guard let paragraph = emptyParagraph() else { return nil }
            _ = block(paragraph)
            return documentRange.endLocation
        }
        let reverse = options.contains(.reverse)
        var line: Int
        if reverse {
            if textLocation == nil {
                line = lineStarts.count - 1
            } else {
                let origin = locationOffset(textLocation)
                if origin >= length {
                    line = lineStarts.count - 1
                } else {
                    line = lineIndex(containing: max(0, origin)) - 1
                }
            }
        } else {
            let origin = locationOffset(textLocation)
            line = lineIndex(containing: min(max(0, origin), length - 1))
        }
        var edge: NSTextLocation?
        while lineStarts.indices.contains(line) {
            guard let paragraph = paragraph(at: line, length: length) else { break }
            edge = reverse ? paragraph.elementRange?.location : paragraph.elementRange?.endLocation
            if block(paragraph) == false { break }
            line += reverse ? -1 : 1
        }
        return edge
    }

    override func processEditing(
        for textStorage: NSTextStorage,
        edited editMask: NSTextStorageEditActions,
        range newCharRange: NSRange,
        changeInLength delta: Int,
        invalidatedRange invalidatedCharRange: NSRange
    ) {
        if !prefersLineIndex(length: textStorage.length) {
            super.processEditing(
                for: textStorage,
                edited: editMask,
                range: newCharRange,
                changeInLength: delta,
                invalidatedRange: invalidatedCharRange
            )
            rebuildLineStarts()
            return
        }
        lineIndexOnly = true
        // The superclass shifts every paragraph object past the edit. Record
        // the line-start delta. Invalidating a range the stock element array
        // does not cover traps (status 133), so only invalidate when
        // `documentRange` already matches the string.
        let length = textStorage.length
        let previous = length - delta
        if indexedLength != previous || delta < 0 || rangeContainsNewline(newCharRange, storage: textStorage) {
            rebuildLineStarts()
        } else if delta > 0 {
            let location = newCharRange.location
            for index in lineStarts.indices where lineStarts[index] > location {
                lineStarts[index] += delta
            }
            indexedLength += delta
        }
        if !loggedFastEdit {
            loggedFastEdit = true
            QuillTrace.write("quill boot fast-enter lines=\(lineStarts.count) len=\(length)\n")
        }
        let doc = documentRange
        let docLen = offset(from: doc.location, to: doc.endLocation)
        if loggedFastEdit, !loggedDocLen {
            loggedDocLen = true
            QuillTrace.write("quill boot fast-doc \(docLen)\n")
        }
        guard docLen == length, !invalidating else {
            _ = editMask
            _ = invalidatedCharRange
            return
        }
        guard let layout = textLayoutManagers.first ?? primaryTextLayoutManager else { return }
        let startOffset: Int
        if length == 0 || lineStarts.isEmpty {
            startOffset = 0
        } else {
            let probe = min(max(0, newCharRange.location), length - 1)
            startOffset = lineStarts[lineIndex(containing: probe)]
        }
        let endOffset: Int
        if delta == 0 {
            endOffset = min(length, max(startOffset, NSMaxRange(newCharRange)))
        } else {
            let probe = min(max(0, startOffset), max(0, length - 1))
            let line = lineStarts.isEmpty ? 0 : lineIndex(containing: probe)
            if line + 1 < lineStarts.count {
                endOffset = lineStarts[line + 1]
            } else {
                endOffset = length
            }
        }
        guard let start = self.location(doc.location, offsetBy: startOffset),
              let textRange = NSTextRange(location: start, end: location(at: endOffset)) else { return }
        invalidating = true
        layout.invalidateLayout(for: textRange)
        invalidating = false
        _ = editMask
        _ = invalidatedCharRange
    }

    private func prefersLineIndex(length: Int) -> Bool {
        if stockEditing || textLayoutManagers.isEmpty || length == 0 { return false }
        if lineIndexOnly { return true }
        return length >= Self.lineIndexUTF16Threshold
    }

    private var invalidating = false

    private func ensureIndex() {
        let length = textStorage?.length ?? 0
        if indexedLength != length {
            rebuildLineStarts()
        }
    }

    private func rebuildLineStarts() {
        guard let storage = textStorage else {
            lineStarts = [0]
            indexedLength = 0
            return
        }
        let ns = storage.string as NSString
        let length = ns.length
        var starts = [0]
        var index = 0
        while index < length {
            if ns.character(at: index) == 10 {
                let next = index + 1
                if next < length { starts.append(next) }
            }
            index += 1
        }
        lineStarts = starts
        indexedLength = length
    }

    private func rangeContainsNewline(_ range: NSRange, storage: NSTextStorage) -> Bool {
        guard range.length > 0, NSMaxRange(range) <= storage.length else { return false }
        let ns = storage.string as NSString
        let found = ns.rangeOfCharacter(from: .newlines, options: [], range: range)
        return found.location != NSNotFound
    }

    /// `location(_:offsetBy:)` is nil past the document. The end location is not optional.
    private func location(at offset: Int) -> any NSTextLocation {
        self.location(documentRange.location, offsetBy: offset) ?? documentRange.endLocation
    }

    private func locationOffset(_ location: NSTextLocation?) -> Int {
        guard let location else { return 0 }
        let value = offset(from: documentRange.location, to: location)
        return value == NSNotFound ? 0 : value
    }

    private func lineIndex(containing offset: Int) -> Int {
        var low = 0
        var high = lineStarts.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if lineStarts[mid] <= offset {
                low = mid
            } else {
                high = mid - 1
            }
        }
        return low
    }

    private func emptyParagraph() -> NSTextParagraph? {
        let paragraph = NSTextParagraph(attributedString: NSAttributedString())
        paragraph.textContentManager = self
        paragraph.elementRange = documentRange
        return paragraph
    }

    private func paragraph(at line: Int, length: Int) -> NSTextParagraph? {
        guard let storage = textStorage, lineStarts.indices.contains(line) else { return nil }
        let start = lineStarts[line]
        let end = line + 1 < lineStarts.count ? lineStarts[line + 1] : length
        guard start <= end, end <= length,
              let startLocation = self.location(documentRange.location, offsetBy: start),
              let elementRange = NSTextRange(location: startLocation, end: location(at: end)) else { return nil }
        let text = storage.attributedSubstring(from: NSRange(location: start, length: end - start))
        let paragraph = NSTextParagraph(attributedString: text)
        paragraph.textContentManager = self
        paragraph.elementRange = elementRange
        return paragraph
    }
}
