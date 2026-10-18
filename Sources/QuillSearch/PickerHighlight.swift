/// Character ranges a picker row should emphasize for the current query.
/// Indices are extended grapheme clusters in `candidate`, merged into runs.
public enum PickerHighlight {
    public enum Style: Equatable, Sendable {
        /// Left-to-right subsequence, the same walk as `Fuzzy.score`.
        case fuzzy
        /// Case-insensitive literal substring, the same walk as the built-in grep.
        case literal
    }

    public static func ranges(query: String, candidate: String, style: Style) -> [Range<Int>] {
        let indices: [Int]
        switch style {
        case .fuzzy:
            indices = fuzzyIndices(query: query, candidate: candidate)
        case .literal:
            indices = literalIndices(query: query, candidate: candidate)
        }
        return merge(indices)
    }

    private static func fuzzyIndices(query: String, candidate: String) -> [Int] {
        if query.isEmpty { return [] }
        let wanted = Array(query.lowercased())
        let chars = Array(candidate.lowercased())
        var queryIndex = 0
        var matched: [Int] = []
        for (index, character) in chars.enumerated() {
            guard queryIndex < wanted.count else { break }
            if character == wanted[queryIndex] {
                matched.append(index)
                queryIndex += 1
            }
        }
        guard queryIndex == wanted.count else { return [] }
        return matched
    }

    private static func literalIndices(query: String, candidate: String) -> [Int] {
        if query.isEmpty { return [] }
        let wanted = Array(query.lowercased())
        let chars = Array(candidate.lowercased())
        guard !wanted.isEmpty, wanted.count <= chars.count else { return [] }
        var matched: [Int] = []
        var index = 0
        while index + wanted.count <= chars.count {
            let slice = chars[index..<(index + wanted.count)]
            if Array(slice) == wanted {
                for offset in 0..<wanted.count {
                    matched.append(index + offset)
                }
                index += wanted.count
            } else {
                index += 1
            }
        }
        return matched
    }

    private static func merge(_ indices: [Int]) -> [Range<Int>] {
        var ranges: [Range<Int>] = []
        for index in indices {
            if let last = ranges.last, last.upperBound == index {
                ranges[ranges.count - 1] = last.lowerBound..<(index + 1)
            } else {
                ranges.append(index..<(index + 1))
            }
        }
        return ranges
    }
}
