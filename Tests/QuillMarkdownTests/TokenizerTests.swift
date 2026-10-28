import XCTest
@testable import QuillMarkdown

final class TokenizerTests: XCTestCase {
    func testTokens() {
        let text = """
        ---
        title: Note
        ---
        # Title
        See [[wikilink]] and `code` and **bold** and *em*.
        - [ ] task
        ```
        let x = 1
        ```
        """
        let doc = MarkdownTokenizer(text: text)
        let kinds = doc.spans.map(\.token)
        XCTAssertTrue(kinds.contains(.frontmatter))
        XCTAssertTrue(kinds.contains(.heading(1)))
        XCTAssertTrue(kinds.contains(.wikilink))
        XCTAssertTrue(kinds.contains(.codeSpan))
        XCTAssertTrue(kinds.contains(.strong))
        XCTAssertTrue(kinds.contains(.emphasis))
        XCTAssertTrue(kinds.contains(.listMarker))
        XCTAssertTrue(kinds.contains(.taskBox))
        XCTAssertTrue(kinds.contains(.fence))
        XCTAssertEqual(MarkdownThemeMap.style(for: .wikilink), .link)
        XCTAssertEqual(MarkdownThemeMap.style(for: .heading(2)), .heading(2))
        XCTAssertEqual(MarkdownThemeMap.style(for: .listMarker), .list)
        XCTAssertEqual(MarkdownThemeMap.style(for: .taskBox), .list)
        XCTAssertEqual(MarkdownThemeMap.style(for: .syntaxMarker), .syntax)
        XCTAssertEqual(MarkdownThemeMap.style(for: .blockquote), .quote)
        XCTAssertEqual(MarkdownThemeMap.style(for: .thematicBreak), .rule)
        XCTAssertEqual(MarkdownThemeMap.style(for: .strikethrough), .strikethrough)
        XCTAssertEqual(MarkdownThemeMap.style(for: .link), .link)
    }

    func testEditShiftsLaterSpans() {
        let text = "hello\n# Title\n"
        var doc = MarkdownTokenizer(text: text)
        let edited = "Xhello\n# Title\n"
        let changed = doc.replace(text: edited, dirtyUTF16: 0)
        XCTAssertLessThan(changed.upperBound, 2)
        let heading = doc.spans.first { $0.token == .heading(1) }
        XCTAssertEqual(heading?.range.lowerBound, 7)
        XCTAssertTrue(doc.spans.contains { $0.token == .heading(1) })
    }

    func testBoundsMatchLineSplit() {
        let text = "a\n\n# Title\n"
        let lines = LineSplit.lines(in: text)
        let bounds = LineSplit.bounds(in: text)
        XCTAssertEqual(lines.map(\.start), bounds.map(\.start))
        XCTAssertEqual(lines.map(\.end), bounds.map(\.end))
        XCTAssertEqual(lines.map(\.isBlank), bounds.map(\.isBlank))
    }

    func testApplyAtStartMovesLaterLineSpan() {
        let text = "aaaa\nbbbb\ncccc\n"
        var doc = MarkdownTokenizer(text: text)
        _ = doc.apply(start: 0, removedUTF16: 0, replacement: "Z")
        XCTAssertEqual(doc.lineSpan(1..<2), 6..<11)
        XCTAssertEqual(doc.utf16Count, text.utf16.count + 1)
    }

    func testSpansFollowEditOnlyWhenTokensAreUnchanged() {
        let plain = TokenSpan(range: 4..<8, token: .codeSpan)
        let shifted = TokenSpan(range: 5..<9, token: .codeSpan)
        XCTAssertTrue(MarkdownTokenizer.spansFollowEdit([plain], [shifted], editAt: 0, delta: 1))
        let grown = TokenSpan(range: 4..<9, token: .codeSpan)
        XCTAssertFalse(MarkdownTokenizer.spansFollowEdit([plain], [grown], editAt: 6, delta: 1))
        XCTAssertFalse(MarkdownTokenizer.spansFollowEdit([plain], [], editAt: 0, delta: 1))
    }

    func testRepeatedApplyAtStartShiftsLaterSpans() {
        let text = (0..<40).map { "Line \($0) [[note]]\n" }.joined()
        var doc = MarkdownTokenizer(text: text)
        let before = doc.spans.first { $0.range.lowerBound > 80 && $0.token == .wikilink }?.range.lowerBound
        _ = doc.apply(start: 0, removedUTF16: 0, replacement: "X")
        _ = doc.apply(start: 0, removedUTF16: 0, replacement: "Y")
        let after = doc.spans.first { $0.range.lowerBound > 80 && $0.token == .wikilink }?.range.lowerBound
        XCTAssertEqual(after, (before ?? -1) + 2)
        XCTAssertEqual(doc.utf16Count, text.utf16.count + 2)
    }

