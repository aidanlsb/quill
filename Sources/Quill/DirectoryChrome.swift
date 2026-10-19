import AppKit
import QuillFS
import QuillVim

/// One buffer line paired with the directory anchor that save will see.
/// The anchor scan matches `AppModel.listingLines`, so marks describe that diff.
struct DirectoryBufferLine: Equatable, Sendable {
    var text: String
    var anchorID: UInt64?
    var sourcePath: String?
    var sourceIsDirectory: Bool
    var transfer: DirectoryTransfer?
}

enum DirectoryMark: Equatable, Sendable {
    case unchanged
    case created
    case renamed(from: String)
    case moved
    case copied
}

struct DirectoryLineStyle: Equatable, Sendable {
    var text: String
    var name: String
    var isDirectory: Bool
    var isDotfile: Bool
    var mark: DirectoryMark
    /// SF Symbol. Empty lines have none, so the gutter stays clear.
    var symbolName: String?
}

struct DirectoryGhost: Equatable, Sendable {
    var name: String
    var isDirectory: Bool
    var isDotfile: Bool
    var symbolName: String
}

struct DirectoryStyle: Equatable, Sendable {
    var header: String
    var lines: [DirectoryLineStyle]
    var deleted: [DirectoryGhost]
}

enum DirectoryStyleBuilder {
    /// `home` itself is `~/`. A descendant is `~/rest/`. Other paths keep their spelling and gain a trailing slash.
    static func abbreviatedDirectory(path: String, home: String) -> String {
        if path.isEmpty { return "" }
        let directory = standardize(path)
        let base = standardize(home)
        let shown: String
        if directory == base {
            shown = "~"
        } else if base != "/", directory.hasPrefix(base + "/") {
            shown = "~" + directory.dropFirst(base.count)
        } else {
            shown = directory
        }
        if shown == "/" { return "/" }
        return shown.hasSuffix("/") ? shown : shown + "/"
    }

    static func style(
        directoryPath: String,
        homePath: String,
        lines: [DirectoryBufferLine],
        original: [DirEntry]
    ) -> DirectoryStyle {
        var used: Set<UInt64> = []
        var styled: [DirectoryLineStyle] = []
        styled.reserveCapacity(lines.count)
        for line in lines {
            if let id = line.anchorID { used.insert(id) }
            styled.append(styleLine(line))
        }
        var deleted: [DirectoryGhost] = []
        for entry in original {
            guard let id = entry.entryID, !used.contains(id) else { continue }
            deleted.append(DirectoryGhost(
                name: entry.displayName,
                isDirectory: entry.isDirectory,
                isDotfile: entry.name.hasPrefix("."),
                symbolName: symbolName(isDirectory: entry.isDirectory)
            ))
        }
        deleted.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return DirectoryStyle(
            header: abbreviatedDirectory(path: directoryPath, home: homePath),
            lines: styled,
            deleted: deleted
        )
    }

    @MainActor
    static func lines(from buffer: TextBuffer) -> [DirectoryBufferLine] {
        var lines: [DirectoryBufferLine] = []
        var offset = 0
        let parts = buffer.text.split(separator: "\n", omittingEmptySubsequences: false)
        for raw in parts {
            let line = String(raw)
            let end = offset + line.utf16.count
            let anchor = buffer.anchors(in: offset..<(end + 1)).first { anchor in
                if case .directoryEntry = anchor.kind { return true }
                return false
            }
            if let anchor, case .directoryEntry(let path, let isDir, let transfer) = anchor.kind {
                lines.append(DirectoryBufferLine(
                    text: line,
                    anchorID: anchor.id.raw,
                    sourcePath: path,
                    sourceIsDirectory: isDir,
                    transfer: transfer
                ))
            } else {
                lines.append(DirectoryBufferLine(
                    text: line,
                    anchorID: nil,
                    sourcePath: nil,
                    sourceIsDirectory: false,
                    transfer: nil
                ))
            }
            offset = end + 1
        }
        return lines
    }

    static func label(for mark: DirectoryMark) -> String? {
        switch mark {
        case .unchanged: return nil
        case .created: return "new"
        case .renamed: return "rename"
        case .moved: return "move"
        case .copied: return "copy"
        }
    }

    static func symbolName(isDirectory: Bool) -> String {
        isDirectory ? "folder" : "doc"
    }

    private static func styleLine(_ line: DirectoryBufferLine) -> DirectoryLineStyle {
        let parsed = ParsedDirLine(line.text)
        if parsed.name.isEmpty {
            return DirectoryLineStyle(
                text: line.text,
                name: "",
                isDirectory: false,
                isDotfile: false,
                mark: .unchanged,
                symbolName: nil
            )
        }
        let display = parsed.isDirectory ? parsed.name + "/" : parsed.name
        let mark: DirectoryMark
        if let transfer = line.transfer {
            switch transfer {
            case .move:
                mark = .moved
            case .copy:
                mark = .copied
            case .identity:
                let original = displayName(path: line.sourcePath ?? "", isDirectory: line.sourceIsDirectory)
                mark = original == display ? .unchanged : .renamed(from: original)
            }
        } else {
            mark = .created
        }
        return DirectoryLineStyle(
            text: line.text,
            name: parsed.name,
            isDirectory: parsed.isDirectory,
            isDotfile: parsed.name.hasPrefix("."),
            mark: mark,
            symbolName: symbolName(isDirectory: parsed.isDirectory)
        )
    }

