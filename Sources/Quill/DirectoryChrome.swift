import AppKit
import QuillFS
import QuillVim

/// Presentation for an oil-style directory buffer. The listing text stays
/// `name` / `name/`, which is what parse, plan, and `:w` already understand.
@MainActor
enum DirectoryChrome {
    static let textInset: CGFloat = 40
    static let rightInset: CGFloat = 24
    static let lineHeight: CGFloat = 1.2
    static let iconSize: CGFloat = 13
    static let iconX: CGFloat = 16

    struct LineRef {
        var line: Int
        var listing: ListingLine
    }

    struct LineStyle {
        var isDirectory: Bool
        var isDotfile: Bool
        var mark: DirectoryMark
    }

    struct Presentation {
        var styles: [Int: LineStyle]
        var pendingSummary: String
        var headerHeight: CGFloat
    }

    /// Home becomes `~`. The path always ends in `/` so it reads as a directory.
    static func pathLabel(_ url: URL) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        let shown: String
        if path == home {
            shown = "~"
        } else if path.hasPrefix(home + "/") {
            shown = "~" + path.dropFirst(home.count)
        } else {
            shown = path
        }
        return shown.hasSuffix("/") ? shown : shown + "/"
    }

    /// One ref per non-empty listing line, in buffer order. Same anchor rules as save.
    static func lineRefs(in engine: Engine) -> [LineRef] {
        var refs: [LineRef] = []
        var offset = 0
        let text = engine.text
        let parts = text.split(separator: "\n", omittingEmptySubsequences: false)
        for (lineIndex, raw) in parts.enumerated() {
            let line = String(raw)
            let parsed = ParsedDirLine(line)
            let end = offset + line.utf16.count
            let anchor = engine.buffer.anchors(in: offset..<(end + 1)).first { anchor in
                if case .directoryEntry = anchor.kind { return true }
                return false
            }
            if !parsed.name.isEmpty {
                let listing: ListingLine
                if let anchor, case .directoryEntry(let path, _, let transfer) = anchor.kind {
                    let kind: LineTransfer
                    switch transfer {
                    case .identity: kind = .identity
                    case .move: kind = .move
                    case .copy: kind = .copy
                    }
                    listing = ListingLine(
                        name: parsed.name,
                        isDirectory: parsed.isDirectory,
                        entryID: anchor.id.raw,
                        sourcePath: path,
                        transfer: kind
                    )
                } else {
                    listing = ListingLine(name: parsed.name, isDirectory: parsed.isDirectory)
                }
                refs.append(LineRef(line: lineIndex, listing: listing))
            }
            offset = end + 1
        }
        return refs
    }

    static func pendingSummary(refs: [LineRef], marks: DirectoryMarks) -> String {
        var parts: [String] = []
        for (index, ref) in refs.enumerated() {
            guard index < marks.rows.count else { continue }
            switch marks.rows[index] {
            case .unchanged:
                break
            case .created, .copied:
                parts.append("+ \(ref.listing.name)")
            case .renamed(let from):
                parts.append("→ \(from)")
            }
            if parts.count == 4 { break }
        }
        for name in marks.deleted.prefix(3) {
            parts.append("− \(name)")
        }
        let extra = marks.deleted.count > 3 ? marks.deleted.count - 3 : 0
        if extra > 0 { parts.append("− \(extra) more") }
        return parts.joined(separator: "   ")
    }

    static func presentation(engine: Engine, snapshot: DirectorySnapshot?) -> Presentation {
        guard let snapshot else {
            return Presentation(styles: [:], pendingSummary: "", headerHeight: 36)
        }
        let refs = lineRefs(in: engine)
        let marks = DirectoryListing.marks(original: snapshot, lines: refs.map(\.listing))
        var styles: [Int: LineStyle] = [:]
        for (index, ref) in refs.enumerated() {
            let mark = index < marks.rows.count ? marks.rows[index] : DirectoryMark.unchanged
            styles[ref.line] = LineStyle(
                isDirectory: ref.listing.isDirectory,
                isDotfile: ref.listing.name.hasPrefix("."),
                mark: mark
            )
        }
        let summary = pendingSummary(refs: refs, marks: marks)
        return Presentation(
            styles: styles,
            pendingSummary: summary,
            headerHeight: summary.isEmpty ? 36 : 54
        )
    }
}
