/// Screen rows under a buffer line that hold an image preview.
///
/// The preview is not text. `ScreenModel.screenLines(of:)` appends these after
/// the text rows from `ScreenLayout.rowRanges`, using `ScreenLayout.gapRows`.
/// `next(after:)` and `previous(before:)` skip the gap, so one `j` or `k`
/// crosses the whole preview and the caret never stops on it.
public struct ScreenRowSpan: Equatable, Sendable {
    public var range: Range<Int>
    /// True for the image preview. `range` is empty and is not a caret position.
    public var isGap: Bool

    public init(range: Range<Int>, isGap: Bool) {
        self.range = range
        self.isGap = isGap
    }
}

public enum ImageScreenRows {
    /// Text rows, then `gapRows` empty rows at `contentEnd`.
    public static func appending(textRows: [Range<Int>], gapRows: Int, contentEnd: Int) -> [ScreenRowSpan] {
        var rows = textRows.map { ScreenRowSpan(range: $0, isGap: false) }
        if rows.isEmpty {
            rows = [ScreenRowSpan(range: contentEnd..<contentEnd, isGap: false)]
        }
        let gaps = max(0, gapRows)
        if gaps > 0 {
            let gap = ScreenRowSpan(range: contentEnd..<contentEnd, isGap: true)
            for _ in 0..<gaps {
                rows.append(gap)
            }
        }
        return rows
    }

    /// Where a vertical step lands inside this line. Gap rows are not a stop:
    /// a step that would enter one leaves the line (`nil`) after crossing the
    /// whole run, and the caller moves to the next buffer line.
    public static func landable(in rows: [ScreenRowSpan], from index: Int, delta: Int) -> Int? {
        guard rows.indices.contains(index), delta != 0 else { return nil }
        let step = delta > 0 ? 1 : -1
        var cursor = index
        var remaining = abs(delta)
        while remaining > 0 {
            let next = cursor + step
            guard rows.indices.contains(next) else { return nil }
            cursor = next
            if rows[cursor].isGap { continue }
            remaining -= 1
        }
        return rows[cursor].isGap ? nil : cursor
    }
}
