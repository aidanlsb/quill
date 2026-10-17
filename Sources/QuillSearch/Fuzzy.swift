/// Native fuzzy matcher: subsequence match with bonuses for consecutive runs
/// and matches at the start of the string or after path separators.
public enum Fuzzy {
    public struct Hit: Equatable, Sendable {
        public var value: String
        public var score: Int
    }

    public static func score(query: String, candidate: String) -> Int? {
        if query.isEmpty { return 0 }
        let q = Array(query.lowercased())
        let c = Array(candidate.lowercased())
        guard !q.isEmpty, q.count <= c.count else { return nil }

        var qi = 0
        var score = 0
        var consecutive = 0
        var lastMatch = -2
        for (idx, ch) in c.enumerated() {
            guard qi < q.count else { break }
            if ch == q[qi] {
                var bonus = 1
                if idx == 0 || isBoundary(c, idx) { bonus += 8 }
                if idx == lastMatch + 1 {
                    consecutive += 1
                    bonus += 4 * consecutive
                } else {
                    consecutive = 0
                }
                score += bonus
                lastMatch = idx
                qi += 1
            }
        }
        guard qi == q.count else { return nil }
        score += max(0, 32 - c.count)
        return score
    }

    /// Same scoring as `score`, over precomputed lowercase UTF-8 bytes.
    public static func scoreUTF8(query: [UInt8], candidate: [UInt8]) -> Int? {
        if query.isEmpty { return 0 }
        guard !query.isEmpty, query.count <= candidate.count else { return nil }
        var qi = 0
        var score = 0
        var consecutive = 0
        var lastMatch = -2
        for (idx, byte) in candidate.enumerated() {
            guard qi < query.count else { break }
            if byte == query[qi] {
                var bonus = 1
                if idx == 0 || isBoundaryByte(candidate, idx) { bonus += 8 }
                if idx == lastMatch + 1 {
                    consecutive += 1
                    bonus += 4 * consecutive
                } else {
                    consecutive = 0
                }
                score += bonus
                lastMatch = idx
                qi += 1
            }
        }
        guard qi == query.count else { return nil }
        score += max(0, 32 - candidate.count)
        return score
    }

    public static func rank(query: String, candidates: [String]) -> [Hit] {
        candidates.compactMap { value in
            score(query: query, candidate: value).map { Hit(value: value, score: $0) }
        }
        .sorted {
            if $0.score != $1.score { return $0.score > $1.score }
            return $0.value.localizedStandardCompare($1.value) == .orderedAscending
        }
    }

    private static func isBoundaryByte(_ bytes: [UInt8], _ idx: Int) -> Bool {
        if idx == 0 { return true }
        switch bytes[idx - 1] {
        case UInt8(ascii: "/"), UInt8(ascii: "-"), UInt8(ascii: "_"), UInt8(ascii: "."), UInt8(ascii: " "):
            return true
        default:
            return false
        }
    }

    private static func isBoundary(_ chars: [Character], _ idx: Int) -> Bool {
        if idx == 0 { return true }
        let prev = chars[idx - 1]
        return prev == "/" || prev == "-" || prev == "_" || prev == "." || prev == " "
    }
}
