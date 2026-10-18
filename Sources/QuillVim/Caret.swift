import Foundation

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

public struct CaretRGB: Equatable, Sendable {
    public var r: Double
    public var g: Double
    public var b: Double

    public init(r: Double, g: Double, b: Double) {
        self.r = r
        self.g = g
        self.b = b
    }
}

public enum CaretShape: Equatable, Sendable {
    /// Normal mode. Width is the glyph's advance, not the font's maximum advance
    /// and not the rest of the line.
    case block
    /// Insert mode. A 2-device-pixel beam with the same em-box height as the block.
    case beam
}

public enum CaretGeometry {
    /// How far a caret height may sit from the font em box before it is the line box.
    public static let glyphHeightMultiple = 1.3
    /// Normal-mode fill. Low enough that the glyph underneath stays readable.
    public static let blockFillAlpha = 0.38
    public static let lightAccent = CaretRGB(r: 0.17, g: 0.39, b: 0.76)
    public static let darkAccent = CaretRGB(r: 0.49, g: 0.72, b: 0.98)

    public static func accent(darkBackground: Bool) -> CaretRGB {
        darkBackground ? darkAccent : lightAccent
    }

    /// `backingScale` is `NSWindow.backingScaleFactor`. Two device pixels, in points.
    public static func beamPointWidth(backingScale: Double) -> Double {
        let scale = backingScale >= 1 ? backingScale : 2
        return 2 / scale
    }

    /// Height is the font em box (`ascender - descender`), never the line-fragment
    /// height. `descender` is negative when the font hangs below the baseline,
    /// matching `NSFont.descender`. The top of the box is `baselineY - ascender`.
    public static func box(
        shape: CaretShape,
        glyphAdvance: Double,
        ascender: Double,
        descender: Double,
        originX: Double,
        baselineY: Double,
        beamPointWidth: Double = 2
    ) -> CaretBox {
        let height = max(1, ascender - descender)
        let width: Double
        switch shape {
        case .beam:
            width = max(0.5, beamPointWidth)
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

    /// `baselinePosition` is the value TextKit passes to `enumerateTextSegments`.
    /// It is either the baseline's container y, or its offset from the segment top.
    /// The one that lands inside the segment is the baseline. On the first line both
    /// readings coincide.
    public static func resolvedBaseline(
        segmentMinY: Double,
        segmentHeight: Double,
        baselinePosition: Double
    ) -> Double? {
        let frameMax = segmentMinY + segmentHeight
        let absolute = baselinePosition
        let relative = segmentMinY + baselinePosition
        func inside(_ y: Double) -> Bool {
            y >= segmentMinY - 1 && y <= frameMax + 1
        }
        let absoluteInside = inside(absolute)
        let relativeInside = inside(relative)
        if absoluteInside && !relativeInside { return absolute }
        if relativeInside && !absoluteInside { return relative }
        if absoluteInside && relativeInside {
            if baselinePosition <= segmentHeight + 1.5 { return relative }
            return absolute
        }
        return nil
    }

    public static func heightFitsEm(caretHeight: Double, emHeight: Double) -> Bool {
        let em = max(emHeight, 0.1)
        return caretHeight <= em * glyphHeightMultiple + 0.75
            && caretHeight + 0.75 >= em / glyphHeightMultiple
    }

    /// Vertical em box, and the caret's leading edge still on that line (end of
    /// line included). A line-fragment caret fails this because it is taller
    /// than the em box.
    public static func sitsInGlyphBounds(caret: CaretBox, glyph: CaretBox, slop: Double = 1.25) -> Bool {
        caret.y >= glyph.y - slop
            && caret.y + caret.height <= glyph.y + glyph.height + slop
            && caret.x >= glyph.x - slop
            && caret.x <= glyph.x + glyph.width + slop
    }
}

public enum CaretContrast {
    /// Redraw the glyph when the tinted cell would drop the text under 3:1.
    public static func needsRedraw(text: CaretRGB, accent: CaretRGB, background: CaretRGB, fillAlpha: Double) -> Bool {
        contrast(text, blend(background, accent, fillAlpha)) < 3
    }

    /// Color for a glyph drawn on top of a nearly solid accent fill.
    public static func glyphColor(accent: CaretRGB, background: CaretRGB) -> CaretRGB {
        if contrast(background, accent) >= 3 { return background }
        return luminance(accent) > 0.55
            ? CaretRGB(r: 0.12, g: 0.12, b: 0.12)
            : CaretRGB(r: 0.96, g: 0.96, b: 0.96)
    }

    public static func blend(_ background: CaretRGB, _ accent: CaretRGB, _ alpha: Double) -> CaretRGB {
        let keep = 1 - alpha
        return CaretRGB(
            r: background.r * keep + accent.r * alpha,
            g: background.g * keep + accent.g * alpha,
            b: background.b * keep + accent.b * alpha
        )
    }

    public static func contrast(_ a: CaretRGB, _ b: CaretRGB) -> Double {
        let hi = max(luminance(a), luminance(b))
        let lo = min(luminance(a), luminance(b))
        return (hi + 0.05) / (lo + 0.05)
    }

    public static func luminance(_ color: CaretRGB) -> Double {
        func channel(_ value: Double) -> Double {
            value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(color.r) + 0.7152 * channel(color.g) + 0.0722 * channel(color.b)
    }

    public static func isDark(_ color: CaretRGB) -> Bool {
        (0.2126 * color.r + 0.7152 * color.g + 0.0722 * color.b) < 0.5
    }
}
