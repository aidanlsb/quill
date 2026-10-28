import AppKit

/// Warm editorial inks. Light is ivory paper and walnut ink; dark is obsidian
/// with a cream letter. One copper accent carries the cursor, links, lists,
/// and the mode pill in both schemes.
enum QuillPalette {
    struct Ink {
        var paper: NSColor
        var text: NSColor
        var syntax: NSColor
        var code: NSColor
        var link: NSColor
        var dim: NSColor
        var accent: NSColor
        var quote: NSColor
        var codeWash: NSColor
        var directoryPaper: NSColor
        var directoryAccent: NSColor
        var created: NSColor
        var renamed: NSColor
        var deleted: NSColor
    }

    static func ink(dark: Bool) -> Ink {
        dark ? Self.dark : Self.light
    }

    /// Warm parchment, not sterile white or a cool gray.
    private static let light = Ink(
        paper: NSColor(calibratedRed: 0.988, green: 0.972, blue: 0.942, alpha: 1),
        text: NSColor(calibratedRed: 0.196, green: 0.157, blue: 0.122, alpha: 1),
        syntax: NSColor(calibratedRed: 0.62, green: 0.56, blue: 0.49, alpha: 1),
        code: NSColor(calibratedRed: 0.38, green: 0.27, blue: 0.20, alpha: 1),
        link: NSColor(calibratedRed: 0.56, green: 0.33, blue: 0.22, alpha: 1),
        dim: NSColor(calibratedRed: 0.62, green: 0.56, blue: 0.50, alpha: 1),
        accent: NSColor(calibratedRed: 0.62, green: 0.34, blue: 0.22, alpha: 1),
        quote: NSColor(calibratedRed: 0.32, green: 0.26, blue: 0.21, alpha: 1),
        codeWash: NSColor(calibratedRed: 0.42, green: 0.30, blue: 0.20, alpha: 0.08),
        directoryPaper: NSColor(calibratedRed: 0.945, green: 0.932, blue: 0.908, alpha: 1),
        directoryAccent: NSColor(calibratedRed: 0.42, green: 0.30, blue: 0.22, alpha: 1),
        created: NSColor(calibratedRed: 0.36, green: 0.48, blue: 0.36, alpha: 1),
        renamed: NSColor(calibratedRed: 0.62, green: 0.44, blue: 0.22, alpha: 1),
        deleted: NSColor(calibratedRed: 0.58, green: 0.32, blue: 0.26, alpha: 1)
    )

    /// Deep warm ink, off-white letters, bronze accent.
    private static let dark = Ink(
        paper: NSColor(calibratedRed: 0.102, green: 0.090, blue: 0.078, alpha: 1),
        text: NSColor(calibratedRed: 0.905, green: 0.872, blue: 0.822, alpha: 1),
        syntax: NSColor(calibratedRed: 0.48, green: 0.44, blue: 0.39, alpha: 1),
        code: NSColor(calibratedRed: 0.80, green: 0.70, blue: 0.58, alpha: 1),
        link: NSColor(calibratedRed: 0.84, green: 0.64, blue: 0.44, alpha: 1),
        dim: NSColor(calibratedRed: 0.50, green: 0.46, blue: 0.41, alpha: 1),
        accent: NSColor(calibratedRed: 0.85, green: 0.64, blue: 0.42, alpha: 1),
        quote: NSColor(calibratedRed: 0.84, green: 0.78, blue: 0.70, alpha: 1),
        codeWash: NSColor(calibratedRed: 1, green: 0.94, blue: 0.86, alpha: 0.07),
        directoryPaper: NSColor(calibratedRed: 0.132, green: 0.118, blue: 0.104, alpha: 1),
        directoryAccent: NSColor(calibratedRed: 0.82, green: 0.70, blue: 0.52, alpha: 1),
        created: NSColor(calibratedRed: 0.58, green: 0.74, blue: 0.58, alpha: 1),
        renamed: NSColor(calibratedRed: 0.86, green: 0.70, blue: 0.44, alpha: 1),
        deleted: NSColor(calibratedRed: 0.82, green: 0.54, blue: 0.48, alpha: 1)
    )
}
