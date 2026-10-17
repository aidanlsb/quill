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
