import AppKit
import QuillVim
import XCTest
@testable import Quill

@MainActor
extension Probe {
    static func checkDefaultType(failures: Failures) {
        let theme = QuillTheme.current()
        let body = theme.bodyFont.pointSize
        check(abs(body - QuillMetrics.defaultFontSize) < 0.2, "default body font \(body)", failures: failures)
        check(
            theme.headingFonts.count == QuillMetrics.headingScale.count,
            "heading scale count \(theme.headingFonts.count)",
            failures: failures
        )
        for (font, scale) in zip(theme.headingFonts, QuillMetrics.headingScale) {
            let expected = CGFloat(QuillMetrics.defaultFontSize) * scale
            check(
                abs(font.pointSize - expected) < 0.6,
                "heading scale \(font.pointSize) expected \(expected)",
                failures: failures
            )
        }
        check(abs(theme.lineHeight - 1.58) < 0.01, "line height \(theme.lineHeight)", failures: failures)
        check(
            QuillMetrics.headingWeights.count == QuillMetrics.headingScale.count,
            "heading weight count \(QuillMetrics.headingWeights.count)",
            failures: failures
        )
        check(QuillConfig.default.fontSize == 16, "default body font config \(QuillConfig.default.fontSize)", failures: failures)
        check(QuillConfig.default.font.isEmpty, "default body font family set", failures: failures)
        let system = NSFont.systemFont(ofSize: CGFloat(QuillMetrics.defaultFontSize))
        check(
            theme.bodyFont.familyName == system.familyName,
            "default body font family \(theme.bodyFont.familyName ?? "")",
            failures: failures
        )
        for (font, expected) in zip(theme.headingFonts, QuillMetrics.headingWeights) {
            let weight = fontWeight(font)
            check(
                abs(weight - expected.rawValue) < 0.08,
                "heading weight \(weight) expected \(expected.rawValue)",
                failures: failures
            )
            check(
                font.familyName == system.familyName,
                "heading family \(font.familyName ?? "")",
                failures: failures
            )
        }
        let monoFamily = theme.monoFont.familyName ?? ""
        let systemMono = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular).familyName ?? ""
        check(theme.monoFont.isFixedPitch, "mono font \(monoFamily)", failures: failures)
        check(
            monoFamily == "SF Mono" || monoFamily == systemMono,
            "mono font \(monoFamily)",
            failures: failures
        )
        let missing = QuillTheme.current(fontFamily: "Not A Real Font")
        check(
            missing.bodyFont.familyName == system.familyName,
            "font fallback \(missing.bodyFont.familyName ?? "")",
            failures: failures
        )
        let helvetica = QuillTheme.current(fontFamily: "Helvetica")
        check(helvetica.bodyFont.familyName == "Helvetica", "font family \(helvetica.bodyFont.familyName ?? "")", failures: failures)
        if let decoded = try? QuillConfig.decode(Data("font = \" Helvetica \"\n".utf8)) {
            check(decoded.font == "Helvetica", "font config \(decoded.font)", failures: failures)
        } else {
            failures.append("font config decode")
        }
        check(QuillConfig.default.columnWidth == 70, "column default \(QuillConfig.default.columnWidth)", failures: failures)
        check(QuillMetrics.fontSize(nil) == 16, "default body font missing", failures: failures)
        check(QuillMetrics.fontSize(9) == 16, "default body font low", failures: failures)
        check(QuillMetrics.fontSize(33) == 16, "default body font high", failures: failures)
        check(QuillMetrics.fontSize(18) == 18, "font size 18", failures: failures)
        check(QuillMetrics.sideGutter >= 120, "side gutter \(QuillMetrics.sideGutter)", failures: failures)
        check(QuillMetrics.verticalInset >= 120, "vertical inset \(QuillMetrics.verticalInset)", failures: failures)
        let tight = QuillMetrics.columnSpan(width: 700, column: 560)
        check(tight.inset >= QuillMetrics.sideGutter, "side gutter \(tight.inset)", failures: failures)
        check(
            tight.inset * 2 + tight.column <= 700.5,
            "side gutter overflow \(tight.inset) \(tight.column)",
            failures: failures
        )
    }

    static func checkTheme(failures: Failures) {
        let dark = QuillTheme.current(scheme: .dark)
        let light = QuillTheme.current(scheme: .light)
        check(brightness(dark.backgroundColor) < brightness(light.backgroundColor), "theme dark", failures: failures)
        check(channel(light.backgroundColor, 0) > channel(light.backgroundColor, 2), "theme light warmth", failures: failures)
        check(channel(light.textColor, 0) > channel(light.textColor, 2), "theme light ink warmth", failures: failures)
        check(channel(dark.textColor, 0) > channel(dark.textColor, 2), "theme dark ink warmth", failures: failures)
        check(colorDistance(light.accentColor, light.textColor) > 0.2, "theme light accent", failures: failures)
        check(colorDistance(dark.accentColor, dark.textColor) > 0.2, "theme dark accent", failures: failures)
        check(light.backgroundColor.alphaComponent > 0.99, "theme light opaque", failures: failures)
        do {
            let fixture = try TempDirectory()
            let url = fixture.url.appendingPathComponent("state.toml")
            try ThemeMemory.save(.dark, to: url)
            check(ThemeMemory.load(from: url) == .dark, "theme memory", failures: failures)
            withExtendedLifetime(fixture) {}
        } catch {
            failures.append("theme memory \(error.localizedDescription)")
        }
        check(QuillConfig.default.theme == .system, "theme config default", failures: failures)
        if let decoded = try? QuillConfig.decode(Data("theme = \"dark\"\n".utf8)) {
            check(decoded.theme == .dark, "theme config \(decoded.theme.rawValue)", failures: failures)
        } else {
            failures.append("theme config")
        }
        check((try? QuillConfig.decode(Data("theme = \"blue\"\n".utf8))) == nil, "theme config name", failures: failures)
    }

}

final class ThemeTests: QuillAppTestCase {
    @MainActor
    func testDefaultType() {
        let failures = Failures()
        Probe.checkDefaultType(failures: failures)
    }

    @MainActor
    func testThemeColorsMemoryAndConfig() {
        let failures = Failures()
        Probe.checkTheme(failures: failures)
    }
}