    func testPrescanLeavesTheTailUntokenized() {
        let text = (0..<30).map { "line\($0) [[n]]\n" }.joined()
        var doc = MarkdownTokenizer(text: text, scanThroughLine: 1)
        XCTAssertEqual(doc.scannedLineCount, 2)
        XCTAssertTrue(doc.spans.allSatisfy { $0.range.lowerBound < 40 })
        let tail = doc.spans(overlapping: doc.lineSpan(20..<21))
        XCTAssertEqual(doc.scannedLineCount, 21)
        XCTAssertTrue(tail.contains { $0.token == .wikilink })
    }

    func testApplyEditKeepsEarlierSpans() {
        let text = "hello\n# Title\n"
        var doc = MarkdownTokenizer(text: text)
        let changed = doc.apply(start: 0, removedUTF16: 0, replacement: "X")
        XCTAssertEqual(changed, 0..<1)
        let heading = doc.spans.first { $0.token == .heading(1) }
        XCTAssertEqual(heading?.range.lowerBound, 7)
        XCTAssertEqual(doc.utf16Count, text.utf16.count + 1)
    }

    func testApplyDeletesNewlineAndDropsHeading() {
        var doc = MarkdownTokenizer(text: "ab\n# T\n")
        let changed = doc.apply(start: 2, removedUTF16: 1, replacement: "")
        XCTAssertEqual(changed.count, 1)
        XCTAssertFalse(doc.spans.contains { $0.token == .heading(1) })
        XCTAssertEqual(doc.utf16Count, 6)
    }

    func testApplyInsertsNewline() {
        var doc = MarkdownTokenizer(text: "# ab\n")
        let changed = doc.apply(start: 2, removedUTF16: 0, replacement: "\n")
        XCTAssertEqual(doc.utf16Count, 6)
        XCTAssertTrue(doc.spans.contains { $0.token == .heading(1) })
        XCTAssertLessThan(changed.upperBound, 3)
    }

    func testIncrementalEditIsCheaperThanRetokenizing() {
        let text = (0..<4_000).map { "Line \($0) with [[note]] and `code` and **bold**.\n" }.joined()
        let full = ContinuousClock().now
        _ = MarkdownTokenizer(text: text)
        let fullMs = milliseconds(since: full)
        var doc = MarkdownTokenizer(text: text)
        let kept = doc.spans.first { $0.token == .wikilink }?.range
        let edit = ContinuousClock().now
        let changed = doc.apply(start: text.utf16.count - 2, removedUTF16: 1, replacement: "!")
        let editMs = milliseconds(since: edit)
        print(String(format: "quill bench styleFullMs=%.2f styleEditMs=%.2f changedLines=%d", fullMs, editMs, changed.count))
        XCTAssertEqual(changed.count, 1)
        XCTAssertEqual(doc.spans.first { $0.token == .wikilink }?.range, kept)
        XCTAssertEqual(doc.utf16Count, text.utf16.count)
    }

    private func milliseconds(since start: ContinuousClock.Instant) -> Double {
        let duration = start.duration(to: .now)
        return Double(duration.components.seconds) * 1000
            + Double(duration.components.attoseconds) / 1_000_000_000_000_000
    }

    func testFenceStateConverges() {
        let text = "# A\n\n```\ncode\n```\n\nafter\n"
        var doc = MarkdownTokenizer(text: text)
        let changed = doc.replace(text: text.replacingOccurrences(of: "code", with: "code2"), dirtyUTF16: 10)
        XCTAssertLessThan(changed.upperBound, LineSplit.lines(in: text).count)
        XCTAssertTrue(doc.spans.contains { $0.token == .fence })
        XCTAssertTrue(doc.spans.contains { $0.token == .heading(1) })
    }

    func testInlinePrefixesDoNotReadPastTheEnd() {
        let lines = [
            "- [ ] task",
            "**bold**",
            "[[link]]",
            "`code`",
            "*em*",
            "[",
            "[ ",
            "[x",
            "**",
            "[[",
            "[[a]",
        ]
        for line in lines {
            let characters = Array(line)
            for length in 0...characters.count {
                let prefix = String(characters.prefix(length))
                let doc = MarkdownTokenizer(text: prefix)
                assertSpansInBounds(doc.spans, utf16Count: doc.utf16Count)
                assertSpansInBounds(Scanner.inline(prefix, lineStart: 0), utf16Count: prefix.utf16.count)
            }
            var typed = MarkdownTokenizer(text: "")
            for character in line {
                _ = typed.apply(start: typed.utf16Count, removedUTF16: 0, replacement: String(character))
                assertSpansInBounds(typed.spans, utf16Count: typed.utf16Count)
            }
        }
    }