    private static func displayName(path: String, isDirectory: Bool) -> String {
        let name = (path as NSString).lastPathComponent
        if name.isEmpty { return "" }
        return isDirectory ? name + "/" : name
    }

    private static func standardize(_ raw: String) -> String {
        let path = URL(fileURLWithPath: raw).standardizedFileURL.path
        if path.count > 1, path.hasSuffix("/") {
            return String(path.dropLast())
        }
        return path
    }
}

@MainActor
enum DirectoryStyler {
    static func apply(_ storage: NSTextStorage, theme: QuillTheme, style: DirectoryStyle) {
        let ns = storage.string as NSString
        let full = NSRange(location: 0, length: ns.length)
        storage.beginEditing()
        if full.length > 0 {
            storage.setAttributes(attributes(theme), range: full)
        }
        var lineIndex = 0
        var start = 0
        while start <= ns.length {
            let newline = ns.rangeOfCharacter(
                from: .newlines,
                options: [],
                range: NSRange(location: start, length: ns.length - start)
            )
            let end = newline.location == NSNotFound ? ns.length : newline.location
            let range = NSRange(location: start, length: max(0, end - start))
            if lineIndex < style.lines.count, range.length > 0 {
                let line = style.lines[lineIndex]
                storage.addAttribute(.font, value: theme.directoryFont, range: range)
                storage.addAttribute(.foregroundColor, value: foreground(line, theme: theme), range: range)
            }
            lineIndex += 1
            if newline.location == NSNotFound { break }
            start = end + max(newline.length, 1)
        }
        storage.endEditing()
    }

    static func foreground(_ line: DirectoryLineStyle, theme: QuillTheme) -> NSColor {
        if line.isDotfile { return theme.dimColor }
        if line.isDirectory { return theme.directoryAccentColor }
        return theme.textColor
    }

    static func markColor(_ mark: DirectoryMark, theme: QuillTheme) -> NSColor {
        switch mark {
        case .unchanged: return theme.dimColor
        case .created: return theme.directoryCreatedColor
        case .renamed, .moved, .copied: return theme.directoryRenamedColor
        }
    }

    private static func attributes(_ theme: QuillTheme) -> [NSAttributedString.Key: Any] {
        let para = NSMutableParagraphStyle()
        para.alignment = .left
        para.lineBreakMode = .byTruncatingTail
        para.lineHeightMultiple = QuillMetrics.directoryLineHeight
        para.paragraphSpacing = 0
        return [
            .font: theme.directoryFont,
            .foregroundColor: theme.textColor,
            .paragraphStyle: para,
        ]
    }
}

@MainActor
extension VimTextView {
    func currentDirectoryStyle() -> DirectoryStyle {
        DirectoryStyleBuilder.style(
            directoryPath: directoryURL?.path ?? "",
            homePath: FileManager.default.homeDirectoryForCurrentUser.path,
            lines: DirectoryStyleBuilder.lines(from: engine.buffer),
            original: directoryEntries
        )
    }

    @discardableResult
    func restyleDirectoryBuffer() -> CGFloat {
        let style = currentDirectoryStyle()
        directoryHeaderText = style.header
        if let storage = textStorage {
            DirectoryStyler.apply(storage, theme: theme, style: style)
        }
        return QuillMetrics.directoryRowHeight(for: theme.directoryFont) * CGFloat(style.deleted.count)
    }

    func drawDirectoryBackground(in rect: NSRect) {
        backgroundColor.setFill()
        rect.fill()
        guard engine != nil, engine.buffer.lineCount > 0 else { return }
        layoutAdapter.ensureFullLayout()
        let index = clampUTF16(selectedRange().location)
        guard let row = directoryLineRect(at: index) else { return }
        theme.directoryHighlightColor.setFill()
        row.fill()
    }

