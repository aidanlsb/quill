import XCTest
@testable import QuillMarkdown

final class CommentTests: XCTestCase {
    func testStandaloneCommentTokens() {
        let text = "see {>>tighten this<<} now"
        let doc = MarkdownTokenizer(text: text)
        XCTAssertEqual(MarkdownTokenizer(text: "{>><<}").spans, [
            TokenSpan(range: 0..<3, token: .syntaxMarker),
            TokenSpan(range: 3..<6, token: .syntaxMarker),
        ])
        XCTAssertTrue(doc.spans.contains { $0.token == .comment && $0.range == 7..<19 })
        XCTAssertTrue(doc.spans.contains { $0.token == .syntaxMarker && $0.range == 4..<7 })
        XCTAssertTrue(doc.spans.contains { $0.token == .syntaxMarker && $0.range == 19..<22 })
        XCTAssertEqual(MarkdownThemeMap.style(for: .comment), .comment)
        XCTAssertEqual(MarkdownThemeMap.style(for: .commentHighlight), .highlight)
        XCTAssertEqual(MarkdownThemeMap.style(for: .syntaxMarker), .syntax)
    }

    func testAnchoredCommentTokens() {
        let text = "{==this sentence==}{>>needs a source<<}"
        let doc = MarkdownTokenizer(text: text)
        XCTAssertEqual(doc.spans, [
            TokenSpan(range: 0..<3, token: .syntaxMarker),
            TokenSpan(range: 3..<16, token: .commentHighlight),
            TokenSpan(range: 16..<19, token: .syntaxMarker),
            TokenSpan(range: 19..<22, token: .syntaxMarker),
            TokenSpan(range: 22..<36, token: .comment),
            TokenSpan(range: 36..<39, token: .syntaxMarker),
        ])
        let comment = MarkdownComments.find(in: text)[0]
        XCTAssertEqual(comment.highlightText(in: text), "this sentence")
        XCTAssertEqual(comment.bodyText(in: text), "needs a source")
        XCTAssertEqual(comment.resolvedText(in: text), "this sentence")
    }

    func testUnclosedMarkersAreNotComments() {
        XCTAssertEqual(MarkdownTokenizer(text: "{>>oops").spans, [])
        XCTAssertEqual(MarkdownTokenizer(text: "{==hi==}{>>oops").spans, [])
        XCTAssertEqual(MarkdownTokenizer(text: "{==hi").spans, [])
        XCTAssertEqual(MarkdownTokenizer(text: "{==hi==}").spans, [])
        XCTAssertEqual(MarkdownTokenizer(text: "{>>oops<<").spans, [])
        XCTAssertEqual(MarkdownComments.find(in: "{>>oops"), [])
        XCTAssertEqual(MarkdownComments.find(in: "{==hi==}"), [])
    }

    func testCodeSpanAndFenceAreNotComments() {
        let span = MarkdownTokenizer(text: "see `{>>not a comment<<}`")
        XCTAssertTrue(span.spans.contains { $0.token == .codeSpan })
        XCTAssertFalse(span.spans.contains { $0.token == .comment })
        XCTAssertEqual(MarkdownComments.find(in: "see `{>>not a comment<<}`"), [])

        let fenced = MarkdownTokenizer(text: "```\n{>>not a comment<<}\n```\n")
        XCTAssertTrue(fenced.spans.allSatisfy { $0.token == .fence })
        XCTAssertEqual(MarkdownComments.find(in: "```\n{>>not a comment<<}\n```\n"), [])
    }