    func testClosedInlineMarkers() {
        XCTAssertEqual(MarkdownTokenizer(text: "- [ ] task").spans, [
            TokenSpan(range: 0..<2, token: .listMarker),
            TokenSpan(range: 2..<5, token: .taskBox),
        ])
        XCTAssertEqual(MarkdownTokenizer(text: "[ ]").spans, [
            TokenSpan(range: 0..<3, token: .taskBox),
        ])
        XCTAssertEqual(MarkdownTokenizer(text: "[x]").spans, [
            TokenSpan(range: 0..<3, token: .taskBox),
        ])
        XCTAssertEqual(MarkdownTokenizer(text: "[X]").spans, [
            TokenSpan(range: 0..<3, token: .taskBox),
        ])
        XCTAssertEqual(MarkdownTokenizer(text: "**bold**").spans, [
            TokenSpan(range: 0..<2, token: .syntaxMarker),
            TokenSpan(range: 2..<6, token: .strong),
            TokenSpan(range: 6..<8, token: .syntaxMarker),
        ])
        XCTAssertEqual(MarkdownTokenizer(text: "[[link]]").spans, [
            TokenSpan(range: 0..<8, token: .wikilink),
            TokenSpan(range: 0..<2, token: .syntaxMarker),
        ])
        XCTAssertEqual(MarkdownTokenizer(text: "`code`").spans, [
            TokenSpan(range: 0..<1, token: .syntaxMarker),
            TokenSpan(range: 0..<6, token: .codeSpan),
            TokenSpan(range: 5..<6, token: .syntaxMarker),
        ])
        XCTAssertEqual(MarkdownTokenizer(text: "*em*").spans, [
            TokenSpan(range: 0..<1, token: .syntaxMarker),
            TokenSpan(range: 1..<3, token: .emphasis),
            TokenSpan(range: 3..<4, token: .syntaxMarker),
        ])
        XCTAssertEqual(MarkdownTokenizer(text: "~~gone~~").spans, [
            TokenSpan(range: 0..<2, token: .syntaxMarker),
            TokenSpan(range: 2..<6, token: .strikethrough),
            TokenSpan(range: 6..<8, token: .syntaxMarker),
        ])
        XCTAssertEqual(MarkdownTokenizer(text: "[text](url)").spans, [
            TokenSpan(range: 0..<1, token: .syntaxMarker),
            TokenSpan(range: 1..<5, token: .link),
            TokenSpan(range: 5..<11, token: .syntaxMarker),
        ])
    }

    func testEditorialBlocks() {
        let quote = MarkdownTokenizer(text: "> a line")
        XCTAssertTrue(quote.spans.contains { $0.token == .blockquote })
        XCTAssertTrue(quote.spans.contains { $0.token == .syntaxMarker && $0.range == 0..<2 })
        let rule = MarkdownTokenizer(text: "---")
        XCTAssertEqual(rule.spans.map(\.token), [.frontmatter])
        let later = MarkdownTokenizer(text: "para\n\n***\n")
        XCTAssertTrue(later.spans.contains { $0.token == .thematicBreak })
        let quotedHeading = MarkdownTokenizer(text: "> # Title")
        XCTAssertTrue(quotedHeading.spans.contains { $0.token == .blockquote })
        XCTAssertTrue(quotedHeading.spans.contains { $0.token == .heading(1) })
        XCTAssertEqual(Scanner.blockquotePrefixUTF16("> a"), 2)
        XCTAssertEqual(Scanner.blockquotePrefixUTF16("  >a"), 3)
        XCTAssertTrue(Scanner.isThematicBreak("---"))
        XCTAssertTrue(Scanner.isThematicBreak("  * * *"))
        XCTAssertFalse(Scanner.isThematicBreak("- item"))
    }

