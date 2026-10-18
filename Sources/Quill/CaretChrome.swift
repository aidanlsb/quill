import AppKit
import QuillVim

/// The caret the user actually sees. TextKit 2's `NSTextInsertionIndicator` is the
/// line-fragment height and ignores `drawInsertionPoint`, so the cell is this view.
final class CaretChrome: NSView {
    enum Kind {
        case block
        case beam
    }

    var kind: Kind = .block {
        didSet { if kind != oldValue { needsDisplay = true } }
    }
    var accent: NSColor = NSColor(srgbRed: 0.17, green: 0.39, blue: 0.76, alpha: 1) {
        didSet { needsDisplay = true }
    }
    /// Normal-mode tint. The glyph underneath shows through.
    var blockAlpha: CGFloat = CGFloat(CaretGeometry.blockFillAlpha) {
        didSet { needsDisplay = true }
    }
    /// Insert-mode beam strength. Pulses only while blinking.
    var beamOpacity: CGFloat = 1 {
        didSet { if abs(beamOpacity - oldValue) > 0.01 { needsDisplay = true } }
    }
    var glyph: String?
    var glyphFont: NSFont?
    var glyphColor: NSColor?

    private var blinkTask: Task<Void, Never>?
    private var blinkGeneration = 0

    var isBlinking: Bool { blinkTask != nil }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Insert mode only. The pulse never reaches zero, and leaving insert restores
    /// full strength on the same frame so the block does not flash off.
    func setBlinking(_ enabled: Bool) {
        if enabled {
            guard blinkTask == nil else { return }
        } else {
            guard blinkTask != nil else { return }
        }
        blinkGeneration += 1
        let generation = blinkGeneration
        blinkTask?.cancel()
        blinkTask = nil
        beamOpacity = 1
        guard enabled else { return }
        blinkTask = Task { @MainActor [weak self] in
            var phase = 0.0
            while !Task.isCancelled {
                guard let self, self.blinkGeneration == generation else { return }
                phase += .pi / 16
                let wave = (cos(phase) + 1) / 2
                self.beamOpacity = 0.34 + 0.66 * wave
                do {
                    try await Task.sleep(nanoseconds: 45_000_000)
                } catch {
                    return
                }
            }
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard bounds.width > 0.5, bounds.height > 0.5 else { return }
        let radius: CGFloat
        let alpha: CGFloat
        switch kind {
        case .beam:
            radius = bounds.width / 2
            alpha = beamOpacity
        case .block:
            radius = min(2.5, bounds.width * 0.28, bounds.height * 0.18)
            alpha = blockAlpha
        }
        accent.withAlphaComponent(alpha).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()
        if kind == .block, let glyph, let glyphFont, let glyphColor, !glyph.isEmpty {
            let attributes: [NSAttributedString.Key: Any] = [
                .font: glyphFont,
                .foregroundColor: glyphColor,
            ]
            (glyph as NSString).draw(with: bounds, options: [.usesLineFragmentOrigin], attributes: attributes)
        }
    }
}

enum CaretInk {
    static func accent(for background: NSColor) -> NSColor {
        let dark = background.caretRGB().map(CaretContrast.isDark) ?? false
        return NSColor(caret: CaretGeometry.accent(darkBackground: dark))
    }

    /// Nil when the tint already leaves the glyph readable.
    static func glyphRedraw(text: NSColor, accent: NSColor, background: NSColor) -> NSColor? {
        guard let textRGB = text.caretRGB(),
              let accentRGB = accent.caretRGB(),
              let backgroundRGB = background.caretRGB() else { return nil }
        guard CaretContrast.needsRedraw(
            text: textRGB,
            accent: accentRGB,
            background: backgroundRGB,
            fillAlpha: CaretGeometry.blockFillAlpha
        ) else { return nil }
        return NSColor(caret: CaretContrast.glyphColor(accent: accentRGB, background: backgroundRGB))
    }
}

extension NSColor {
    fileprivate convenience init(caret rgb: CaretRGB) {
        self.init(srgbRed: rgb.r, green: rgb.g, blue: rgb.b, alpha: 1)
    }

    fileprivate func caretRGB() -> CaretRGB? {
        guard let rgb = usingColorSpace(.sRGB) else { return nil }
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        guard rgb.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else { return nil }
        return CaretRGB(r: Double(red), g: Double(green), b: Double(blue))
    }
}
