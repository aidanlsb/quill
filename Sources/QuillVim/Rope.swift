/// Weight-balanced implicit treap of ~1 KB chunks.
/// Offsets are UTF-16 code units, matching NSString, TextKit, and LSP.
/// Each node summarizes the UTF-16 length and newline count of its subtree,
/// so index, line, and edit operations are O(log n).
public struct Rope: Equatable {
    static let chunkUTF16 = 1024

    final class Node {
        var priority: UInt64
        var left: Node?
        var right: Node?
        var text: String
        var utf16: Int = 0
        var newlines: Int = 0
        var pieceUTF16: Int = 0
        var pieceNewlines: Int = 0

        init(text: String, priority: UInt64) {
            self.text = text
            self.priority = priority
            recompute()
        }

        func recompute() {
            pieceUTF16 = text.utf16.count
            var nl = 0
            for unit in text.utf16 where unit == 10 { nl += 1 }
            pieceNewlines = nl
            utf16 = (left?.utf16 ?? 0) + pieceUTF16 + (right?.utf16 ?? 0)
            newlines = (left?.newlines ?? 0) + pieceNewlines + (right?.newlines ?? 0)
        }

        func deepCopy() -> Node {
            let copy = Node(text: text, priority: priority)
            copy.left = left?.deepCopy()
            copy.right = right?.deepCopy()
            copy.recompute()
            return copy
        }
    }

    final class Storage {
        var root: Node?
        var cached: String?
        var nextPriority: UInt64 = 1
        func priority() -> UInt64 {
            nextPriority &+= 0x9E37_79B9_7F4A_7C15
            return nextPriority | 1
        }
    }

    private var storage: Storage

    public init() {
        storage = Storage()
    }

    public init(_ text: String) {
        storage = Storage()
        if !text.isEmpty {
            storage.root = build(text)
        }
    }

    public var utf16Count: Int { storage.root?.utf16 ?? 0 }
    public var newlineCount: Int { storage.root?.newlines ?? 0 }
    public var isEmpty: Bool { utf16Count == 0 }

    public var content: String {
        if let cached = storage.cached { return cached }
        var out = ""
        out.reserveCapacity(utf16Count)
        collect(storage.root, into: &out)
        storage.cached = out
        return out
    }

    public static func == (lhs: Rope, rhs: Rope) -> Bool {
        lhs.utf16Count == rhs.utf16Count && lhs.content == rhs.content
    }

    public mutating func replace(_ range: Range<Int>, with new: String) {
        ensureUnique()
        storage.cached = nil
        let lower = range.lowerBound
        let upper = range.upperBound
        let (left, rest) = split(storage.root, lower)
        let (_, right) = split(rest, upper - lower)
        let mid = new.isEmpty ? nil : build(new)
        storage.root = merge(merge(left, mid), right)
    }

    public func substring(_ range: Range<Int>) -> String {
        if range.isEmpty { return "" }
        let lower = max(0, range.lowerBound)
        let upper = min(utf16Count, max(lower, range.upperBound))
        if lower >= upper { return "" }
        var out = ""
        collect(storage.root, range: lower..<upper, base: 0, into: &out)
        return out
    }

    /// Leaf piece containing `offset`, plus the piece-local UTF-16 index and the
    /// absolute UTF-16 offset where that piece begins.
    func piece(at offset: Int) -> (text: String, local: Int, base: Int)? {
        guard utf16Count > 0 else { return nil }
        let target = min(max(0, offset), utf16Count - 1)
        var node = storage.root
        var base = 0
        while let n = node {
            let leftCount = n.left?.utf16 ?? 0
            if target < base + leftCount {
                node = n.left
                continue
            }
            base += leftCount
            if target < base + n.pieceUTF16 {
                return (n.text, target - base, base)
            }
            base += n.pieceUTF16
            node = n.right
        }
        return nil
    }

    /// UTF-16 span of the grapheme cluster that contains `offset`.
    public func graphemeSpan(containing offset: Int) -> Range<Int> {
        guard let piece = piece(at: offset) else { return 0..<0 }
        var units = 0
        var index = piece.text.startIndex
        while index < piece.text.endIndex {
            let width = piece.text[index].utf16.count
            let next = units + width
            if piece.local < next {
                return (piece.base + units)..<(piece.base + next)
            }
            units = next
            index = piece.text.index(after: index)
        }
        let end = piece.base + piece.text.utf16.count
        return (end - 1)..<end
    }

    public func character(at offset: Int) -> Character {
        let span = graphemeSpan(containing: offset)
        let text = substring(span)
        return text.first ?? "\u{FFFD}"
    }