    func drawDirectoryDecorations() {
        guard engine != nil else { return }
        layoutAdapter.ensureFullLayout()
        let style = currentDirectoryStyle()
        drawDirectoryHeader(style.header)
        var lastMaxY = textContainerOrigin.y
        for (index, line) in style.lines.enumerated() where index < engine.buffer.lineCount {
            let utf16 = engine.buffer.line(index).start
            guard let box = directoryLineBox(at: utf16) else { continue }
            lastMaxY = max(lastMaxY, box.row.maxY)
            guard let symbol = line.symbolName else { continue }
            let color = DirectoryStyler.foreground(line, theme: theme)
            drawDirectorySymbol(symbol, color: color, row: box.row)
            if let label = DirectoryStyleBuilder.label(for: line.mark) {
                drawDirectoryMarkBar(DirectoryStyler.markColor(line.mark, theme: theme), row: box.row)
                drawDirectoryLabel(label, color: DirectoryStyler.markColor(line.mark, theme: theme), after: box.text, row: box.row)
            }
        }
        let rowHeight = QuillMetrics.directoryRowHeight(for: theme.directoryFont)
        for (index, ghost) in style.deleted.enumerated() {
            let row = NSRect(x: 0, y: lastMaxY + CGFloat(index) * rowHeight, width: bounds.width, height: rowHeight)
            let color = theme.dimColor
            drawDirectorySymbol(ghost.symbolName, color: color, row: row)
            drawDirectoryMarkBar(theme.directoryDeletedColor, row: row)
            let struck: [NSAttributedString.Key: Any] = [
                .font: theme.directoryFont,
                .foregroundColor: color,
                .strikethroughStyle: NSUnderlineStyle.single.rawValue,
                .strikethroughColor: color,
            ]
            let nameWidth = (ghost.name as NSString).size(withAttributes: struck).width
            let name = NSRect(
                x: textContainerInset.width,
                y: row.minY,
                width: max(nameWidth, 1),
                height: row.height
            )
            (ghost.name as NSString).draw(with: name, options: [.usesLineFragmentOrigin], attributes: struck)
            drawDirectoryLabel("delete", color: theme.directoryDeletedColor, after: name, row: row)
        }
    }

    private func drawDirectoryHeader(_ header: String) {
        guard !header.isEmpty else { return }
        let rect = NSRect(
            x: QuillMetrics.directoryIconLeading,
            y: 4,
            width: max(1, bounds.width - QuillMetrics.directoryIconLeading - 16),
            height: QuillMetrics.directoryHeaderHeight
        )
        let attrs: [NSAttributedString.Key: Any] = [
            .font: theme.directoryHeaderFont,
            .foregroundColor: theme.dimColor,
        ]
        (header as NSString).draw(
            with: rect,
            options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
            attributes: attrs
        )
    }

    private func drawDirectorySymbol(_ name: String, color: NSColor, row: NSRect) {
        let size = QuillMetrics.directoryIconSize
        let rect = NSRect(
            x: QuillMetrics.directoryIconLeading,
            y: row.midY - size / 2,
            width: size,
            height: size
        )
        let base = NSImage.SymbolConfiguration(pointSize: size - 1, weight: .regular)
        let tinted = base.applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        if let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(tinted) {
            image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 0.92, respectFlipped: true, hints: nil)
            return
        }
        let glyph = name == "folder" ? "/" : "·"
        (glyph as NSString).draw(with: rect, options: [.usesLineFragmentOrigin], attributes: [
            .font: theme.directoryFont,
            .foregroundColor: color,
        ])
    }

    private func drawDirectoryMarkBar(_ color: NSColor, row: NSRect) {
        let bar = NSRect(x: 6, y: row.minY + 3, width: 2, height: max(1, row.height - 6))
        color.setFill()
        NSBezierPath(roundedRect: bar, xRadius: 1, yRadius: 1).fill()
    }

    private func drawDirectoryLabel(_ label: String, color: NSColor, after text: NSRect, row: NSRect) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: theme.directoryHeaderFont,
            .foregroundColor: color,
        ]
        let size = (label as NSString).size(withAttributes: attrs)
        var originX = text.maxX + 12
        if originX + size.width > bounds.width - 8 {
            originX = bounds.width - 8 - size.width
        }
        let rect = NSRect(x: max(8, originX), y: row.minY, width: size.width + 2, height: row.height)
        (label as NSString).draw(with: rect, options: [.usesLineFragmentOrigin], attributes: attrs)
    }

    private func directoryLineRect(at utf16: Int) -> NSRect? {
        directoryLineBox(at: utf16)?.row
    }

    private func directoryLineBox(at utf16: Int) -> (row: NSRect, text: NSRect)? {
        guard let lm = textLayoutManager else { return nil }
        let doc = lm.documentRange.location
        let index = min(max(0, utf16), (string as NSString).length)
        guard let location = lm.location(doc, offsetBy: index),
              let fragment = lm.textLayoutFragment(for: location) else { return nil }
        let fragmentStart = lm.offset(from: doc, to: fragment.rangeInElement.location)
        let local = index - fragmentStart
        guard let line = fragment.textLineFragments.first(where: { line in
            let span = line.characterRange
            return local >= span.location && local < span.location + max(span.length, 1)
        }) ?? fragment.textLineFragments.last else { return nil }
        let container = textContainerOrigin
        let fragmentFrame = fragment.layoutFragmentFrame
        var text = line.typographicBounds
        text.origin.x += container.x + fragmentFrame.minX
        text.origin.y += container.y + fragmentFrame.minY
        var row = text
        row.origin.x = 0
        row.size.width = bounds.width
        return (row, text)
    }
}
