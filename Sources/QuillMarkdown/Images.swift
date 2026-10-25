/// Inline images. The markdown source stays plain text: a preview is screen
/// space under the source line, never characters in the buffer.
public struct MarkdownImage: Equatable, Sendable {
    public var line: Int
    /// UTF-16 range of the whole `![alt](destination)` marker.
    public var range: Range<Int>
    public var alt: String
    public var destination: String

    public init(line: Int, range: Range<Int>, alt: String, destination: String) {
        self.line = line
        self.range = range
        self.alt = alt
        self.destination = destination
    }
}

public enum ResolvedImage: Equatable, Sendable {
    case local(path: String)
    case remote(url: String)

    public var identity: String {
        switch self {
        case .local(let path): return "file:" + path
        case .remote(let url): return "url:" + url
        }
    }
}

public enum MarkdownImages {
    /// Every inline image outside frontmatter, fenced code, and inline code.
    /// Reference-style `![alt][id]` is not a preview. One pass; lines without
    /// `!` are not copied.
    public static func find(in text: String) -> [MarkdownImage] {
        var images: [MarkdownImage] = []
        var index = text.startIndex
        var utf16 = 0
        var line = 0
        var inFence = false
        var inFrontmatter = text.hasPrefix("---")
        while index < text.endIndex {
            let lineStart = index
            let lineUTF = utf16
            var hasBang = false
            while index < text.endIndex, text[index] != "\n" {
                if text[index] == "!" { hasBang = true }
                utf16 += text[index].utf16.count
                index = text.index(after: index)
            }
            let lineEnd = index
            if inFrontmatter {
                if line > 0, text[lineStart..<lineEnd] == "---" {
                    inFrontmatter = false
                }
            } else if isFence(text, lineStart, lineEnd) {
                inFence.toggle()
            } else if !inFence, hasBang {
                let slice = String(text[lineStart..<lineEnd])
                images.append(contentsOf: imagesInLine(slice, lineNumber: line, utf16: lineUTF))
            }
            if index < text.endIndex {
                utf16 += text[index].utf16.count
                index = text.index(after: index)
            }
            line += 1
        }
        return images
    }

    private static func isFence(_ text: String, _ start: String.Index, _ end: String.Index) -> Bool {
        var index = start
        var spaces = 0
        while index < end, text[index] == " ", spaces < 3 {
            spaces += 1
            index = text.index(after: index)
        }
        guard index < end else { return false }
        if text[index] == "`" { return hasPrefix(text, index, end, "```") }
        if text[index] == "~" { return hasPrefix(text, index, end, "~~~") }
        return false
    }

    private static func hasPrefix(_ text: String, _ start: String.Index, _ end: String.Index, _ prefix: String) -> Bool {
        var index = start
        for character in prefix {
            if index >= end || text[index] != character { return false }
            index = text.index(after: index)
        }
        return true
    }

    static func imagesInLine(_ source: String, lineNumber: Int, utf16: Int) -> [MarkdownImage] {
        var images: [MarkdownImage] = []
        var index = source.startIndex
        var cursor = utf16
        var code = false
        while index < source.endIndex {
            let character = source[index]
            if character == "\\" {
                guard let next = source.index(index, offsetBy: 1, limitedBy: source.endIndex), next < source.endIndex else { break }
                cursor += character.utf16.count + source[next].utf16.count
                index = source.index(after: next)
                continue
            }
            if character == "`" {
                code.toggle()
                cursor += character.utf16.count
                index = source.index(after: index)
                continue
            }
            if !code,
               character == "!",
               let bracket = source.index(index, offsetBy: 1, limitedBy: source.endIndex),
               bracket < source.endIndex,
               source[bracket] == "[",
               let match = matchImage(source, bang: index, bangUTF: cursor) {
                images.append(MarkdownImage(
                    line: lineNumber,
                    range: match.range,
                    alt: match.alt,
                    destination: match.destination
                ))
                index = match.end
                cursor = match.endUTF
                continue
            }
            cursor += character.utf16.count
            index = source.index(after: index)
        }
        return images
    }