    // MARK: Tree

    private mutating func ensureUnique() {
        if !isKnownUniquelyReferenced(&storage) {
            let copy = Storage()
            copy.root = storage.root?.deepCopy()
            copy.nextPriority = storage.nextPriority
            storage = copy
        }
    }

    private func build(_ text: String) -> Node? {
        let parts = chunks(of: text)
        var node: Node?
        for part in parts {
            let leaf = Node(text: part, priority: storage.priority())
            node = merge(node, leaf)
        }
        return node
    }

    private func chunks(of text: String) -> [String] {
        var parts: [String] = []
        var start = text.startIndex
        var units = 0
        var index = text.startIndex
        while index < text.endIndex {
            let width = text[index].utf16.count
            if units > 0, units + width > Self.chunkUTF16 {
                parts.append(String(text[start..<index]))
                start = index
                units = 0
            }
            units += width
            index = text.index(after: index)
        }
        if start < text.endIndex {
            parts.append(String(text[start..<text.endIndex]))
        }
        return parts
    }

    private func merge(_ a: Node?, _ b: Node?) -> Node? {
        guard let a else { return b }
        guard let b else { return a }
        if a.left == nil, a.right == nil, b.left == nil, b.right == nil,
           a.pieceUTF16 + b.pieceUTF16 <= Self.chunkUTF16 {
            a.text += b.text
            a.recompute()
            return a
        }
        if a.priority > b.priority {
            a.right = merge(a.right, b)
            a.recompute()
            return a
        } else {
            b.left = merge(a, b.left)
            b.recompute()
            return b
        }
    }

    private func split(_ n: Node?, _ index: Int) -> (Node?, Node?) {
        guard let n else { return (nil, nil) }
        if index <= 0 { return (nil, n) }
        if index >= n.utf16 { return (n, nil) }
        let leftCount = n.left?.utf16 ?? 0
        if index < leftCount {
            let (l, r) = split(n.left, index)
            n.left = r
            n.recompute()
            return (l, n)
        }
        let pieceStart = leftCount
        let local = index - pieceStart
        if local >= n.pieceUTF16 {
            let (l, r) = split(n.right, local - n.pieceUTF16)
            n.right = l
            n.recompute()
            return (n, r)
        }
        if local == 0 {
            let left = n.left
            n.left = nil
            n.recompute()
            return (left, n)
        }
        let (head, tail) = splitPiece(n.text, at: local)
        let oldRight = n.right
        n.text = head
        n.right = nil
        n.recompute()
        let rightPiece = Node(text: tail, priority: storage.priority())
        let right = merge(rightPiece, oldRight)
        return (n, right)
    }

    private func splitPiece(_ text: String, at utf16: Int) -> (String, String) {
        var units = 0
        var index = text.startIndex
        while index < text.endIndex, units < utf16 {
            let width = text[index].utf16.count
            if units + width > utf16 { break }
            units += width
            index = text.index(after: index)
        }
        return (String(text[..<index]), String(text[index...]))
    }

    private func collect(_ n: Node?, into out: inout String) {
        guard let n else { return }
        collect(n.left, into: &out)
        out += n.text
        collect(n.right, into: &out)
    }

    private func collect(_ n: Node?, range: Range<Int>, base: Int, into out: inout String) {
        guard let n else { return }
        let leftCount = n.left?.utf16 ?? 0
        let leftEnd = base + leftCount
        if range.lowerBound < leftEnd {
            collect(n.left, range: range, base: base, into: &out)
        }
        let pieceStart = leftEnd
        let pieceEnd = pieceStart + n.pieceUTF16
        let lo = max(range.lowerBound, pieceStart)
        let hi = min(range.upperBound, pieceEnd)
        if lo < hi {
            let localLo = lo - pieceStart
            let localHi = hi - pieceStart
            out += slice(n.text, localLo..<localHi)
        }
        if range.upperBound > pieceEnd {
            collect(n.right, range: range, base: pieceEnd, into: &out)
        }
    }

    private func slice(_ text: String, _ range: Range<Int>) -> String {
        var units = 0
        var start: String.Index?
        var end: String.Index?
        var index = text.startIndex
        while index < text.endIndex {
            if units == range.lowerBound { start = index }
            if units == range.upperBound { end = index; break }
            let width = text[index].utf16.count
            if start == nil, units + width > range.lowerBound { start = index }
            units += width
            if end == nil, units >= range.upperBound {
                end = text.index(after: index)
                break
            }
            index = text.index(after: index)
        }
        let s = start ?? text.endIndex
        let e = end ?? text.endIndex
        return String(text[s..<e])
    }
}
