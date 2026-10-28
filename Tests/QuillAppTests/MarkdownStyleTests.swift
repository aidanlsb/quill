import AppKit
import QuillMarkdown
import XCTest
@testable import Quill

/// Editorial paint: headings, quotes, rules, code wash, links, strikethrough.
/// The buffer characters stay exactly as typed.
@MainActor
final class MarkdownStyleTests: QuillAppTestCase {
    func testHeadingHashesStayBodySizedAndTitleGainsWeight() {
        let source = "# Title\n## Section\n"
        let storage = paint(source)
        XCTAssertEqual(storage.string, source)
        let light = QuillTheme.current(scheme: .light)
        let hashFont = storage.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        let titleFont = storage.attribute(.font, at: 2, effectiveRange: nil) as? NSFont
        XCTAssertEqual(hashFont?.pointSize ?? -1, light.bodyFont.pointSize, accuracy: 0.3, "heading hash size")
        XCTAssertGreaterThan(titleFont?.pointSize ?? 0, (hashFont?.pointSize ?? 0) + 4, "heading title size")
        let hashColor = storage.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
        XCTAssertTrue(Probe.sameColor(hashColor, light.syntaxColor), "heading hash color")
        let style = storage.attribute(.paragraphStyle, at: 2, effectiveRange: nil) as? NSParagraphStyle
        XCTAssertGreaterThan(style?.paragraphSpacing ?? 0, 2, "heading spacing")
    }

    func testQuoteItalicAndCodeWashAndRuleRecede() {
        let source = "> quoted line\n\n```\nlet x = 1\n```\n\n---\n\n`code` and ~~gone~~ and [text](url)\n"
        let storage = paint(source)
        XCTAssertEqual(storage.string, source)
        let light = QuillTheme.current(scheme: .light)
        let quoteAt = 2
        let quoteColor = storage.attribute(.foregroundColor, at: quoteAt, effectiveRange: nil) as? NSColor
        XCTAssertTrue(Probe.sameColor(quoteColor, light.quoteColor), "quote color")
        let quotePara = storage.attribute(.paragraphStyle, at: quoteAt, effectiveRange: nil) as? NSParagraphStyle
        XCTAssertGreaterThan(quotePara?.firstLineHeadIndent ?? 0, 4, "quote indent")
        let fence = (source as NSString).range(of: "let x = 1")
        let wash = storage.attribute(.backgroundColor, at: fence.location, effectiveRange: nil) as? NSColor
        XCTAssertTrue(Probe.sameColor(wash, light.codeBackground), "code wash")
        let rule = (source as NSString).range(of: "---")
        XCTAssertNotEqual(rule.location, NSNotFound)
        let ruleColor = storage.attribute(.foregroundColor, at: rule.location, effectiveRange: nil) as? NSColor
        XCTAssertFalse(Probe.sameColor(ruleColor, light.textColor), "rule recedes")
        let code = (source as NSString).range(of: "code")
        let codeWash = storage.attribute(.backgroundColor, at: code.location, effectiveRange: nil) as? NSColor
        XCTAssertTrue(Probe.sameColor(codeWash, light.codeBackground), "inline code wash")
        let gone = (source as NSString).range(of: "gone")
        let strike = storage.attribute(.strikethroughStyle, at: gone.location, effectiveRange: nil) as? NSNumber
        XCTAssertEqual(strike?.intValue, NSUnderlineStyle.single.rawValue, "strikethrough")
        let link = (source as NSString).range(of: "text")
        let linkColor = storage.attribute(.foregroundColor, at: link.location, effectiveRange: nil) as? NSColor
        XCTAssertTrue(Probe.sameColor(linkColor, light.linkColor), "markdown link")
    }

    func testLightPaperIsWarmIvoryNotWhite() {
        let light = QuillTheme.current(scheme: .light)
        let dark = QuillTheme.current(scheme: .dark)
        XCTAssertGreaterThan(Probe.channel(light.backgroundColor, 0), Probe.channel(light.backgroundColor, 2) + 0.02)
        XCTAssertGreaterThan(Probe.channel(light.backgroundColor, 0), 0.95)
        XCTAssertLessThan(Probe.channel(dark.backgroundColor, 0), 0.16)
        XCTAssertGreaterThan(Probe.channel(dark.textColor, 0), Probe.channel(dark.textColor, 2))
    }

    private func paint(_ source: String) -> NSTextStorage {
        let storage = NSTextStorage(string: source)
        let theme = QuillTheme.current(scheme: .light)
        let doc = MarkdownTokenizer(text: source)
        MarkdownStyler.restyle(storage, theme: theme, spans: doc.spans, tableColumnWidth: 480)
        return storage
    }
}