    private struct Match {
        var range: Range<Int>
        var alt: String
        var destination: String
        var end: String.Index
        var endUTF: Int
    }

    private static func matchImage(_ line: String, bang: String.Index, bangUTF: Int) -> Match? {
        guard let bracket = line.index(bang, offsetBy: 1, limitedBy: line.endIndex), bracket < line.endIndex else { return nil }
        var index = line.index(after: bracket)
        var utf = bangUTF + line[bang].utf16.count + line[bracket].utf16.count
        var depth = 1
        var alt = ""
        while index < line.endIndex, depth > 0 {
            let character = line[index]
            if character == "\\" {
                guard let next = line.index(index, offsetBy: 1, limitedBy: line.endIndex), next < line.endIndex else { return nil }
                alt.append(line[next])
                utf += character.utf16.count + line[next].utf16.count
                index = line.index(after: next)
                continue
            }
            utf += character.utf16.count
            if character == "[" {
                depth += 1
                alt.append(character)
            } else if character == "]" {
                depth -= 1
                if depth > 0 { alt.append(character) }
            } else {
                alt.append(character)
            }
            index = line.index(after: index)
        }
        guard depth == 0, index < line.endIndex, line[index] == "(" else { return nil }
        utf += line[index].utf16.count
        index = line.index(after: index)
        guard let destination = readDestination(line, from: &index, utf16: &utf) else { return nil }
        let trimmed = trim(destination)
        guard !trimmed.isEmpty else { return nil }
        return Match(range: bangUTF..<utf, alt: alt, destination: trimmed, end: index, endUTF: utf)
    }

    /// `index` and `utf16` sit just after `(`. On success they sit just after `)`.
    private static func readDestination(_ line: String, from index: inout String.Index, utf16: inout Int) -> String? {
        guard index < line.endIndex else { return nil }
        let destination: String
        if line[index] == "<" {
            utf16 += line[index].utf16.count
            index = line.index(after: index)
            var raw = ""
            var closed = false
            while index < line.endIndex {
                let character = line[index]
                utf16 += character.utf16.count
                index = line.index(after: index)
                if character == ">" {
                    closed = true
                    break
                }
                raw.append(character)
            }
            guard closed else { return nil }
            destination = raw
        } else {
            var raw = ""
            var depth = 0
            while index < line.endIndex {
                let character = line[index]
                if character == " " || character == "\t" { break }
                if character == ")" && depth == 0 { break }
                if character == "(" { depth += 1 }
                if character == ")" { depth -= 1 }
                raw.append(character)
                utf16 += character.utf16.count
                index = line.index(after: index)
            }
            destination = raw
        }
        while index < line.endIndex, line[index] == " " || line[index] == "\t" {
            utf16 += line[index].utf16.count
            index = line.index(after: index)
        }
        if index < line.endIndex, line[index] == "\"" || line[index] == "'" {
            let quote = line[index]
            utf16 += quote.utf16.count
            index = line.index(after: index)
            while index < line.endIndex, line[index] != quote {
                utf16 += line[index].utf16.count
                index = line.index(after: index)
            }
            guard index < line.endIndex else { return nil }
            utf16 += line[index].utf16.count
            index = line.index(after: index)
            while index < line.endIndex, line[index] == " " || line[index] == "\t" {
                utf16 += line[index].utf16.count
                index = line.index(after: index)
            }
        }
        guard index < line.endIndex, line[index] == ")" else { return nil }
        utf16 += line[index].utf16.count
        index = line.index(after: index)
        return destination
    }

    static func trim(_ text: String) -> String {
        var start = text.startIndex
        var end = text.endIndex
        while start < end, isSpace(text[start]) {
            start = text.index(after: start)
        }
        while end > start {
            let previous = text.index(before: end)
            if !isSpace(text[previous]) { break }
            end = previous
        }
        return start == text.startIndex && end == text.endIndex ? text : String(text[start..<end])
    }

    private static func isSpace(_ character: Character) -> Bool {
        character == " " || character == "\t" || character == "\n" || character == "\r"
    }
}