    func testTruncatedInlineMarkersStayOpen() {
        XCTAssertEqual(MarkdownTokenizer(text: "[").spans, [])
        XCTAssertEqual(MarkdownTokenizer(text: "[ ").spans, [])
        XCTAssertEqual(MarkdownTokenizer(text: "[x").spans, [])
        XCTAssertEqual(MarkdownTokenizer(text: "**").spans, [])
        XCTAssertEqual(MarkdownTokenizer(text: "[[").spans, [])
        XCTAssertEqual(MarkdownTokenizer(text: "[[a]").spans, [])
        XCTAssertEqual(MarkdownTokenizer(text: "`").spans, [])
        XCTAssertEqual(MarkdownTokenizer(text: "*em").spans, [])
        XCTAssertEqual(MarkdownTokenizer(text: "~~").spans, [])
        XCTAssertEqual(MarkdownTokenizer(text: "[text](").spans, [])
        XCTAssertEqual(MarkdownTokenizer(text: "- [ ").spans, [
            TokenSpan(range: 0..<2, token: .listMarker),
        ])
        XCTAssertEqual(MarkdownTokenizer(text: "- [x").spans, [
            TokenSpan(range: 0..<2, token: .listMarker),
        ])
    }

    private func assertSpansInBounds(_ spans: [TokenSpan], utf16Count: Int, file: StaticString = #filePath, line: UInt = #line) {
        for span in spans {
            XCTAssertGreaterThanOrEqual(span.range.lowerBound, 0, file: file, line: line)
            XCTAssertLessThanOrEqual(span.range.upperBound, utf16Count, file: file, line: line)
            XCTAssertLessThan(span.range.lowerBound, span.range.upperBound, file: file, line: line)
        }
    }

    func testListHangPrefix() {
        XCTAssertEqual(MarkdownTokenizer.listHangPrefixUTF16("- item"), 2)
        XCTAssertEqual(MarkdownTokenizer.listHangPrefixUTF16("* item"), 2)
        XCTAssertEqual(MarkdownTokenizer.listHangPrefixUTF16("+ item"), 2)
        XCTAssertEqual(MarkdownTokenizer.listHangPrefixUTF16("1. item"), 3)
        XCTAssertEqual(MarkdownTokenizer.listHangPrefixUTF16("12. item"), 4)
        XCTAssertEqual(MarkdownTokenizer.listHangPrefixUTF16("- [ ] item"), 6)
        XCTAssertEqual(MarkdownTokenizer.listHangPrefixUTF16("- [x] item"), 6)
        XCTAssertEqual(MarkdownTokenizer.listHangPrefixUTF16("- [X] item"), 6)
        XCTAssertEqual(MarkdownTokenizer.listHangPrefixUTF16("* [ ] item"), 6)
        XCTAssertEqual(MarkdownTokenizer.listHangPrefixUTF16("1. [x] item"), 7)
        XCTAssertEqual(MarkdownTokenizer.listHangPrefixUTF16("  - nested"), 4)
        XCTAssertEqual(MarkdownTokenizer.listHangPrefixUTF16("    * nested"), 6)
        XCTAssertEqual(MarkdownTokenizer.listHangPrefixUTF16("\t- nested"), 3)
        XCTAssertEqual(MarkdownTokenizer.listHangPrefixUTF16("- [ ]"), 5)
        XCTAssertEqual(MarkdownTokenizer.listHangPrefixUTF16("- [x]"), 5)
        XCTAssertEqual(MarkdownTokenizer.listHangPrefixUTF16("- [y] item"), 2)
        XCTAssertEqual(MarkdownTokenizer.listHangPrefixUTF16("- see [x] later"), 2)
        XCTAssertEqual(MarkdownTokenizer.listHangPrefixUTF16("- café"), 2)
        XCTAssertNil(MarkdownTokenizer.listHangPrefixUTF16("plain"))
        XCTAssertNil(MarkdownTokenizer.listHangPrefixUTF16("-item"))
        XCTAssertNil(MarkdownTokenizer.listHangPrefixUTF16("1.item"))
        XCTAssertNil(MarkdownTokenizer.listHangPrefixUTF16(""))
        XCTAssertNil(MarkdownTokenizer.listHangPrefixUTF16("---"))
        XCTAssertNil(MarkdownTokenizer.listHangPrefixUTF16("> - item"))
        let fenced = MarkdownTokenizer(text: "```\n- [ ] item\n```\n")
        XCTAssertFalse(fenced.spans.contains { $0.token == .listMarker })
    }

    func testWikilinkUTF16() {
        let text = "[[note]]"
        XCTAssertEqual(WikilinkQuery.at(cursor: 4, in: text), "note")
        XCTAssertEqual(WikilinkQuery.prefix(before: 6, in: "[[not"), "not")
        let line = "see [[no"
        XCTAssertEqual(WikilinkQuery.prefix(before: line.utf16.count, in: line), "no")
        let current = "plain text"
        XCTAssertNil(WikilinkQuery.prefix(before: current.utf16.count, in: current))
        let paragraph = Paragraphs.range(in: "one\n\ntwo three\n", utf16: 6)
        XCTAssertTrue(paragraph.contains(6))
    }
}
