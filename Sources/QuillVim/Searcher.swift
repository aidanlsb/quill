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
        let starts = literalMatches(in: text, pattern: pattern).map(\.lowerBound)
        if forward {
            if let hit = starts.first(where: { $0 > from }) { return hit }
            return wrap ? starts.first : nil
        }
        if let hit = starts.last(where: { $0 < from }) { return hit }
        return wrap ? starts.last : nil
    }

    /// Every place `pattern` occurs in `text` as UTF-16 ranges of `text`, overlapping
    /// ones included, each starting and ending on a grapheme boundary. With smartcase
    /// both sides are lowercased per grapheme; that can change UTF-16 lengths (`İ`
    /// becomes `i̇`), so hits map back through the folded text's origins.
    static func literalMatches(in text: String, pattern: String) -> [Range<Int>] {
        let ignoreCase = ignoresCase(pattern)
        let hay = Folded(text, ignoreCase: ignoreCase)
        let needle = Folded(pattern, ignoreCase: ignoreCase).units
        guard !needle.isEmpty, needle.count <= hay.units.count else { return [] }
        var out: [Range<Int>] = []
        for i in 0...(hay.units.count - needle.count) where hay.isBoundary[i] && hay.isBoundary[i + needle.count] {
            if hay.units[i..<(i + needle.count)].elementsEqual(needle) {
                out.append(hay.origin[i]..<hay.origin[i + needle.count])
            }
        }
        return out
    }

    private struct Folded {
        var units: [UInt16] = []
        /// UTF-16 offset in the source of the grapheme each unit came from; one extra entry for the end.
        var origin: [Int] = []
        /// Whether a unit starts a grapheme; one extra `true` for the end.
        var isBoundary: [Bool] = []

        init(_ text: String, ignoreCase: Bool) {
            var at = 0
            for character in text {
                let folded = ignoreCase ? character.lowercased() : String(character)
                for (k, unit) in folded.utf16.enumerated() {
                    units.append(unit)
                    origin.append(at)
                    isBoundary.append(k == 0)
                }
                at += character.utf16.count
            }
            origin.append(at)
            isBoundary.append(true)
        }
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