public enum ImagePaths {
    /// `filePath` is the markdown file. Relative paths need it. `~` uses `home`.
    /// `http` and `https` stay remote. Anything else that cannot be placed is nil.
    public static func resolve(_ destination: String, filePath: String?, home: String) -> ResolvedImage? {
        let raw = MarkdownImages.trim(destination)
        if raw.isEmpty { return nil }
        let lower = raw.lowercased()
        if lower.hasPrefix("https://") || lower.hasPrefix("http://") {
            let scheme = lower.hasPrefix("https://") ? "https://" : "http://"
            let rest = raw.dropFirst(scheme.count)
            if rest.isEmpty || rest.hasPrefix("/") { return nil }
            return .remote(url: raw)
        }
        if lower.hasPrefix("file:") {
            return fileURL(raw)
        }
        if raw == "~" || raw.hasPrefix("~/") {
            let rest = raw == "~" ? "" : String(raw.dropFirst(2))
            let root = trimSlash(home)
            let joined = rest.isEmpty ? root : root + "/" + rest
            return .local(path: standardize(percentDecode(joined)))
        }
        if raw.hasPrefix("~") { return nil }
        if raw.hasPrefix("/") {
            return .local(path: standardize(percentDecode(raw)))
        }
        guard let filePath, !filePath.isEmpty else { return nil }
        let dir = directory(of: filePath)
        let joined = dir == "/" ? "/" + raw : dir + "/" + raw
        return .local(path: standardize(percentDecode(joined)))
    }

    private static func fileURL(_ raw: String) -> ResolvedImage? {
        var path = raw
        let lower = raw.lowercased()
        if lower.hasPrefix("file://localhost") {
            path = String(raw.dropFirst("file://localhost".count))
        } else if lower.hasPrefix("file://") {
            path = String(raw.dropFirst("file://".count))
        } else {
            path = String(raw.dropFirst("file:".count))
        }
        if let query = path.firstIndex(of: "?") { path = String(path[..<query]) }
        if let fragment = path.firstIndex(of: "#") { path = String(path[..<fragment]) }
        if path.hasPrefix("//") { return nil }
        if !path.hasPrefix("/") { path = "/" + path }
        let decoded = standardize(percentDecode(path))
        if decoded.isEmpty || decoded == "/" { return nil }
        return .local(path: decoded)
    }

    static func directory(of path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return "." }
        if slash == path.startIndex { return "/" }
        return String(path[..<slash])
    }

    static func standardize(_ path: String) -> String {
        let absolute = path.hasPrefix("/")
        var parts: [String] = []
        for part in path.split(separator: "/", omittingEmptySubsequences: true) {
            if part == "." { continue }
            if part == ".." {
                if let last = parts.last, last != ".." {
                    parts.removeLast()
                } else if !absolute {
                    parts.append("..")
                }
                continue
            }
            parts.append(String(part))
        }
        let joined = parts.joined(separator: "/")
        if absolute { return "/" + joined }
        return joined.isEmpty ? "." : joined
    }

    static func percentDecode(_ text: String) -> String {
        var bytes: [UInt8] = []
        var changed = false
        var index = text.startIndex
        while index < text.endIndex {
            if text[index] == "%",
               let first = text.index(index, offsetBy: 1, limitedBy: text.endIndex),
               let second = text.index(index, offsetBy: 2, limitedBy: text.endIndex),
               second < text.endIndex,
               let hi = hex(text[first]),
               let lo = hex(text[second]) {
                bytes.append((hi << 4) | lo)
                index = text.index(after: second)
                changed = true
                continue
            }
            let character = text[index]
            for unit in String(character).utf8 { bytes.append(unit) }
            index = text.index(after: index)
        }
        if !changed { return text }
        return String(decoding: bytes, as: UTF8.self)
    }

    private static func hex(_ character: Character) -> UInt8? {
        guard let scalar = character.unicodeScalars.first, character.unicodeScalars.count == 1 else { return nil }
        let value = scalar.value
        switch value {
        case 48...57: return UInt8(value - 48)
        case 65...70: return UInt8(value - 55)
        case 97...102: return UInt8(value - 87)
        default: return nil
        }
    }

    private static func trimSlash(_ path: String) -> String {
        if path.count > 1, path.hasSuffix("/") { return String(path.dropLast()) }
        return path
    }
}

