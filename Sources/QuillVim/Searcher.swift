/// Literal search with smartcase, and regex when the pattern uses metacharacters.
/// Offsets are UTF-16, matching the rope.
enum Searcher {
    static func find(
        text: String,
        pattern: String,
        from: Int,
        forward: Bool,
        wrap: Bool
    ) -> Int? {
        guard !pattern.isEmpty, !text.isEmpty else { return nil }
        if usesRegex(pattern) {
            return regexFind(text: text, pattern: pattern, from: from, forward: forward, wrap: wrap)
        }
        return literalFind(text: text, pattern: pattern, from: from, forward: forward, wrap: wrap)
    }

    static func usesRegex(_ pattern: String) -> Bool {
        pattern.contains { ".*+?[]()|^$\\".contains($0) }
    }

    static func ignoresCase(_ pattern: String) -> Bool {
        !pattern.contains { $0.isUppercase && $0.isLetter }
    }

    private static func literalFind(
        text: String,
        pattern: String,
        from: Int,
        forward: Bool,
        wrap: Bool
    ) -> Int? {
        let hay = Array(folded(text, ignoreCase: ignoresCase(pattern)).utf16)
        let needle = Array(folded(pattern, ignoreCase: ignoresCase(pattern)).utf16)
        guard !needle.isEmpty, needle.count <= hay.count else { return nil }
        if forward {
            let start = min(max(0, from + 1), hay.count)
            if let hit = scan(hay, needle, from: start, through: hay.count) { return hit }
            if wrap, let hit = scan(hay, needle, from: 0, through: min(start, hay.count)) { return hit }
        } else {
            let before = min(max(0, from), hay.count)
            if let hit = scanBackward(hay, needle, from: before, limit: 0) { return hit }
            if wrap, let hit = scanBackward(hay, needle, from: hay.count, limit: before) { return hit }
        }
        return nil
    }

    private static func scan(_ hay: [UInt16], _ needle: [UInt16], from: Int, through end: Int) -> Int? {
        var i = from
        while i + needle.count <= end && i + needle.count <= hay.count {
            if matches(hay, needle, at: i) { return i }
            i += 1
        }
        return nil
    }

    private static func scanBackward(_ hay: [UInt16], _ needle: [UInt16], from: Int, limit: Int) -> Int? {
        var i = min(from, hay.count - needle.count + 1) - 1
        while i >= limit {
            if i >= 0, matches(hay, needle, at: i) { return i }
            i -= 1
        }
        return nil
    }

    private static func matches(_ hay: [UInt16], _ needle: [UInt16], at: Int) -> Bool {
        for offset in 0..<needle.count where hay[at + offset] != needle[offset] { return false }
        return true
    }

    private static func folded(_ text: String, ignoreCase: Bool) -> String {
        ignoreCase ? text.lowercased() : text
    }

    private static func regexFind(
        text: String,
        pattern: String,
        from: Int,
        forward: Bool,
        wrap: Bool
    ) -> Int? {
        guard var regex = try? Regex(pattern) else {
            return literalFind(text: text, pattern: pattern, from: from, forward: forward, wrap: wrap)
        }
        if ignoresCase(pattern) { regex = regex.ignoresCase() }
        let start = index(atUTF16: min(max(0, from + (forward ? 1 : 0)), text.utf16.count), in: text)
        if forward {
            if let hit = firstRegex(text, regex, from: start, through: text.endIndex) { return hit }
            if wrap, let hit = firstRegex(text, regex, from: text.startIndex, through: start) { return hit }
        } else {
            if let hit = lastRegex(text, regex, before: start) { return hit }
            if wrap, let hit = lastRegex(text, regex, before: text.endIndex, after: start) { return hit }
        }
        return nil
    }

    private static func firstRegex(_ text: String, _ regex: Regex<AnyRegexOutput>, from: String.Index, through end: String.Index) -> Int? {
        guard from <= end else { return nil }
        let slice = text[from..<end]
        guard let match = slice.firstMatch(of: regex) else { return nil }
        return utf16Offset(of: match.range.lowerBound, in: text)
    }

    private static func lastRegex(_ text: String, _ regex: Regex<AnyRegexOutput>, before: String.Index, after: String.Index? = nil) -> Int? {
        let lower = after ?? text.startIndex
        let slice = text[lower..<before]
        var found: String.Index?
        for match in slice.matches(of: regex) {
            found = match.range.lowerBound
        }
        return found.map { utf16Offset(of: $0, in: text) }
    }

    static func index(atUTF16 offset: Int, in text: String) -> String.Index {
        var remaining = max(0, offset)
        var index = text.startIndex
        while index < text.endIndex, remaining > 0 {
            let width = text[index].utf16.count
            if width > remaining { break }
            remaining -= width
            index = text.index(after: index)
        }
        return index
    }

    static func utf16Offset(of index: String.Index, in text: String) -> Int {
        text[text.startIndex..<index].utf16.count
    }

    /// Split `/pat/rep/flags` (the first character is the separator).
    static func substituteParts(_ args: String) -> (pattern: String, replacement: String, global: Bool)? {
        guard let separator = args.first else { return nil }
        let body = args.dropFirst()
        var pattern = ""
        var replacement = ""
        var flags = ""
        var stage = 0
        for ch in body {
            if ch == separator {
                stage += 1
                continue
            }
            if stage == 0 { pattern.append(ch) }
            else if stage == 1 { replacement.append(ch) }
            else { flags.append(ch) }
        }
        guard stage >= 1 else { return nil }
        return (pattern, replacement, flags.contains("g"))
    }
}
