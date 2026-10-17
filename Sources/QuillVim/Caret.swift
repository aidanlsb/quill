/// One character cell for the caret. Coordinates are flipped: `y` grows downward,
/// and `baselineY` is the baseline of the glyph under the cursor.
public struct CaretBox: Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

public enum CaretShape: Equatable, Sendable {
    /// Normal mode. Width is the glyph's advance, not the font's maximum advance
    /// and not the rest of the line.
    case block
    /// Insert mode. A one-point beam with the same em-box height as the block.
    case beam
}

public enum CaretGeometry {
    /// Height is the font em box (`ascender - descender`), never the line-fragment
    /// height. `descender` is negative when the font hangs below the baseline,
    /// matching `NSFont.descender`.
    public static func box(
        shape: CaretShape,
        glyphAdvance: Double,
        ascender: Double,
        descender: Double,
        originX: Double,
        baselineY: Double
    ) -> CaretBox {
        let height = max(1, ascender - descender)
        let width: Double
        switch shape {
        case .beam:
            width = 1
        case .block:
            width = max(1, glyphAdvance)
        }
        return CaretBox(
            x: originX,
            y: baselineY - ascender,
            width: width,
            height: height
        )
    }
}