/// What an open markdown file is allowed to load as a preview.
public enum ImageLoads {
    /// Remote URLs are not fetched. Opening a note must not contact the network.
    public static func mayFetch(_ image: ResolvedImage) -> Bool {
        if case .local = image { return true }
        return false
    }

    public static let maxFileBytes = 32 * 1024 * 1024
    public static let maxPixelSide = 8_192
    public static let maxPixelCount = 32_000_000

    public static func allowsFileSize(_ bytes: Int) -> Bool {
        bytes >= 0 && bytes <= maxFileBytes
    }

    public static func allowsPixels(width: Int, height: Int) -> Bool {
        if width <= 0 || height <= 0 { return false }
        if width > maxPixelSide || height > maxPixelSide { return false }
        let count = width.multipliedReportingOverflow(by: height)
        if count.overflow { return false }
        return count.partialValue <= maxPixelCount
    }
}

/// Display size of a preview. The width fits the writing column, the aspect
/// ratio is kept, and the height stops at `maxHeight`.
public enum ImageFit {
    public static let maxHeight: Double = 360
    public static let placeholderHeight: Double = 72
    public static let verticalGap: Double = 6
    public static let cornerRadius: Double = 8

    public static func displaySize(pixelWidth: Int, pixelHeight: Int, columnWidth: Double) -> (width: Double, height: Double) {
        let column = max(1, columnWidth)
        guard pixelWidth > 0, pixelHeight > 0 else {
            return (column, placeholderHeight)
        }
        let aspect = Double(pixelHeight) / Double(pixelWidth)
        var width = column
        var height = width * aspect
        if height > maxHeight {
            height = maxHeight
            width = min(column, height / aspect)
        }
        return (max(1, width), max(1, height))
    }

    public static func screenRows(height: Double, rowHeight: Double) -> Int {
        let row = rowHeight > 0 ? rowHeight : 1
        return max(1, Int((height / row).rounded(.up)))
    }

    /// Gap, then each image, then a gap after every image.
    public static func spacing(heights: [Double]) -> Double {
        guard !heights.isEmpty else { return 0 }
        return verticalGap + heights.reduce(0, +) + verticalGap * Double(heights.count)
    }
}

/// Memory cache addressed by path (or URL) and modification time.
/// A different mtime is a miss and drops the stale entry. Remote images use
/// a nil mtime and stay until `invalidate`.
public struct ImageCache<Value> {
    public struct Key: Equatable, Hashable, Sendable {
        public var identity: String
        public var modified: Int64?

        public init(identity: String, modified: Int64?) {
            self.identity = identity
            self.modified = modified
        }
    }

    private var entries: [String: (key: Key, value: Value)] = [:]
    private var order: [String] = []
    public var limit: Int

    public init(limit: Int = 64) {
        self.limit = max(1, limit)
    }

    public var count: Int { entries.count }

    public mutating func value(for key: Key) -> Value? {
        guard let entry = entries[key.identity] else { return nil }
        guard entry.key.modified == key.modified else {
            entries[key.identity] = nil
            order.removeAll { $0 == key.identity }
            return nil
        }
        touch(key.identity)
        return entry.value
    }

    /// The entry for `identity`, whatever its mtime. Does not drop a mismatch.
    public mutating func stored(identity: String) -> (modified: Int64?, value: Value)? {
        guard let entry = entries[identity] else { return nil }
        touch(identity)
        return (entry.key.modified, entry.value)
    }

    public mutating func store(_ value: Value, for key: Key) {
        let exists = entries[key.identity] != nil
        if !exists, entries.count >= limit, let oldest = order.first {
            entries[oldest] = nil
            order.removeFirst()
        }
        entries[key.identity] = (key, value)
        touch(key.identity)
    }

    public mutating func invalidate(identity: String) {
        entries[identity] = nil
        order.removeAll { $0 == identity }
    }

    private mutating func touch(_ identity: String) {
        if let index = order.firstIndex(of: identity) {
            order.remove(at: index)
        }
        order.append(identity)
    }
}
