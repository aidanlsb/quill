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

    func testWikilinkUTF16() {
        let text = "[[note]]"
        XCTAssertEqual(WikilinkQuery.at(cursor: 4, in: text), "note")
        XCTAssertEqual(WikilinkQuery.prefix(before: 6, in: "[[not"), "not")
        let paragraph = Paragraphs.range(in: "one\n\ntwo three\n", utf16: 6)
        XCTAssertTrue(paragraph.contains(6))
    }

    func testThemeFile() {
        let theme = ThemeFile.parse("{\"name\":\"paper\",\"focusDim\":true,\"text\":\"#222\",\"link\":\"#36a\"}")
        XCTAssertEqual(theme?.name, "paper")
        XCTAssertEqual(theme?.colors["link"], "#36a")
        XCTAssertEqual(theme?.focusDim, true)
    }
}