    func testNestedBracesStayInsideTheCommentBody() {
        let text = "{>>look at {this} pair<<}"
        let comment = MarkdownComments.find(in: text)[0]
        XCTAssertEqual(comment.bodyText(in: text), "look at {this} pair")
        XCTAssertEqual(comment.range, 0..<text.utf16.count)

        let nested = "{>>outer {>>inner<<} leftover<<}"
        let found = MarkdownComments.find(in: nested)
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found[0].bodyText(in: nested), "outer {>>inner")
    }

    func testHighlightWithoutACommentIsPlainText() {
        let text = "{==only highlight==} and later {>>a note<<}"
        let comments = MarkdownComments.find(in: text)
        XCTAssertEqual(comments.count, 1)
        XCTAssertNil(comments[0].highlight)
        XCTAssertEqual(comments[0].bodyText(in: text), "a note")
        let spaced = "{==this==} {>>not anchored<<}"
        XCTAssertNil(MarkdownComments.find(in: spaced)[0].highlight)
    }

    func testCommentsStayOnOneLine() {
        let split = "start {>>broken\ncomment<<} after"
        XCTAssertEqual(MarkdownComments.find(in: split), [])
        let splitAnchor = "{==two\nlines==}{>>nope<<}"
        let found = MarkdownComments.find(in: splitAnchor)
        XCTAssertEqual(found.count, 1)
        XCTAssertNil(found[0].highlight)
        XCTAssertEqual(found[0].bodyText(in: splitAnchor), "nope")
        XCTAssertFalse(MarkdownComments.isSingleLine("a\nb"))
        XCTAssertTrue(MarkdownComments.isSingleLine("one line"))
    }

    func testFrontmatterIsNotAComment() {
        let text = "---\n{>>meta<<}\n---\n{>>real<<}\n"
        let comments = MarkdownComments.find(in: text)
        XCTAssertEqual(comments.count, 1)
        XCTAssertEqual(comments[0].bodyText(in: text), "real")
    }

    func testJumpAndCursorLookup() {
        let text = "aa {>>one<<} bb {==two==}{>>three<<} cc"
        let comments = MarkdownComments.find(in: text)
        XCTAssertEqual(comments.count, 2)
        XCTAssertEqual(MarkdownComments.at(cursor: 5, in: text)?.bodyText(in: text), "one")
        XCTAssertEqual(MarkdownComments.at(cursor: 3, in: text)?.bodyText(in: text), "one")
        XCTAssertNil(MarkdownComments.at(cursor: 0, in: text))
        let secondStart = comments[1].range.lowerBound
        XCTAssertEqual(MarkdownComments.jump(from: 0, forward: true, in: text)?.range.lowerBound, comments[0].range.lowerBound)
        XCTAssertEqual(MarkdownComments.jump(from: comments[0].range.lowerBound, forward: true, in: text)?.range.lowerBound, secondStart)
        XCTAssertNil(MarkdownComments.jump(from: secondStart, forward: true, in: text))
        XCTAssertEqual(MarkdownComments.jump(from: secondStart + 1, forward: false, in: text)?.range.lowerBound, secondStart)
        XCTAssertEqual(MarkdownComments.jump(from: secondStart, forward: false, in: text)?.bodyText(in: text), "one")
    }

    func testWrapAndResolveHelpers() {
        XCTAssertEqual(MarkdownComments.wrap("sel"), "{==sel==}{>><<}")
        XCTAssertEqual(MarkdownComments.wrapInsertUTF16(selectedUTF16: 3), 12)
        XCTAssertEqual(MarkdownComments.emptyBodyUTF16, 3)
        let anchored = MarkdownComments.find(in: "{==keep==}{>>drop<<}")[0]
        XCTAssertEqual(anchored.resolvedText(in: "{==keep==}{>>drop<<}"), "keep")
        let standalone = MarkdownComments.find(in: "x{>>drop<<}y")[0]
        XCTAssertEqual(standalone.resolvedText(in: "x{>>drop<<}y"), "")
    }

    func testEmojiUTF16Offsets() {
        let text = "😀{>>ok<<}"
        let comment = MarkdownComments.find(in: text)[0]
        XCTAssertEqual(comment.range.lowerBound, 2)
        XCTAssertEqual(comment.bodyText(in: text), "ok")
        let doc = MarkdownTokenizer(text: text)
        XCTAssertTrue(doc.spans.contains { $0.token == .comment && $0.range == 5..<7 })
    }

    func testCommentEditDoesNotRetokenizeTheTail() {
        let prefix = "intro {>>first<<}\n"
        let tail = (0..<200).map { "Line \($0) with [[note]]\n" }.joined()
        var doc = MarkdownTokenizer(text: prefix + tail)
        let kept = doc.spans.last { $0.token == .wikilink }?.range.lowerBound
        let changed = doc.apply(start: prefix.utf16.count - 2, removedUTF16: 1, replacement: "!")
        XCTAssertEqual(changed.count, 1)
        XCTAssertEqual(doc.spans.last { $0.token == .wikilink }?.range.lowerBound, kept)
    }
}
