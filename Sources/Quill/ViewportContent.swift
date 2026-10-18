import AppKit

/// TextKit 2's stock content storage builds an `NSTextParagraph` for every
/// line, then shifts each one when a character is inserted at the top of the
/// note. A 10k-line insert spent the keystroke there. This storage keeps line
/// starts as integers and builds a paragraph only when layout asks for it.
final class ViewportContentStorage: NSTextContentStorage {
    private var lineStarts: [Int] = [0]
    private var indexedLength = 0

    func adopt(storage: NSTextStorage?, layoutManager: NSTextLayoutManager?) {
        var backing = storage
        if let layoutManager, let previous = layoutManager.textContentManager as? NSTextContentStorage, previous !== self {
            backing = previous.textStorage ?? backing
            // One text storage can feed only one content storage. Drop the stock
            // one before this instance takes the same backing store.
            previous.textStorage = nil
            previous.removeTextLayoutManager(layoutManager)
        }
        textStorage = backing
        if let layoutManager, !textLayoutManagers.contains(where: { $0 === layoutManager }) {
            addTextLayoutManager(layoutManager)
        }
        backing?.textStorageObserver = self
        rebuildLineStarts()
    }

    override func enumerateTextElements(
        from textLocation: NSTextLocation?,
        options: NSTextContentManager.EnumerationOptions = [],
        using block: (NSTextElement) -> Bool
    ) -> NSTextLocation? {
        guard let storage = textStorage else {
            return super.enumerateTextElements(from: textLocation, options: options, using: block)
        }
        ensureIndex()
        let length = storage.length
        if length == 0 || lineStarts.isEmpty {
            let paragraph = NSTextParagraph(attributedString: NSAttributedString())
            paragraph.textContentManager = self
            paragraph.elementRange = documentRange
            _ = block(paragraph)
            return documentRange.endLocation
        }
        let reverse = options.contains(.reverse)
        let origin = locationOffset(textLocation)
        var line = lineIndex(containing: min(max(0, origin), max(0, length - 1)))
        if reverse { line -= 1 }
        var edge: NSTextLocation?
        while lineStarts.indices.contains(line) {
            guard let paragraph = paragraph(at: line, length: length) else { break }
            edge = paragraph.elementRange?.endLocation
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
        // The superclass shifts every paragraph object past the edit. Record
        // the line-start delta and let the next layout pass rebuild the one
        // paragraph it displays.
        if delta < 0 || rangeContainsNewline(newCharRange, storage: textStorage) {
            rebuildLineStarts()
        } else if delta > 0 {
            let location = newCharRange.location
            for index in lineStarts.indices where lineStarts[index] > location {
                lineStarts[index] += delta
            }
            indexedLength += delta
        }
        guard let layout = textLayoutManagers.first ?? primaryTextLayoutManager else { return }
        let end = min(textStorage.length, newCharRange.location + newCharRange.length)
        guard let start = self.location(documentRange.location, offsetBy: newCharRange.location),
              let finish = self.location(documentRange.location, offsetBy: end) ?? documentRange.endLocation,
              let textRange = NSTextRange(location: start, end: finish) else { return }
        layout.invalidateLayout(for: textRange)
        _ = editMask
        _ = invalidatedCharRange
    }

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
        let slice = ns.substring(with: range)
        return slice.contains("\n") || slice.contains("\r")
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

    private func paragraph(at line: Int, length: Int) -> NSTextParagraph? {
        guard let storage = textStorage, lineStarts.indices.contains(line) else { return nil }
        let start = lineStarts[line]
        let end = line + 1 < lineStarts.count ? lineStarts[line + 1] : length
        guard start <= end, end <= length,
              let startLocation = self.location(documentRange.location, offsetBy: start),
              let endLocation = self.location(documentRange.location, offsetBy: end) ?? documentRange.endLocation,
              let elementRange = NSTextRange(location: startLocation, end: endLocation) else { return nil }
        let text = storage.attributedSubstring(from: NSRange(location: start, length: end - start))
        let paragraph = NSTextParagraph(attributedString: text)
        paragraph.textContentManager = self
        paragraph.elementRange = elementRange
        return paragraph
    }
}
